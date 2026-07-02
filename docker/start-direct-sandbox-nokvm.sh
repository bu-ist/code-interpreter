#!/bin/bash
# Direct sandbox start script for no-KVM environments where the container is
# already Debian-based (worker-sandbox-nokvm stage). No bind mounts or
# architecture-specific chroot tricks are needed — NsJail, the sandbox API,
# and all their libraries are at their correct Debian paths.
#
# This is installed as /usr/local/bin/start-direct-sandbox.sh in the
# worker-sandbox-nokvm Dockerfile stage and invoked by supervisor.sh.

echo "Starting Sandbox (direct NsJail, no microVM) on port 2000..."

# Remount cgroupfs rw so we can manipulate cgroups below.
if mount -o remount,rw /sys/fs/cgroup 2>/dev/null; then
    echo "[sandbox] Remounted cgroupfs as rw"
else
    echo "[sandbox] WARNING: could not remount cgroupfs rw - NsJail cgroup isolation may fail"
fi

# cgroup v2 delegation: drain all root-cgroup processes into an 'init/' sub-cgroup
# so that subtree_control can be written (the kernel forbids enabling controllers
# on a cgroup that still has member processes). entrypoint.sh then creates a
# 'sandbox_api/' sub-cgroup for NsJail's per-execution isolation.
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

# Remove /proc submounts that Kubernetes/containerd adds. NsJail needs a clean
# /proc to mount fresh procfs inside each sandbox's PID namespace.
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

# Exec directly into the sandbox API entrypoint — no bind mounts needed because
# NsJail and the sandbox API already live at their correct Debian paths.
exec /sandbox_api/entrypoint.sh
