#!/bin/bash
#
# Package Init Script
# Installs Python, Node, Bun, Bash, and R runtime packages for the NsJail sandbox.
# Runs inside the package-init container to populate the packages PVC.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER_FILE="/pkgs/.initialized"
FORCE_REBUILD="${FORCE_REBUILD:-false}"
PYTHON_VERSION="${PYTHON_VERSION:-3.14.4}"
PYTHON_SITE_VERSION="${PYTHON_VERSION%.*}"
PYTHON_ALIAS="python${PYTHON_SITE_VERSION}"
# "uv" (default) installs the Python package list noticeably faster than pip.
# Set to "pip" to use the previous behavior. Like any unpinned "latest
# compatible" install, the exact resolved versions can differ run to run (and
# between installers) for packages with no version constraint in the list
# below — that's inherent to installing unpinned packages, not specific to uv.
PYTHON_PACKAGE_INSTALLER="${PYTHON_PACKAGE_INSTALLER:-uv}"
UV_VERSION="${UV_VERSION:-0.11.26}"
NODE_VERSION="${NODE_VERSION:-24.22.1}"
BUN_VERSION="${BUN_VERSION:-1.4.4}"
BASH_PACKAGE_VERSION="${BASH_PACKAGE_VERSION:-5.2.0}"
R_VERSION="${R_VERSION:-4.5.2}"
# CRAN publishes no arm64 Linux binaries, so every R package is compiled from
# source. A dated snapshot — not a moving mirror — keeps that compile
# reproducible: the same commit resolves the same package versions on a
# rebuild. Bump this date deliberately, the way a pinned version is bumped.
R_CRAN_REPO="${R_CRAN_REPO:-https://packagemanager.posit.co/cran/2026-11-03}"
# "core" installs only the first tier of r-packages.txt (shorter local builds);
# the default installs every tier.
R_PACKAGE_SET="${R_PACKAGE_SET:-full}"
INSTALL_FAILED=false
JS_PACKAGE_MANIFEST="${JS_PACKAGE_MANIFEST:-${SCRIPT_DIR}/javascript-packages.txt}"
R_PACKAGE_MANIFEST="${R_PACKAGE_MANIFEST:-${SCRIPT_DIR}/r-packages.txt}"

