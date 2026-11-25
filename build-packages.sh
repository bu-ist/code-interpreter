#!/usr/bin/env bash
#
# Package builder for Code Interpreter API
# Installs Python, Node, Bun, and Bash runtime packages for the NsJail sandbox.
# Works on both arm64 (Apple Silicon) and amd64 (Linux/WSL).
#
# Usage:
#   ./build-packages.sh              # Build all packages
#
# Environment Variables:
#   PYTHON_VERSION=3.14.4    # Python version to install
#   NODE_VERSION=24.22.1     # Node.js version to install
#   BUN_VERSION=1.4.4       # Bun version to install
#   BASH_PACKAGE_VERSION=5.2.0 # Bash package registration version (semver-like x.y.z)
#   SKIP_PYTHON_PACKAGES=1   # Skip Python pip packages
#   SKIP_JS_PACKAGES=1       # Skip JavaScript npm packages for Node/Bun
#   SKIP_NODE=1              # Skip Node.js installation
#   SKIP_BUN=1               # Skip Bun installation
#   SKIP_PYTHON=1            # Skip Python installation
#   FORCE_REBUILD=1          # Delete existing packages first
#   BUN_PACKAGE_BATCH_SIZE=4 # Positive integer number of direct JS packages per Bun install batch
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PYTHON_VERSION="${PYTHON_VERSION:-3.14.4}"
NODE_VERSION="${NODE_VERSION:-24.22.1}"
BUN_VERSION="${BUN_VERSION:-1.4.4}"
R_VERSION="${R_VERSION:-4.5.2}"
PACKAGES_DIR="./data/pkgs"
JS_PACKAGE_MANIFEST="${JS_PACKAGE_MANIFEST:-${SCRIPT_DIR}/javascript-packages.txt}"
R_PACKAGE_MANIFEST="${R_PACKAGE_MANIFEST:-${SCRIPT_DIR}/r-packages.txt}"
# Keep these aligned with docker/package-init.sh, which is the implementation
# the deployed images use. This script is the local-developer path only.
R_CRAN_REPO="${R_CRAN_REPO:-https://packagemanager.posit.co/cran/2026-11-03}"
R_PACKAGE_SET="${R_PACKAGE_SET:-core}"

