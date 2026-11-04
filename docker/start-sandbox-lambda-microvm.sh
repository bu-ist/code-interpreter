#!/bin/bash
# Sandbox entrypoint for AWS Lambda MicroVMs.
#
# Installed as /usr/local/bin/start-sandbox.sh by the sandbox-lambda-microvm
# stage of docker/Dockerfile.worker-sandbox.
#
# This is start-direct-sandbox-nokvm.sh with the container-specific parts
# removed. There is no supervisor and no worker: the worker stays in EKS and
# talks to this over the Lambda MicroVM endpoint, so this process is the whole
# payload and must be PID 1's exec target.
#
# Two things the container version does are unnecessary here:
#
#   * Removing /proc submounts. Those are added by containerd; a Firecracker
#     guest boots with a clean /proc. The loop below is kept anyway because it
#     is a no-op when there is nothing to remove, and skipping it would make
#     this script silently wrong if the guest ever gains submounts.
#
#   * Bind-mounting a Debian rootfs over a Fedora base. Not applicable — this
#     image is Debian all the way down, same as Stage 7.
#
# One thing is genuinely uncertain: whether the guest gives us a writable
# cgroup2 filesystem with delegable controllers. Every cgroup step below is
# therefore best-effort and logged, and the script fails loudly at the end if
# SANDBOX_USE_CGROUPV2 was requested but the controllers are not actually
# available — silently running without memory limits on untrusted code is the
# one outcome worth refusing to start for.

set -uo pipefail

echo "[sandbox] Starting sandbox API (NsJail inside a Lambda MicroVM) on port 2000..."

if mount -o remount,rw /sys/fs/cgroup 2>/dev/null; then
    echo "[sandbox] Remounted cgroupfs as rw"
else
    echo "[sandbox] cgroupfs not remounted (may already be rw, or not present)"
fi

# cgroup v2 delegation: the kernel refuses to enable controllers on a cgroup
# that still has member processes, so drain the root cgroup into init/ first.
mkdir -p /sys/fs/cgroup/init 2>/dev/null
_root_procs=$(cat /sys/fs/cgroup/cgroup.procs 2>/dev/null || true)
for _pid in $_root_procs; do
    echo "$_pid" > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null || true
done
_remaining=$(wc -w < /sys/fs/cgroup/cgroup.procs 2>/dev/null || echo "?")
echo "[sandbox] Root cgroup procs after drain: $_remaining"

if echo "+memory +pids" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
    echo "[sandbox] Enabled +memory +pids on root cgroup.subtree_control"
    CGROUP_OK=true
else
    echo "[sandbox] WARNING: could not enable controllers on root ($_remaining procs remain)"
    CGROUP_OK=false
fi

# Kubernetes/containerd artifact; a no-op in a Firecracker guest.
PROC_SUBMOUNTS=$(awk '$5 ~ /^\/proc\/./ {print $5}' /proc/self/mountinfo 2>/dev/null | sort -r)
for mnt in $PROC_SUBMOUNTS; do
    umount "$mnt" 2>/dev/null || true
done

# Refuse to run untrusted code without the memory and pid limits we claimed to
# have. If this fires, the MicroVM guest does not delegate cgroup2 the way the
# in-cluster sandbox node does, and SANDBOX_USE_CGROUPV2 must be revisited
# before this image is used — not quietly dropped.
if [ "${SANDBOX_USE_CGROUPV2:-false}" = "true" ] && [ "$CGROUP_OK" != "true" ]; then
    echo "[sandbox] FATAL: SANDBOX_USE_CGROUPV2=true but cgroup v2 controllers are unavailable." >&2
    echo "[sandbox]        Per-execution memory and pid limits would not be enforced. Refusing to start." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# RLIMIT_NOFILE: raise the HARD limit so nsjail can grant jobs a real budget.
# ---------------------------------------------------------------------------
# The guest boots with a hard limit of 1024. nsjail sets RLIMIT_NOFILE per job
# to SANDBOX_MAX_OPEN_FILES, and raising a hard limit needs CAP_SYS_RESOURCE,
# which nsjail does not have. So SANDBOX_MAX_OPEN_FILES could never exceed
# 1024 -- asking for more failed every execution before any code ran:
#
#   containSetLimits():188 util::setrlimit(0, RLIMIT_NOFILE, 2048):
#       Operation not permitted
#   runChild():551 Launching child process failed
#
# In cluster this never arose: launcher/src/main.rs raises the limit before
# exec, and that launcher is not used on the MicroVM path (KVM_ENABLED=false).
# This restores parity -- the in-cluster sandbox runs at soft 65536 /
# hard 1048576.
#
# PID 1 here is root in the guest and the image declares
# AdditionalOsCapabilities ALL, so CAP_SYS_RESOURCE should be available. It is
# NOT assumed: the raise is best-effort and logged, exactly like the cgroup
# steps above. If it fails the sandbox still starts, because
# SANDBOX_MAX_OPEN_FILES stays at the old value until a separate change raises
# it -- and that change must only land once the log line below confirms the
# new hard limit. Raising both at once would reintroduce the failure above.
#
# The target is clamped to /proc/sys/fs/nr_open, the kernel ceiling a hard
# limit cannot exceed.
HARD_NOFILE_TARGET="${SANDBOX_HARD_NOFILE:-1048576}"
NR_OPEN=$(cat /proc/sys/fs/nr_open 2>/dev/null || echo "")
if [ -n "$NR_OPEN" ] && [ "$HARD_NOFILE_TARGET" -gt "$NR_OPEN" ] 2>/dev/null; then
    echo "[sandbox] Clamping RLIMIT_NOFILE target $HARD_NOFILE_TARGET to kernel nr_open $NR_OPEN"
    HARD_NOFILE_TARGET="$NR_OPEN"
fi

NOFILE_SOFT_BEFORE=$(ulimit -Sn 2>/dev/null || echo "?")
NOFILE_HARD_BEFORE=$(ulimit -Hn 2>/dev/null || echo "?")

if ulimit -n "$HARD_NOFILE_TARGET" 2>/dev/null; then
    echo "[sandbox] Raised RLIMIT_NOFILE from ${NOFILE_SOFT_BEFORE}/${NOFILE_HARD_BEFORE} to $(ulimit -Sn)/$(ulimit -Hn)"
else
    echo "[sandbox] WARNING: could not raise RLIMIT_NOFILE above ${NOFILE_SOFT_BEFORE}/${NOFILE_HARD_BEFORE}" >&2
    echo "[sandbox]          (CAP_SYS_RESOURCE unavailable). SANDBOX_MAX_OPEN_FILES must stay <= ${NOFILE_HARD_BEFORE}." >&2
fi

exec /sandbox_api/entrypoint.sh