load_js_packages() {
    if [ ! -f "$JS_PACKAGE_MANIFEST" ]; then
        echo "ERROR: Missing JavaScript package manifest: $JS_PACKAGE_MANIFEST"
        INSTALL_FAILED=true
        JS_PACKAGES=()
        return
    fi

    JS_PACKAGES=()
    while IFS= read -r package_spec || [ -n "$package_spec" ]; do
        [[ "$package_spec" =~ ^[[:space:]]*(#|$) ]] && continue
        JS_PACKAGES+=("$package_spec")
    done < "$JS_PACKAGE_MANIFEST"
    if [ "${#JS_PACKAGES[@]}" -eq 0 ]; then
        echo "ERROR: JavaScript package manifest is empty: $JS_PACKAGE_MANIFEST"
        INSTALL_FAILED=true
    fi
}

validate_bun_package_batch_size() {
    local batch_size="${BUN_PACKAGE_BATCH_SIZE:-4}"
    if [[ ! "$batch_size" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: BUN_PACKAGE_BATCH_SIZE must be a positive integer (got: ${batch_size})" >&2
        return 1
    fi
    printf '%s\n' "$batch_size"
}

package_name_from_spec() {
    local spec="$1"
    echo "${spec%@*}"
}

package_version_from_spec() {
    local spec="$1"
    echo "${spec##*@}"
}

js_packages_ready() {
    local pkg_root="$1"
    local spec package_name package_version package_json
    [ "${#JS_PACKAGES[@]}" -gt 0 ] || return 1
    for spec in "${JS_PACKAGES[@]}"; do
        package_name="$(package_name_from_spec "$spec")"
        package_version="$(package_version_from_spec "$spec")"
        package_json="${pkg_root}/node_modules/${package_name}/package.json"
        [ -f "$package_json" ] || return 1
        if [ "$package_name" != "$package_version" ]; then
            grep -F "\"version\": \"${package_version}\"" "$package_json" >/dev/null || return 1
        fi
    done
}

load_js_packages

echo "=============================================="
echo "  Code Interpreter - Package Init"
echo "=============================================="
echo ""

packages_ready() {
    [ -f "/pkgs/python/${PYTHON_VERSION}/lib/python${PYTHON_SITE_VERSION}/.sandbox-pipe-runtime-v1" ] &&
    [ -f "/pkgs/python/${PYTHON_VERSION}/.package-installed" ] &&
    [ -d "/pkgs/python/${PYTHON_VERSION}/lib/python${PYTHON_SITE_VERSION}/site-packages/PIL" ] &&
    [ -d "/pkgs/python/${PYTHON_VERSION}/lib/python${PYTHON_SITE_VERSION}/site-packages/markitdown" ] &&
    [ -d "/pkgs/python/${PYTHON_VERSION}/lib/python${PYTHON_SITE_VERSION}/site-packages/chdb" ] &&
    [ -d "/pkgs/python/${PYTHON_VERSION}/lib/python${PYTHON_SITE_VERSION}/site-packages/statsmodels" ] &&
    [ -d "/pkgs/python/${PYTHON_VERSION}/lib/python${PYTHON_SITE_VERSION}/site-packages/rasterio" ] &&
    [ -f "/pkgs/node/${NODE_VERSION}/.package-installed" ] &&
    js_packages_ready "/pkgs/node/${NODE_VERSION}" &&
    [ -f "/pkgs/bun/${BUN_VERSION}/.package-installed" ] &&
    js_packages_ready "/pkgs/bun/${BUN_VERSION}" &&
    [ -f "/pkgs/bash/${BASH_PACKAGE_VERSION}/.package-installed" ] &&
    [ -f "/pkgs/r/${R_VERSION}/.package-installed" ]
}

write_node_launcher() {
    local destination="$1"
    local launcher
    launcher="$(mktemp "${destination}/.run.XXXXXX")"
    cat > "$launcher" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="${SCRIPT_DIR}/node_modules"
if [ -d "$MODULE_DIR" ]; then
    if [ -L /mnt/data/node_modules ]; then
        LINK_TARGET="$(readlink -m /mnt/data/node_modules)"
        if [ "$LINK_TARGET" != "$MODULE_DIR" ]; then
            case "$LINK_TARGET" in
                "${SCRIPT_DIR%/*/*}/"*/node_modules)
                    ln -sfnT "$MODULE_DIR" /mnt/data/node_modules ;;
            esac
        fi
    elif [ ! -e /mnt/data/node_modules ]; then
        ln -s "$MODULE_DIR" /mnt/data/node_modules 2>/dev/null || true
    fi
fi
"${SCRIPT_DIR}/bin/node" "$@"
EOF
    chmod 0755 "$launcher"
    mv -f "$launcher" "${destination}/run"
}

write_bun_launcher() {
    local destination="$1"
    local launcher
    launcher="$(mktemp "${destination}/.run.XXXXXX")"
    cat > "$launcher" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="${SCRIPT_DIR}/node_modules"
if [ -d "$MODULE_DIR" ]; then
    if [ -L /mnt/data/node_modules ]; then
        LINK_TARGET="$(readlink -m /mnt/data/node_modules)"
        if [ "$LINK_TARGET" != "$MODULE_DIR" ]; then
            case "$LINK_TARGET" in
                "${SCRIPT_DIR%/*/*}/"*/node_modules)
                    ln -sfnT "$MODULE_DIR" /mnt/data/node_modules ;;
            esac
        fi
    elif [ ! -e /mnt/data/node_modules ]; then
        ln -s "$MODULE_DIR" /mnt/data/node_modules 2>/dev/null || true
    fi
fi
"${SCRIPT_DIR}/bun" run "$@"
EOF
    chmod 0755 "$launcher"
    mv -f "$launcher" "${destination}/run"
}

if [ -f "$MARKER_FILE" ] && [ "$FORCE_REBUILD" != "true" ]; then
    if packages_ready; then
        write_node_launcher "/pkgs/node/${NODE_VERSION}"
        write_bun_launcher "/pkgs/bun/${BUN_VERSION}"
        echo "Packages already initialized (marker file exists)"
        echo "Set FORCE_REBUILD=true to force reinstall"
        echo ""
        echo "Installed packages:"
        ls -la /pkgs/ 2>/dev/null || echo "  (none)"
        exit 0
    fi
    echo "Initialization marker exists, but one or more required packages are missing"
    echo "Continuing package initialization"
fi

if [ "$FORCE_REBUILD" = "true" ] && [ -d "/pkgs" ]; then
    echo "Force rebuild requested, cleaning existing packages..."
    rm -rf /pkgs/* /pkgs/.initialized
fi

# ==============================
# Install Python
# ==============================
echo ""
echo "=============================================="
echo "  Installing Python ${PYTHON_VERSION}"
echo "=============================================="
echo ""

PKG_DEST="/pkgs/python/${PYTHON_VERSION}"
mkdir -p "$PKG_DEST"
rm -f "$PKG_DEST/.package-installed"

cd /tmp
wget -q "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz"
tar xf "Python-${PYTHON_VERSION}.tar.xz"
cd "Python-${PYTHON_VERSION}"
./configure --prefix="$PKG_DEST" --enable-optimizations 2>/dev/null
make -j$(nproc)
make install
"${PKG_DEST}/bin/python3" "${SCRIPT_DIR}/python-runtime/install.py"
cd /tmp
rm -rf /tmp/Python-${PYTHON_VERSION}*

cat > "$PKG_DEST/pkg-info.json" << EOF
{
    "language": "python",
    "version": "${PYTHON_VERSION}",
    "build_platform": "docker-debian",
    "aliases": ["py", "py3", "python3", "${PYTHON_ALIAS}"]
}
EOF

cat > "$PKG_DEST/run" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/bin/python3" "$@"
EOF
chmod +x "$PKG_DEST/run"

echo "PATH=${PKG_DEST}/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:." > "$PKG_DEST/.env"

echo "Python ${PYTHON_VERSION} installed"

# ==============================
# Install Python packages
# ==============================
echo ""
echo "=============================================="
echo "  Installing Python packages"
echo "=============================================="
echo ""

PIP_PATH="${PKG_DEST}/bin/pip3"
if [ -f "$PIP_PATH" ]; then
    "$PIP_PATH" install --upgrade pip 2>/dev/null || true
    PYTHON_PACKAGES_INSTALLED=false

    PYTHON_INSTALL_CMD=("$PIP_PATH" install)
    if [ "$PYTHON_PACKAGE_INSTALLER" = "uv" ]; then
        "$PIP_PATH" install "uv==${UV_VERSION}" 2>/dev/null || true
        PYTHON_INSTALL_CMD=("${PKG_DEST}/bin/uv" pip install --python "${PKG_DEST}/bin/python3")
    fi

    # MarkItDown 0.1.x initializes Magika/ONNX at import time; the aarch64
    # onnxruntime wheel segfaults under NsJail. 0.0.2 still supports PPTX via
    # python-pptx without that native dependency.
    if ! "${PYTHON_INSTALL_CMD[@]}" \
        openpyxl \
        matplotlib \
        numpy \
        pandas \
        lifelines \
        scipy \
        statsmodels \
        pillow \
        scikit-learn \
        scikit-image \
        networkx \
        sympy \
        wordcloud \
        pypdf2 \
        python-docx \
        imageio \
        seaborn \
        plotly \
        beautifulsoup4 \
        tabulate \
        xlrd \
        numba \
        patsy \
        numexpr \
        pyarrow \
        chdb==4.1.6 \
        markitdown==0.0.2 \
        python-pptx \
        xlsxwriter \
        docx2python \
        docxtpl \
        mammoth \
        pdf2image \
        "pdfminer.six" \
        reportlab \
        opencv-python-headless \
        svglib \
        cairosvg \
        exifread \
        hachoir \
        python-barcode \
        qrcode \
        fonttools \
        pytesseract \
        pdfminer \
        vsdx \
        rasterio \
        rioxarray \
        geopandas \
        pyogrio \
        pyproj \
        osmnx \
        folium \
        gpxpy; then
        echo "ERROR: Python package installation failed"
        INSTALL_FAILED=true
    else
        PYTHON_PACKAGES_INSTALLED=true
    fi

    "$PIP_PATH" install --upgrade six 2>/dev/null || true
    if [ "$PYTHON_PACKAGES_INSTALLED" = true ]; then
        echo "$(date +%s)000" > "$PKG_DEST/.package-installed"
    fi

    echo ""
    echo "Installed Python packages:"
    "$PIP_PATH" list 2>/dev/null | head -20
else
    echo "ERROR: pip not found at $PIP_PATH"
    INSTALL_FAILED=true
fi

# ==============================
# Install Node.js
# ==============================
echo ""
echo "=============================================="
echo "  Installing Node.js ${NODE_VERSION}"
echo "=============================================="
echo ""

NODE_DEST="/pkgs/node/${NODE_VERSION}"
mkdir -p "$NODE_DEST"
rm -f "$NODE_DEST/.package-installed"
NODE_INSTALLED=false

ARCH=$(uname -m)
case "$ARCH" in
    x86_64) NODE_ARCH="x64" ;;
    aarch64|arm64) NODE_ARCH="arm64" ;;
    *)
        echo "ERROR: Unsupported architecture for Node.js: $ARCH"
        NODE_ARCH=""
        INSTALL_FAILED=true
        ;;
esac

if [ -n "$NODE_ARCH" ]; then
    NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"
    cd /tmp
    if curl -fsSL "$NODE_URL" -o node.tar.xz; then
        if tar -xJf node.tar.xz --strip-components=1 -C "$NODE_DEST"; then
            rm -f node.tar.xz

            cat > "$NODE_DEST/pkg-info.json" << EOF
{
    "language": "node",
    "version": "${NODE_VERSION}",
    "build_platform": "docker-debian",
    "aliases": ["nodejs", "node-js", "node-javascript"]
}
EOF

            write_node_launcher "$NODE_DEST"

            {
                echo "PATH=${NODE_DEST}/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:."
                echo "NODE_PATH=${NODE_DEST}/node_modules"
            } > "$NODE_DEST/.env"

            NODE_INSTALLED=true
            echo "Node.js ${NODE_VERSION} installed: $($NODE_DEST/bin/node --version)"
        else
            echo "ERROR: Failed to extract Node.js archive"
            rm -f node.tar.xz
            INSTALL_FAILED=true
        fi
    else
        echo "ERROR: Failed to download Node.js"
        INSTALL_FAILED=true
    fi
fi

# ==============================
# Install JavaScript packages for Node.js
# ==============================
echo ""
echo "=============================================="
echo "  Installing Node.js packages"
echo "=============================================="
echo ""

NODE_NPM="${NODE_DEST}/bin/npm"
if [ "$NODE_INSTALLED" = true ] && [ "${#JS_PACKAGES[@]}" -gt 0 ] && [ -f "$NODE_NPM" ]; then
    if ! PATH="${NODE_DEST}/bin:$PATH" "$NODE_NPM" install \
        --prefix "$NODE_DEST" \
        --omit=dev \
        --no-audit \
        --no-fund \
        --save-exact \
        --package-lock=false \
        "${JS_PACKAGES[@]}"; then
        echo "ERROR: Node.js package installation failed"
        INSTALL_FAILED=true
    else
        echo "$(date +%s)000" > "$NODE_DEST/.package-installed"
    fi

    echo ""
    echo "Installed Node.js packages:"
    PATH="${NODE_DEST}/bin:$PATH" "$NODE_NPM" ls --prefix "$NODE_DEST" --depth=0 2>/dev/null | head -40 || true
elif [ "$NODE_INSTALLED" = true ] && [ "${#JS_PACKAGES[@]}" -eq 0 ]; then
    echo "ERROR: No JavaScript packages loaded for Node.js"
    INSTALL_FAILED=true
elif [ "$NODE_INSTALLED" = true ]; then
    echo "ERROR: npm not found at $NODE_NPM"
    INSTALL_FAILED=true
else
    echo "Skipping Node.js package installation because Node.js was not installed"
fi

# ==============================
# Install Bun
# ==============================
echo ""
echo "=============================================="
echo "  Installing Bun ${BUN_VERSION}"
echo "=============================================="
echo ""

BUN_DEST="/pkgs/bun/${BUN_VERSION}"
mkdir -p "$BUN_DEST"
rm -f "$BUN_DEST/.package-installed"
BUN_INSTALLED=false

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  BUN_ARCH="x64" ;;
    aarch64|arm64) BUN_ARCH="aarch64" ;;
    *)
        echo "ERROR: Unsupported architecture for Bun: $ARCH"
        BUN_ARCH=""
        INSTALL_FAILED=true
        ;;
esac

if [ -n "$BUN_ARCH" ]; then
    BUN_URL="https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-${BUN_ARCH}.zip"
    cd /tmp
    if curl -fsSL "$BUN_URL" -o bun.zip; then
        if unzip -o bun.zip && mv bun-linux-${BUN_ARCH}/bun "$BUN_DEST/"; then
            chmod +x "$BUN_DEST/bun"
            rm -rf bun.zip bun-linux-${BUN_ARCH}

            cat > "$BUN_DEST/pkg-info.json" << EOF
{
    "language": "bun",
    "version": "${BUN_VERSION}",
    "build_platform": "docker-debian",
    "provides": [
        { "language": "typescript", "aliases": ["bun-ts"] },
        { "language": "javascript", "aliases": ["bun-js"] }
    ]
}
EOF

            write_bun_launcher "$BUN_DEST"

            {
                echo "PATH=${BUN_DEST}:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:."
                echo "NODE_PATH=${BUN_DEST}/node_modules"
            } > "$BUN_DEST/.env"

            BUN_INSTALLED=true
            echo "Bun ${BUN_VERSION} installed: $($BUN_DEST/bun --version)"
        else
            echo "ERROR: Failed to extract Bun archive"
            rm -rf bun.zip bun-linux-${BUN_ARCH}
            INSTALL_FAILED=true
        fi
    else
        echo "ERROR: Failed to download Bun"
        INSTALL_FAILED=true
    fi
fi

# ==============================
# Install JavaScript packages for Bun
# ==============================
echo ""
echo "=============================================="
echo "  Installing Bun packages"
echo "=============================================="
echo ""

if [ "$BUN_INSTALLED" = true ] && [ "${#JS_PACKAGES[@]}" -gt 0 ] && [ -f "$BUN_DEST/bun" ]; then
    cd "$BUN_DEST"
    BUN_BATCH_FAILED=false
    if ! BUN_PACKAGE_BATCH_SIZE="$(validate_bun_package_batch_size)"; then
        INSTALL_FAILED=true
    else
        BUN_BATCH_COUNT=$(( (${#JS_PACKAGES[@]} + BUN_PACKAGE_BATCH_SIZE - 1) / BUN_PACKAGE_BATCH_SIZE ))
        BUN_BATCH_INDEX=1

        for ((i = 0; i < ${#JS_PACKAGES[@]}; i += BUN_PACKAGE_BATCH_SIZE)); do
            echo "Installing Bun package batch ${BUN_BATCH_INDEX}/${BUN_BATCH_COUNT}"
            if ! BUN_CONFIG_MAX_HTTP_REQUESTS="${BUN_CONFIG_MAX_HTTP_REQUESTS:-8}" ./bun add --exact "${JS_PACKAGES[@]:i:BUN_PACKAGE_BATCH_SIZE}"; then
                BUN_BATCH_FAILED=true
                break
            fi
            BUN_BATCH_INDEX=$((BUN_BATCH_INDEX + 1))
        done

        if [ "$BUN_BATCH_FAILED" = true ]; then
            echo "ERROR: Bun package installation failed"
            INSTALL_FAILED=true
        else
            echo "$(date +%s)000" > "$BUN_DEST/.package-installed"
        fi
    fi

    echo ""
    echo "Installed Bun packages:"
    ./bun pm ls --depth 0 2>/dev/null | head -40 || true
elif [ "$BUN_INSTALLED" = true ] && [ "${#JS_PACKAGES[@]}" -eq 0 ]; then
    echo "ERROR: No JavaScript packages loaded for Bun"
    INSTALL_FAILED=true
elif [ "$BUN_INSTALLED" = true ]; then
    echo "ERROR: bun not found at $BUN_DEST/bun"
    INSTALL_FAILED=true
else
    echo "Skipping Bun package installation because Bun was not installed"
fi

# ==============================
# Register Bash
# ==============================
echo ""
echo "=============================================="
echo "  Registering Bash"
echo "=============================================="
echo ""

SYSTEM_BASH_VERSION=$(bash --version | sed -nE '1s/.* ([0-9]+[.][0-9]+[.][0-9]+).*/\1/p')
BASH_DEST="/pkgs/bash/${BASH_PACKAGE_VERSION}"
mkdir -p "$BASH_DEST"

cat > "$BASH_DEST/pkg-info.json" << EOF
{
    "language": "bash",
    "version": "${BASH_PACKAGE_VERSION}",
    "build_platform": "docker-debian",
    "system_version": "${SYSTEM_BASH_VERSION}",
    "aliases": ["sh"]
}
EOF

cat > "$BASH_DEST/run" << 'EOF'
#!/bin/bash
bash "$@"
EOF
chmod +x "$BASH_DEST/run"

echo "PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:." > "$BASH_DEST/.env"
echo "$(date +%s)000" > "$BASH_DEST/.package-installed"

echo "Bash ${BASH_PACKAGE_VERSION} registered (using system binary ${SYSTEM_BASH_VERSION})"

# ==============================
# Install R
# ==============================
echo ""
echo "=============================================="
echo "  Installing R ${R_VERSION}"
echo "=============================================="
echo ""

# R is installed from the Posit r-builds Debian package rather than from
# Debian's own r-base (4.2.x on bookworm) or from source. CRAN serves no arm64
# Linux binaries at all, and arm64 is mandatory for the Lambda MicroVM sandbox,
# so this is the only route to a current R that does not add a ~15 minute
# source build to every image rebuild.
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)        R_ARCH="amd64" ;;
    aarch64|arm64) R_ARCH="arm64" ;;
    *)
        echo "ERROR: Unsupported architecture for R: $ARCH"
        R_ARCH=""
        INSTALL_FAILED=true
        ;;