load_js_packages() {
    if [ ! -f "$JS_PACKAGE_MANIFEST" ]; then
        echo "Missing JavaScript package manifest: $JS_PACKAGE_MANIFEST"
        exit 1
    fi

    JS_PACKAGES=()
    while IFS= read -r package_spec || [ -n "$package_spec" ]; do
        [[ "$package_spec" =~ ^[[:space:]]*(#|$) ]] && continue
        JS_PACKAGES+=("$package_spec")
    done < "$JS_PACKAGE_MANIFEST"
    if [ "${#JS_PACKAGES[@]}" -eq 0 ]; then
        echo "JavaScript package manifest is empty: $JS_PACKAGE_MANIFEST"
        exit 1
    fi
}

should_load_js_packages() {
    [ "${SKIP_JS_PACKAGES:-}" != "1" ] &&
        { [ "${SKIP_NODE:-}" != "1" ] || [ "${SKIP_BUN:-}" != "1" ]; }
}

validate_bun_package_batch_size() {
    local batch_size="${BUN_PACKAGE_BATCH_SIZE:-4}"
    if [[ ! "$batch_size" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: BUN_PACKAGE_BATCH_SIZE must be a positive integer (got: ${batch_size})" >&2
        return 1
    fi
    printf '%s\n' "$batch_size"
}

if should_load_js_packages; then
    load_js_packages
else
    JS_PACKAGES=()
fi

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  BUN_ARCH="x64"; NODE_ARCH="x64"; R_ARCH="amd64"; echo "Detected: amd64 (Linux/WSL)" ;;
    arm64|aarch64) BUN_ARCH="aarch64"; NODE_ARCH="arm64"; R_ARCH="arm64"; echo "Detected: arm64 (Apple Silicon)" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

if [ "${FORCE_REBUILD:-}" = "1" ]; then
    echo "Force rebuild requested, cleaning existing packages..."
    docker run --rm -v "$PWD/data/pkgs:/pkgs" alpine sh -c "rm -rf /pkgs/*" 2>/dev/null || rm -rf "$PACKAGES_DIR"/*
fi

mkdir -p "$PACKAGES_DIR"

CONTAINER_NAME="pkg-builder-$$"
cleanup() {
    echo "Cleaning up..."
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

install_python() {
    if [ "${SKIP_PYTHON:-}" = "1" ]; then
        echo "Skipping Python (SKIP_PYTHON=1)"
        return 0
    fi

    local pkg_dest="/pkgs/python/${PYTHON_VERSION}"
    local python_minor="${PYTHON_VERSION%.*}"

    echo "=============================================="
    echo "  Installing Python ${PYTHON_VERSION}"
    echo "=============================================="

    docker exec "$CONTAINER_NAME" bash -c "
        set -e
        mkdir -p ${pkg_dest}
        rm -f ${pkg_dest}/.package-installed
        cd /tmp
        wget -q https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz
        tar xf Python-${PYTHON_VERSION}.tar.xz
        cd Python-${PYTHON_VERSION}
        ./configure --prefix=${pkg_dest} --enable-optimizations 2>/dev/null
        make -j\$(nproc)
        make install
        rm -rf /tmp/Python-${PYTHON_VERSION}*
    "

    docker cp "$SCRIPT_DIR/docker/python-runtime" "$CONTAINER_NAME:/tmp/python-runtime"
    docker exec "$CONTAINER_NAME" "${pkg_dest}/bin/python3" /tmp/python-runtime/install.py

    docker exec "$CONTAINER_NAME" bash -c "cat > ${pkg_dest}/pkg-info.json << 'EOF'
{
    \"language\": \"python\",
    \"version\": \"${PYTHON_VERSION}\",
    \"build_platform\": \"docker-debian\",
    \"aliases\": [\"py\", \"py3\", \"python3\", \"python${python_minor}\"]
}
EOF"

    docker exec "$CONTAINER_NAME" bash -c "cat > ${pkg_dest}/run << 'EOF'
#!/bin/bash
SCRIPT_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")\" && pwd)\"
\"\${SCRIPT_DIR}/bin/python3\" \"\$@\"
EOF
chmod +x ${pkg_dest}/run"

    docker exec "$CONTAINER_NAME" bash -c "
        echo 'PATH=${pkg_dest}/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:.' > ${pkg_dest}/.env
    "

    if [ "${SKIP_PYTHON_PACKAGES:-}" = "1" ]; then
        docker exec "$CONTAINER_NAME" bash -c "echo \$(date +%s)000 > ${pkg_dest}/.package-installed"
    fi

    docker exec "$CONTAINER_NAME" "${pkg_dest}/bin/python3" -m pip install --upgrade pip 2>/dev/null || true

    echo "Python ${PYTHON_VERSION} installed"
}

install_python_packages() {
    if [ "${SKIP_PYTHON:-}" = "1" ] || [ "${SKIP_PYTHON_PACKAGES:-}" = "1" ]; then
        echo "Skipping Python packages (SKIP_PYTHON=1 or SKIP_PYTHON_PACKAGES=1)"
        return 0
    fi

    local pip_path="/pkgs/python/${PYTHON_VERSION}/bin/pip3"

    echo "=============================================="
    echo "  Installing Python packages"
    echo "=============================================="

    # MarkItDown 0.1.x initializes Magika/ONNX at import time; the aarch64
    # onnxruntime wheel segfaults under NsJail. 0.0.2 still supports PPTX via
    # python-pptx without that native dependency.
    local python_packages_installed=false
    if docker exec "$CONTAINER_NAME" "$pip_path" install \
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
        python_packages_installed=true
    else
        echo "ERROR: Python package installation failed"
        return 1
    fi

    docker exec "$CONTAINER_NAME" "$pip_path" install --upgrade six 2>/dev/null || true
    if [ "$python_packages_installed" = true ]; then
        docker exec "$CONTAINER_NAME" bash -c "echo \$(date +%s)000 > /pkgs/python/${PYTHON_VERSION}/.package-installed"
    fi

    echo "Installed Python packages:"
    docker exec "$CONTAINER_NAME" "$pip_path" list 2>/dev/null | head -20
}

install_node() {
    if [ "${SKIP_NODE:-}" = "1" ]; then
        echo "Skipping Node.js (SKIP_NODE=1)"
        return 0
    fi

    local pkg_dest="/pkgs/node/${NODE_VERSION}"

    echo "=============================================="
    echo "  Installing Node.js ${NODE_VERSION}"
    echo "=============================================="

    docker exec "$CONTAINER_NAME" bash -c "
        set -e
        mkdir -p ${pkg_dest}
        rm -f ${pkg_dest}/.package-installed
        cd /tmp
        curl -fsSL -o node.tar.xz https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz
        tar -xJf node.tar.xz --strip-components=1 -C ${pkg_dest}
        rm -f node.tar.xz
    "

    docker exec "$CONTAINER_NAME" bash -c "cat > ${pkg_dest}/pkg-info.json << 'EOF'
{
    \"language\": \"node\",
    \"version\": \"${NODE_VERSION}\",
    \"build_platform\": \"docker-debian\",
    \"aliases\": [\"nodejs\", \"node-js\", \"node-javascript\"]
}
EOF"

    docker exec "$CONTAINER_NAME" bash -c "cat > ${pkg_dest}/run << 'EOF'
#!/bin/bash
SCRIPT_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")\" && pwd)\"
MODULE_DIR=\"\${SCRIPT_DIR}/node_modules\"
if [ -d \"\${MODULE_DIR}\" ]; then
    if [ -L /mnt/data/node_modules ]; then
        LINK_TARGET=\"\$(readlink -m /mnt/data/node_modules)\"
        if [ \"\${LINK_TARGET}\" != \"\${MODULE_DIR}\" ]; then
            case \"\${LINK_TARGET}\" in
                \"\${SCRIPT_DIR%/*/*}/\"*/node_modules)
                    ln -sfnT \"\${MODULE_DIR}\" /mnt/data/node_modules ;;
            esac
        fi
    elif [ ! -e /mnt/data/node_modules ]; then
        ln -s \"\${MODULE_DIR}\" /mnt/data/node_modules 2>/dev/null || true
    fi
fi
\"\${SCRIPT_DIR}/bin/node\" \"\$@\"
EOF
chmod +x ${pkg_dest}/run"

    docker exec "$CONTAINER_NAME" bash -c "
        echo 'PATH=${pkg_dest}/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:.' > ${pkg_dest}/.env
        echo 'NODE_PATH=${pkg_dest}/node_modules' >> ${pkg_dest}/.env
    "

    if [ "${SKIP_JS_PACKAGES:-}" = "1" ]; then
        docker exec "$CONTAINER_NAME" bash -c "echo \$(date +%s)000 > ${pkg_dest}/.package-installed"
    fi

    echo "Node.js ${NODE_VERSION} installed: $(docker exec "$CONTAINER_NAME" "${pkg_dest}/bin/node" --version)"
}

install_node_packages() {
    if [ "${SKIP_NODE:-}" = "1" ] || [ "${SKIP_JS_PACKAGES:-}" = "1" ]; then
        echo "Skipping Node.js packages (SKIP_NODE=1 or SKIP_JS_PACKAGES=1)"
        return 0
    fi

    local pkg_dest="/pkgs/node/${NODE_VERSION}"
    local npm_path="${pkg_dest}/bin/npm"

    echo "=============================================="
    echo "  Installing Node.js packages"
    echo "=============================================="

    docker exec "$CONTAINER_NAME" env "PATH=${pkg_dest}/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:." "$npm_path" install \
        --prefix "$pkg_dest" \
        --omit=dev \
        --no-audit \
        --no-fund \
        --save-exact \
        --package-lock=false \
        "${JS_PACKAGES[@]}"

    # Mirror the manifest into npm's global tree (${pkg_dest}/lib/node_modules
    # + bin shims on PATH) so `npm list -g`, `npm root -g`, and CLI shims work
    # as LLMs expect. The local tree above is still what feeds the
    # /mnt/data/node_modules symlink used by `require()` from user code.
    docker exec "$CONTAINER_NAME" env "PATH=${pkg_dest}/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:." "$npm_path" install -g \
        --prefix "$pkg_dest" \
        --omit=dev \
        --no-audit \
        --no-fund \
        --save-exact \
        "${JS_PACKAGES[@]}"

    docker exec "$CONTAINER_NAME" bash -c "echo \$(date +%s)000 > ${pkg_dest}/.package-installed"

    echo "Installed Node.js packages (local):"
    docker exec "$CONTAINER_NAME" env "PATH=${pkg_dest}/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:." "$npm_path" ls --prefix "$pkg_dest" --depth=0 2>/dev/null | head -40 || true

    echo "Installed Node.js packages (global):"
    docker exec "$CONTAINER_NAME" env "PATH=${pkg_dest}/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:." "$npm_path" ls -g --prefix "$pkg_dest" --depth=0 2>/dev/null | head -40 || true
}

install_bun() {
    if [ "${SKIP_BUN:-}" = "1" ]; then
        echo "Skipping Bun (SKIP_BUN=1)"
        return 0
    fi

    local pkg_dest="/pkgs/bun/${BUN_VERSION}"

    echo "=============================================="
    echo "  Installing Bun ${BUN_VERSION}"
    echo "=============================================="

    docker exec "$CONTAINER_NAME" bash -c "
        set -e
        mkdir -p ${pkg_dest}
        rm -f ${pkg_dest}/.package-installed
        cd /tmp
        curl -fsSL -o bun.zip https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-${BUN_ARCH}.zip
        unzip -o bun.zip
        mv bun-linux-${BUN_ARCH}/bun ${pkg_dest}/bun
        chmod +x ${pkg_dest}/bun
        rm -rf bun.zip bun-linux-${BUN_ARCH}
    "

    docker exec "$CONTAINER_NAME" bash -c "cat > ${pkg_dest}/pkg-info.json << 'EOF'
{
    \"language\": \"bun\",
    \"version\": \"${BUN_VERSION}\",
    \"build_platform\": \"docker-debian\",
    \"provides\": [
        { \"language\": \"typescript\", \"aliases\": [\"bun-ts\"] },
        { \"language\": \"javascript\", \"aliases\": [\"bun-js\"] }
    ]
}
EOF"

    docker exec "$CONTAINER_NAME" bash -c "cat > ${pkg_dest}/run << 'EOF'
#!/bin/bash
SCRIPT_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")\" && pwd)\"
MODULE_DIR=\"\${SCRIPT_DIR}/node_modules\"
if [ -d \"\${MODULE_DIR}\" ]; then
    if [ -L /mnt/data/node_modules ]; then
        LINK_TARGET=\"\$(readlink -m /mnt/data/node_modules)\"
        if [ \"\${LINK_TARGET}\" != \"\${MODULE_DIR}\" ]; then
            case \"\${LINK_TARGET}\" in
                \"\${SCRIPT_DIR%/*/*}/\"*/node_modules)
                    ln -sfnT \"\${MODULE_DIR}\" /mnt/data/node_modules ;;
            esac
        fi
    elif [ ! -e /mnt/data/node_modules ]; then
        ln -s \"\${MODULE_DIR}\" /mnt/data/node_modules 2>/dev/null || true
    fi
fi
\"\${SCRIPT_DIR}/bun\" run \"\$@\"
EOF
chmod +x ${pkg_dest}/run"

    docker exec "$CONTAINER_NAME" bash -c "
        echo 'PATH=${pkg_dest}/bin:${pkg_dest}:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:.' > ${pkg_dest}/.env
        echo 'NODE_PATH=${pkg_dest}/node_modules' >> ${pkg_dest}/.env
        echo 'BUN_INSTALL=${pkg_dest}' >> ${pkg_dest}/.env
    "

    if [ "${SKIP_JS_PACKAGES:-}" = "1" ]; then
        docker exec "$CONTAINER_NAME" bash -c "echo \$(date +%s)000 > ${pkg_dest}/.package-installed"
    fi

    echo "Bun ${BUN_VERSION} installed: $(docker exec "$CONTAINER_NAME" "${pkg_dest}/bun" --version)"
}

install_bun_packages() {
    if [ "${SKIP_BUN:-}" = "1" ] || [ "${SKIP_JS_PACKAGES:-}" = "1" ]; then
        echo "Skipping Bun packages (SKIP_BUN=1 or SKIP_JS_PACKAGES=1)"
        return 0
    fi

    local pkg_dest="/pkgs/bun/${BUN_VERSION}"
    local batch_size
    batch_size="$(validate_bun_package_batch_size)"
    local batch_index=1
    local batch_count=$(( (${#JS_PACKAGES[@]} + batch_size - 1) / batch_size ))

    echo "=============================================="
    echo "  Installing Bun packages"
    echo "=============================================="

    for ((i = 0; i < ${#JS_PACKAGES[@]}; i += batch_size)); do
        local batch_packages
        printf -v batch_packages "%q " "${JS_PACKAGES[@]:i:batch_size}"
        echo "Installing Bun package batch ${batch_index}/${batch_count}"
        docker exec "$CONTAINER_NAME" bash -c "
            set -e
            cd ${pkg_dest}
            BUN_CONFIG_MAX_HTTP_REQUESTS=${BUN_CONFIG_MAX_HTTP_REQUESTS:-8} ./bun add --exact ${batch_packages}
        "
        batch_index=$((batch_index + 1))
    done

    # Mirror the manifest into bun's global tree (BUN_INSTALL=${pkg_dest} ->
    # ${pkg_dest}/install/global/node_modules) so `bun pm ls -g`, `bun add -g`,
    # and global CLI shims at ${pkg_dest}/install/global/bin work as LLMs
    # expect. The local tree above is still what feeds the
    # /mnt/data/node_modules symlink used by `import` from user code.
    batch_index=1
    for ((i = 0; i < ${#JS_PACKAGES[@]}; i += batch_size)); do
        local batch_packages
        printf -v batch_packages "%q " "${JS_PACKAGES[@]:i:batch_size}"
        echo "Installing global Bun package batch ${batch_index}/${batch_count}"
        docker exec "$CONTAINER_NAME" bash -c "
            set -e
            cd ${pkg_dest}
            BUN_CONFIG_MAX_HTTP_REQUESTS=${BUN_CONFIG_MAX_HTTP_REQUESTS:-8} BUN_INSTALL=${pkg_dest} ./bun install -g --exact ${batch_packages}
        "
        batch_index=$((batch_index + 1))
    done

    docker exec "$CONTAINER_NAME" bash -c "echo \$(date +%s)000 > ${pkg_dest}/.package-installed"

    echo "Installed Bun packages (local):"
    docker exec "$CONTAINER_NAME" bash -c "cd ${pkg_dest} && ./bun pm ls --depth 0 2>/dev/null | head -40" || true

    echo "Installed Bun packages (global):"
    docker exec "$CONTAINER_NAME" bash -c "cd ${pkg_dest} && BUN_INSTALL=${pkg_dest} ./bun pm ls -g 2>/dev/null | head -40" || true
}

install_bash() {
    local bash_package_version
    bash_package_version="${BASH_PACKAGE_VERSION:-5.2.0}"
    local system_bash_version
    system_bash_version=$(docker exec "$CONTAINER_NAME" bash --version | head -1 | sed -E 's/.* ([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
    local pkg_dest="/pkgs/bash/${bash_package_version}"

    echo "=============================================="
    echo "  Registering Bash ${bash_package_version}"
    echo "=============================================="

    docker exec "$CONTAINER_NAME" bash -c "
        mkdir -p ${pkg_dest}
    "

    docker exec "$CONTAINER_NAME" bash -c "cat > ${pkg_dest}/pkg-info.json << 'PKGEOF'
{
    \"language\": \"bash\",
    \"version\": \"${bash_package_version}\",
    \"build_platform\": \"docker-debian\",
    \"system_version\": \"${system_bash_version}\",
    \"aliases\": [\"sh\"]
}
PKGEOF"

    docker exec "$CONTAINER_NAME" bash -c "cat > ${pkg_dest}/run << 'RUNEOF'
#!/bin/bash
bash \"\$@\"
RUNEOF
chmod +x ${pkg_dest}/run"

    # Surface node + bun toolchains and their global trees on PATH so bash
    # tool invocations (which is how LLMs typically reach for `npm list -g`,
    # `bun pm ls -g`, `handlebars`, etc.) discover the manifest packages.
    # BUN_INSTALL points bun at the bun runtime's BUN_INSTALL root so
    # `bun pm ls -g` resolves the offline globals instead of falling back
    # to ~/.bun/install/global.
    docker exec "$CONTAINER_NAME" bash -c "
        cat > ${pkg_dest}/.env <<EOF
PATH=/pkgs/bun/${BUN_VERSION}/bin:/pkgs/bun/${BUN_VERSION}:/pkgs/node/${NODE_VERSION}/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:.
NODE_PATH=/pkgs/node/${NODE_VERSION}/node_modules
BUN_INSTALL=/pkgs/bun/${BUN_VERSION}
EOF
        echo \$(date +%s)000 > ${pkg_dest}/.package-installed
    "

    echo "Bash ${bash_package_version} registered (using system binary ${system_bash_version})"
}

# Mirrors the R section of docker/package-init.sh, which is the implementation
# the deployed images use; keep the two in step. Defaults to R_PACKAGE_SET=core
# here because this is the local-developer path and the extended tier adds a
# long source build. Every R package compiles from source: CRAN ships no arm64
# Linux binaries.
install_r() {
    if [ "${SKIP_R:-}" = "1" ]; then
        echo "Skipping R (SKIP_R=1)"
        return 0
    fi

    local pkg_dest="/pkgs/r/${R_VERSION}"

    echo "=============================================="
    echo "  Installing R ${R_VERSION} (${R_PACKAGE_SET})"
    echo "=============================================="

    if [ ! -f "$R_PACKAGE_MANIFEST" ]; then
        echo "ERROR: Missing R package manifest: $R_PACKAGE_MANIFEST" >&2
        return 1
    fi

    local r_packages=()
    while IFS= read -r package_spec || [ -n "$package_spec" ]; do
        if [[ "$package_spec" =~ ^[[:space:]]*#[[:space:]]*---[[:space:]]*extended ]]; then
            [ "$R_PACKAGE_SET" = "core" ] && break
            continue
        fi
        [[ "$package_spec" =~ ^[[:space:]]*(#|$) ]] && continue
        r_packages+=("$package_spec")
    done < "$R_PACKAGE_MANIFEST"
    if [ "${#r_packages[@]}" -eq 0 ]; then
        echo "ERROR: No R packages listed in $R_PACKAGE_MANIFEST" >&2
        return 1
    fi

    # The builder container is buildpack-deps:bookworm. Posit's builds are not
    # interchangeable across Debian releases: a bookworm build installs on
    # trixie and then fails to start on libtirpc.so.3.
    docker exec "$CONTAINER_NAME" bash -c "
        set -e
        rm -rf ${pkg_dest}
        mkdir -p /pkgs/r
        curl -fsSL -o /tmp/r.deb \
            https://cdn.posit.co/r/debian-12/pkgs/r-${R_VERSION}_1_${R_ARCH}.deb
        # main() purges /var/lib/apt/lists, and the R package pulls in
        # libopenblas-dev, libpaper-utils and zip. Without a refresh those read
        # as 'not installable'. docker/apt-install.sh refreshes for the same
        # reason, which is why the image build path does not hit this.
        apt-get update
        apt-get install -y --no-install-recommends /tmp/r.deb
        rm -rf /tmp/r.deb /var/lib/apt/lists/*
        # The package installs under /opt, which the NsJail mount namespace does
        # not expose. Move it where the jail can see it and repoint R_HOME,
        # which is baked into these files at package build time.
        mv /opt/R/${R_VERSION} ${pkg_dest}
        rmdir /opt/R 2>/dev/null || true
        for relative in bin/R lib/R/bin/R lib/R/etc/Makeconf lib/R/etc/ldpaths lib/pkgconfig/libR.pc; do
            [ -f \"${pkg_dest}/\$relative\" ] && \
                sed -i \"s|/opt/R/${R_VERSION}|${pkg_dest}|g\" \"${pkg_dest}/\$relative\"
        done
        # Stock Rscript is an ELF with R_HOME compiled in and cannot be
        # relocated. Both copies must be replaced: package build scripts reach
        # the lib/R/bin one through R_HOME, and leaving it breaks any package
        # whose configure step shells out to Rscript.
        for rscript in ${pkg_dest}/bin/Rscript ${pkg_dest}/lib/R/bin/Rscript; do
            cat > \"\$rscript\" << 'RSCRIPT'
#!/bin/bash
R_BIN=\"${pkg_dest}/bin/R\"
if [ \"\$#\" -eq 0 ] || [ \"\${1#-}\" != \"\$1\" ]; then
    exec \"\$R_BIN\" --no-echo --no-restore \"\$@\"
fi
script=\"\$1\"
shift
exec \"\$R_BIN\" --no-echo --no-restore --file=\"\$script\" --args \"\$@\"
RSCRIPT
            chmod +x \"\$rscript\"
        done
        if grep -rl \"/opt/R/${R_VERSION}\" ${pkg_dest} >/dev/null 2>&1; then
            echo 'ERROR: files still reference the pre-relocation prefix' >&2
            exit 1
        fi
        mkdir -p ${pkg_dest}/lib/R/site-library
    "

    local r_vector
    r_vector=$(printf '"%s",' "${r_packages[@]}")
    r_vector="${r_vector%,}"
    # install.packages() reports a failed build as a warning and still exits 0,
    # so the explicit check afterwards is what makes this fail loudly.
    docker exec "$CONTAINER_NAME" bash -c "
        set -e
        cat > /tmp/install-r-packages.R << RINSTALL
pkgs <- c(${r_vector})
lib <- \"${pkg_dest}/lib/R/site-library\"
install.packages(pkgs, repos = \"${R_CRAN_REPO}\", lib = lib,
                 Ncpus = max(1L, parallel::detectCores()))
missing <- pkgs[!pkgs %in% rownames(installed.packages(lib.loc = lib))]
if (length(missing)) {
    cat(\"FAILED R packages:\", paste(missing, collapse = \", \"), \"\n\")
    quit(status = 1L)
}
cat(\"All\", length(pkgs), \"R packages installed\n\")
RINSTALL
        ${pkg_dest}/bin/R --no-echo --no-restore --file=/tmp/install-r-packages.R
        rm -f /tmp/install-r-packages.R
    "

    # Carry every shared object R resolves outside /pkgs, so the runtime does not
    # depend on the builder's /usr. glibc, libgcc and libstdc++ stay excluded:
    # those come from the running image, which is never older than this builder.
    docker exec "$CONTAINER_NAME" bash -c "
        set -e
        mkdir -p ${pkg_dest}/syslib
        find ${pkg_dest} -type f \\( -name '*.so' -o -name '*.so.*' -o -path '*/bin/exec/R' \\) -print0 \
            | xargs -0 -r -n1 ldd 2>/dev/null \
            | awk '/=> \\// {print \$3}' \
            | sort -u \
            | grep -v '^/pkgs' \
            | grep -vE '/(ld-linux[^/]*|libc|libm|libdl|libpthread|librt|libresolv|libgcc_s|libstdc\\+\\+)\\.so' \
            > /tmp/r-syslibs.txt
        while IFS= read -r lib; do
            [ -n \"\$lib\" ] && cp -Ln \"\$lib\" ${pkg_dest}/syslib/ 2>/dev/null || true
        done < /tmp/r-syslibs.txt
        echo \"Carried \$(ls -1 ${pkg_dest}/syslib | wc -l) shared libraries into ${pkg_dest}/syslib\"
        rm -f /tmp/r-syslibs.txt

        cat > ${pkg_dest}/pkg-info.json << 'EOF'
{
    \"language\": \"r\",
    \"version\": \"${R_VERSION}\",
    \"build_platform\": \"docker-debian\",
    \"aliases\": [\"rscript\", \"rstats\"]
}
EOF

        cat > ${pkg_dest}/run << 'EOF'
#!/bin/bash
SCRIPT_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")\" && pwd)\"
\"\${SCRIPT_DIR}/bin/Rscript\" \"\$@\"
EOF
        chmod +x ${pkg_dest}/run

        {
            echo 'PATH=${pkg_dest}/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:.'
            echo 'R_HOME=${pkg_dest}/lib/R'
            echo 'LD_LIBRARY_PATH=${pkg_dest}/lib/R/lib:${pkg_dest}/syslib'
            echo 'R_LIBS_SITE=${pkg_dest}/lib/R/site-library'
        } > ${pkg_dest}/.env

        echo \$(date +%s)000 > ${pkg_dest}/.package-installed
    "

    echo "R ${R_VERSION} registered"
}

main() {
    echo "=============================================="
    echo "  Code Interpreter API - Package Builder"
    echo "=============================================="
    echo ""

    command -v docker >/dev/null 2>&1 || { echo "Docker is required"; exit 1; }

    echo "Starting builder container..."
    docker run \
        -v "$PWD/data/pkgs:/pkgs" \
        -dit \
        --name "$CONTAINER_NAME" \
        buildpack-deps:bookworm >/dev/null

    echo "Installing system dependencies..."
    docker exec "$CONTAINER_NAME" bash -c "
        apt-get update && apt-get install -y --no-install-recommends \
            curl unzip wget ca-certificates \
            build-essential libssl-dev libffi-dev libsqlite3-dev \
            zlib1g-dev libbz2-dev libreadline-dev libncurses5-dev \
            tk-dev xz-utils libcurl4-openssl-dev libfontconfig1-dev \
            libudunits2-dev libpng-dev libxml2-dev libcairo2-dev \
            libfreetype6-dev \
            gfortran libblas-dev liblapack-dev libicu-dev libpcre2-dev \
            liblzma-dev libjpeg-dev libtiff-dev cmake libuv1-dev \
        && rm -rf /var/lib/apt/lists/*
    "

    install_python
    install_python_packages
    install_node
    install_node_packages
    install_bun
    install_bun_packages
    install_bash
    install_r

    echo "Setting permissions..."
    chmod -R a+rX "$PACKAGES_DIR" 2>/dev/null || true

    echo ""
    echo "=============================================="
    echo "  Build complete!"
    echo "=============================================="
    echo ""
    echo "Packages installed to: $PACKAGES_DIR"
    echo ""
    echo "Next steps:"
    echo "  1. Run: docker compose up --build"
    echo ""
}

main "$@"
