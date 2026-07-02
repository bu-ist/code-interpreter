#!/bin/bash

echo "Starting Sandbox (direct NsJail, no microVM) on port 2000..."

ROOTFS="${SANDBOX_ROOTFS:-/sandbox-rootfs}"

mkdir -p /sandbox_api /pkgs

if mount -o remount,rw /sys/fs/cgroup 2>/dev/null; then
    echo "[sandbox] Remounted cgroupfs as rw"
else
    echo "[sandbox] WARNING: could not remount cgroupfs rw - NsJail cgroup isolation may fail"
fi

mkdir -p /sys/fs/cgroup/init
echo "[sandbox] Draining root cgroup ($(wc -w < /sys/fs/cgroup/cgroup.procs 2>/dev/null || echo '?') procs) into init/..."
_root_procs=$(cat /sys/fs/cgroup/cgroup.procs 2>/dev/null || true)
for _pid in $_root_procs; do
    echo "$_pid" > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null || true
done
_remaining=$(wc -w < /sys/fs/cgroup/cgroup.procs 2>/dev/null || echo "?")
echo "[sandbox] Root cgroup procs after drain: $_remaining"

if echo "+memory +pids" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
    echo "[sandbox] Enabled +memory +pids on root cgroup.subtree_control"
else
    echo "[sandbox] WARNING: could not enable controllers on root ($_remaining procs remain)"
fi

PROC_SUBMOUNTS=$(awk '$5 ~ /^\/proc\/./ {print $5}' /proc/self/mountinfo 2>/dev/null | sort -r)
if [ -n "$PROC_SUBMOUNTS" ]; then
    echo "[sandbox] Removing $(echo "$PROC_SUBMOUNTS" | wc -l) /proc submounts for fresh procfs support..."
    for mnt in $PROC_SUBMOUNTS; do
        umount "$mnt" 2>/dev/null || true
    done
    REMAINING=$(awk '$5 ~ /^\/proc\/./ {print $5}' /proc/self/mountinfo 2>/dev/null | wc -l)
    if [ "$REMAINING" -eq 0 ]; then
        echo "[sandbox] All /proc submounts removed"
    else
        echo "[sandbox] WARNING: $REMAINING /proc submounts remain"
    fi
else
    echo "[sandbox] No /proc submounts to remove"
fi

export SANDBOX_ROOTFS="$ROOTFS"

# On Fedora 43 (usr-merge), /usr/sbin → /usr/bin, so bind-mounting $ROOTFS/usr/sbin
# actually replaces Fedora's /usr/bin with Debian's. All subsequent calls to Debian
# binaries require /lib/x86_64-linux-gnu/ which does not exist via Fedora paths.
#
# Key fact: /usr/lib64 on Fedora x86_64 is a REAL directory (not merged with /usr/lib).
# Fedora binaries link against /usr/lib64/ which none of the bind mounts below touch.
# Copying Fedora's mount and bash to /tmp preserves working Fedora binaries that can
# be called after the Debian rootfs is overlaid. Debian binaries (nsjail, etc.) use
# their own embedded linker (/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2) which knows
# its own multiarch library paths (/usr/lib/x86_64-linux-gnu) without LD_LIBRARY_PATH.
cp "$(command -v mount)" /tmp/.sandbox-mount
chmod +x /tmp/.sandbox-mount
cp "$(command -v bash)" /tmp/.sandbox-bash
chmod +x /tmp/.sandbox-bash

exec unshare --mount bash -c '
    ROOTFS="${SANDBOX_ROOTFS:-/sandbox-rootfs}"
    MOUNT=/tmp/.sandbox-mount
    echo "[unshare] starting in new mount namespace, ROOTFS=$ROOTFS"

    "$MOUNT" -o bind,ro "$ROOTFS/usr/sbin"     /usr/sbin    && echo "[unshare] mounted /usr/sbin"    || { echo "FATAL: cannot bind /usr/sbin"; exit 1; }
    "$MOUNT" -o bind,ro "$ROOTFS/usr/local"    /usr/local   && echo "[unshare] mounted /usr/local"   || { echo "FATAL: cannot bind /usr/local"; exit 1; }
    "$MOUNT" -o bind,ro "$ROOTFS/sandbox_api"  /sandbox_api && echo "[unshare] mounted /sandbox_api" || { echo "FATAL: cannot bind /sandbox_api"; exit 1; }
    "$MOUNT" -o bind,ro "$ROOTFS/pkgs"         /pkgs        && echo "[unshare] mounted /pkgs"        || { echo "FATAL: cannot bind /pkgs"; exit 1; }

    if [ -d /host-packages ]; then
        "$MOUNT" --bind /host-packages /pkgs 2>/dev/null && echo "[unshare] overlaid /host-packages" || \
            echo "WARNING: could not bind /host-packages"
    fi

    "$MOUNT" -o bind,ro "$ROOTFS/usr/bin"  /usr/bin  && echo "[unshare] mounted /usr/bin"  || { echo "FATAL: cannot bind /usr/bin"; exit 1; }
    "$MOUNT" -o bind,ro "$ROOTFS/usr/lib"  /usr/lib  && echo "[unshare] mounted /usr/lib"  || { echo "FATAL: cannot bind /usr/lib"; exit 1; }

    if [ -d "$ROOTFS/usr/lib64" ] && ! [ -L "$ROOTFS/usr/lib64" ]; then
        "$MOUNT" -o bind,ro "$ROOTFS/usr/lib64" /usr/lib64 && echo "[unshare] mounted /usr/lib64" || \
            echo "[sandbox] WARNING: could not bind /usr/lib64"
    else
        echo "[unshare] skipping /usr/lib64 (not present or is symlink in sandbox-rootfs)"
    fi

    export PATH="/root/.bun/bin:$PATH"

    echo "[unshare] bind mounts done — execing /tmp/.sandbox-bash /sandbox_api/entrypoint.sh"
    ls -la /tmp/.sandbox-bash /sandbox_api/entrypoint.sh || echo "[unshare] WARN: file(s) missing"

    exec /tmp/.sandbox-bash /sandbox_api/entrypoint.sh
    echo "[unshare] FATAL: exec returned (should be unreachable)"
'