esac

R_DEST="/pkgs/r/${R_VERSION}"

# Posit publishes one build per Debian release and they are NOT interchangeable.
# The bookworm build installs cleanly on trixie — apt resolves every dependency —
# and then fails at run time with "libtirpc.so.3: cannot open shared object
# file", because the t64 transition renamed the package that ships it. An
# install that succeeds and a binary that cannot start is the worst failure mode
# available, so pick the build by the release actually running this script
# rather than hardcoding one: api/Dockerfile's package-builder is bookworm,
# while the BU sandbox stages are trixie.
if [ -z "${R_DEB_DISTRO:-}" ]; then
    r_os_version=$( . /etc/os-release 2>/dev/null && printf '%s' "${VERSION_ID:-}" )
    case "$r_os_version" in
        12) R_DEB_DISTRO="debian-12" ;;
        13) R_DEB_DISTRO="debian-13" ;;
        *)
            echo "ERROR: No known Posit R build for Debian VERSION_ID='${r_os_version}'."
            echo "       Set R_DEB_DISTRO explicitly if a build exists for it."
            R_ARCH=""
            INSTALL_FAILED=true
            ;;
    esac
fi

if [ -n "$R_ARCH" ]; then
    R_DEB_URL="https://cdn.posit.co/r/${R_DEB_DISTRO}/pkgs/r-${R_VERSION}_1_${R_ARCH}.deb"
    rm -rf "$R_DEST"
    mkdir -p /pkgs/r

    if curl -fsSL -o /tmp/r.deb "$R_DEB_URL" \
        && apt-install /tmp/r.deb; then
        rm -f /tmp/r.deb

        # The package installs under /opt, which is not mounted inside the
        # NsJail mount namespace — only /usr and the selected runtime's
        # directory under /pkgs are. Move it where the jail can see it.
        mv "/opt/R/${R_VERSION}" "$R_DEST"
        rmdir /opt/R 2>/dev/null || true

        # R_HOME is baked into these text files at package build time. The
        # verification below is what keeps this list honest — add to it there
        # rather than trusting this list to stay complete.
        for relative in \
            bin/R \
            lib/R/bin/R \
            lib/R/etc/Makeconf \
            lib/R/etc/ldpaths \
            lib/pkgconfig/libR.pc
        do
            if [ -f "${R_DEST}/${relative}" ]; then
                sed -i "s|/opt/R/${R_VERSION}|${R_DEST}|g" "${R_DEST}/${relative}"
            fi
        done

        # The stock Rscript is an ELF with R_HOME compiled in; it ignores the
        # R_HOME environment variable and execs the old /opt path, so it cannot
        # be relocated. Replace it with a wrapper over the (patched) R shell
        # script, which honours the relocation.
        #
        # Both copies must be replaced. R ships one at bin/Rscript for users
        # and one at lib/R/bin/Rscript, and package build scripts call the
        # latter through R_HOME. Leaving it unpatched silently breaks any
        # package whose configure step shells out to Rscript (fs, sass,
        # htmlwidgets, ...) and everything depending on them, while packages
        # that build without it install fine — so the damage is partial and
        # easy to miss.
        for rscript in "${R_DEST}/bin/Rscript" "${R_DEST}/lib/R/bin/Rscript"; do
            cat > "$rscript" << RSCRIPT
#!/bin/bash
R_BIN="${R_DEST}/bin/R"
# Same reasoning as the run launcher: package build scripts call this directly
# through R_HOME, where no .env has been applied.
export LD_LIBRARY_PATH="${R_DEST}/lib/R/lib:${R_DEST}/syslib\${LD_LIBRARY_PATH:+:}\${LD_LIBRARY_PATH}"
if [ "\$#" -eq 0 ] || [ "\${1#-}" != "\$1" ]; then
    # No file argument, or a flag such as -e: hand through unchanged.
    exec "\$R_BIN" --no-echo --no-restore "\$@"
fi
script="\$1"
shift
exec "\$R_BIN" --no-echo --no-restore --file="\$script" --args "\$@"
RSCRIPT
            chmod +x "$rscript"
        done

        # Nothing else may still point at the pre-relocation prefix: a missed
        # file fails later, during a package build or at run time, with an
        # error that names neither R nor the path.
        if grep -rl "/opt/R/${R_VERSION}" "$R_DEST" >/dev/null 2>&1; then
            echo "ERROR: files still reference /opt/R/${R_VERSION} after relocation:"
            grep -rl "/opt/R/${R_VERSION}" "$R_DEST" | sed "s|^|  |"
            INSTALL_FAILED=true
        fi

        mkdir -p "${R_DEST}/lib/R/site-library"
        echo "R ${R_VERSION} installed to ${R_DEST}"
    else
        echo "ERROR: Failed to install R from ${R_DEB_URL}"
        INSTALL_FAILED=true
        R_ARCH=""
    fi
fi

# ==============================
# Install R packages
# ==============================
if [ -n "$R_ARCH" ]; then
    echo ""
    echo "=============================================="
    echo "  Installing R packages (${R_PACKAGE_SET})"
    echo "=============================================="
    echo ""

    if [ ! -f "$R_PACKAGE_MANIFEST" ]; then
        echo "ERROR: Missing R package manifest: $R_PACKAGE_MANIFEST"
        INSTALL_FAILED=true
    else
        R_PACKAGES=()
        while IFS= read -r package_spec || [ -n "$package_spec" ]; do
            # The extended tier starts at its header; stop there for "core".
            if [[ "$package_spec" =~ ^[[:space:]]*#[[:space:]]*---[[:space:]]*extended ]]; then
                [ "$R_PACKAGE_SET" = "core" ] && break
                continue
            fi
            [[ "$package_spec" =~ ^[[:space:]]*(#|$) ]] && continue
            R_PACKAGES+=("$package_spec")
        done < "$R_PACKAGE_MANIFEST"

        if [ ${#R_PACKAGES[@]} -eq 0 ]; then
            echo "ERROR: No R packages listed in $R_PACKAGE_MANIFEST"
            INSTALL_FAILED=true
        else
            echo "Installing ${#R_PACKAGES[@]} R packages from ${R_CRAN_REPO}"
            R_PACKAGE_VECTOR=$(printf '"%s",' "${R_PACKAGES[@]}")
            R_PACKAGE_VECTOR="${R_PACKAGE_VECTOR%,}"

            # Driven from a script file rather than -e: the installer is
            # multi-statement, and --file has unambiguous parsing.
            #
            # Ncpus parallelises independent packages. The explicit check
            # afterwards is required because install.packages() reports a
            # failed build as a warning and still exits 0.
            cat > /tmp/install-r-packages.R << RINSTALL
pkgs <- c(${R_PACKAGE_VECTOR})
lib <- "${R_DEST}/lib/R/site-library"
install.packages(pkgs,
                 repos = "${R_CRAN_REPO}",
                 lib = lib,
                 Ncpus = max(1L, parallel::detectCores()))
missing <- pkgs[!pkgs %in% rownames(installed.packages(lib.loc = lib))]
if (length(missing)) {
    cat("FAILED R packages:", paste(missing, collapse = ", "), "\n")
    quit(status = 1L)
}
cat("All", length(pkgs), "R packages installed\n")
RINSTALL

            if "${R_DEST}/bin/R" --no-echo --no-restore --file=/tmp/install-r-packages.R; then
                echo "R packages installed"
            else
                echo "ERROR: One or more R packages failed to install"
                INSTALL_FAILED=true
            fi
            rm -f /tmp/install-r-packages.R
        fi
    fi
fi

# ==============================
# Register R
# ==============================
if [ -n "$R_ARCH" ] && [ "$INSTALL_FAILED" != true ]; then
    echo ""
    echo "=============================================="
    echo "  Registering R"
    echo "=============================================="
    echo ""

    # R is built here on Debian 12 but runs in a Debian 13 sandbox image, and
    # the jail exposes no /usr from this builder. Carry every shared object R
    # resolves outside /pkgs so the runtime depends on nothing in the final
    # image. glibc, libgcc and libstdc++ are deliberately excluded: those must
    # come from the running image, which is never older than this builder.
    mkdir -p "${R_DEST}/syslib"
    find "$R_DEST" -type f \( -name '*.so' -o -name '*.so.*' -o -path '*/bin/exec/R' \) -print0 \
        | xargs -0 -r -n1 ldd 2>/dev/null \
        | awk '/=> \// {print $3}' \
        | sort -u \
        | grep -v '^/pkgs' \
        | grep -vE '/(ld-linux[^/]*|libc|libm|libdl|libpthread|librt|libresolv|libgcc_s|libstdc\+\+)\.so' \
        > /tmp/r-syslibs.txt
    while IFS= read -r lib; do
        [ -n "$lib" ] && cp -Ln "$lib" "${R_DEST}/syslib/" 2>/dev/null || true
    done < /tmp/r-syslibs.txt
    echo "Carried $(ls -1 "${R_DEST}/syslib" | wc -l) shared libraries into ${R_DEST}/syslib"
    rm -f /tmp/r-syslibs.txt

    cat > "$R_DEST/pkg-info.json" << EOF
{
    "language": "r",
    "version": "${R_VERSION}",
    "build_platform": "docker-debian",
    "aliases": ["rscript", "rstats"]
}
EOF

    # The launcher sets R_HOME and LD_LIBRARY_PATH itself rather than trusting
    # the caller to have applied .env. R is the only runtime here that cannot
    # even start without LD_LIBRARY_PATH: the build purges the toolchain, so
    # libblas, liblapack and libgfortran exist ONLY in syslib, and exec/R dies
    # with "libblas.so.3: cannot open shared object file" before any R code
    # runs. Every other runtime needs no more than PATH, which the shell
    # resolves anyway, so for them a dropped .env degrades quietly; for R it is
    # fatal and the message names neither R nor the missing environment.
    # R's own lib/R/etc/ldpaths appends whatever it inherits, so exporting here
    # composes with it instead of fighting it. .env is kept as well.
    cat > "$R_DEST/run" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export R_HOME="${SCRIPT_DIR}/lib/R"
export R_LIBS_SITE="${SCRIPT_DIR}/lib/R/site-library"
export LD_LIBRARY_PATH="${SCRIPT_DIR}/lib/R/lib:${SCRIPT_DIR}/syslib${LD_LIBRARY_PATH:+:}${LD_LIBRARY_PATH}"
exec "${SCRIPT_DIR}/bin/Rscript" "$@"
EOF
    chmod +x "$R_DEST/run"

    # R_HOME and LD_LIBRARY_PATH are required because the install is relocated
    # away from its compiled-in prefix. OPENBLAS/OMP thread counts are left to
    # the sandbox defaults (1), which keeps BLAS from forking past the jail's
    # process limit.
    {
        echo "PATH=${R_DEST}/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:."
        echo "R_HOME=${R_DEST}/lib/R"
        echo "LD_LIBRARY_PATH=${R_DEST}/lib/R/lib:${R_DEST}/syslib"
        echo "R_LIBS_SITE=${R_DEST}/lib/R/site-library"
    } > "$R_DEST/.env"

    echo "$(date +%s)000" > "$R_DEST/.package-installed"

    echo "R ${R_VERSION} registered"
fi

# ==============================
# Finalize
# ==============================
echo ""
echo "=============================================="
echo "  Finalizing"
echo "=============================================="
echo ""

echo "Setting permissions..."
chmod -R a+rX /pkgs/ 2>/dev/null || true

if [ "$INSTALL_FAILED" = true ]; then
    echo ""
    echo "=============================================="
    echo "  ERROR: Package initialization FAILED"
    echo "=============================================="
    echo ""
    echo "One or more packages failed to install."
    echo "Marker file NOT created -- next run will retry."
    echo ""
    echo "Partial packages on disk:"
    ls -la /pkgs/
    echo ""
    exit 1
fi

echo "Creating initialization marker..."
cat > "$MARKER_FILE" << MARKER
initialized_at=$(date -Iseconds)
python_version=${PYTHON_VERSION}
node_version=${NODE_VERSION}
bun_version=${BUN_VERSION}
r_version=${R_VERSION}
packages=$(ls /pkgs/ 2>/dev/null | tr '\n' ',')
MARKER

echo ""
echo "=============================================="
echo "  Package initialization complete!"
echo "=============================================="
echo ""
echo "Installed packages:"
ls -la /pkgs/
echo ""
