#!/usr/bin/env bash
# patch-host-gpu.sh — TAPPaaS host GPU preparation
<<<<<<< HEAD
# Repo: ErikDaniel007/private_tappaas
=======
# Repo: ErikDaniel007/
>>>>>>> addaf18 (fix: merge Erik's vllm-amd scripts + patch entrypoint bug)
# Path: src/apps/vllm-amd/patch-host-gpu.sh
#
# Run ON the Proxmox host (tappaas2) via SSH from install.sh
# Reads GPU device info from <module>.meta.json
# Usage: bash patch-host-gpu.sh <module>

set -euo pipefail

# --- Color codes ---
GN="\033[1;92m"; RD="\033[01;31m"; CL="\033[m"
ok()  { printf "${GN}  ✅ %-30s${CL}\n" "$1"; }
err() { printf "${RD}  ❌ %-30s — %s${CL}\n" "$1" "$2"; }
die() { printf "${RD}  ❌ FATAL: %s${CL}\n" "$1"; exit 1; }

# --- Check argument ---
[ -z "${1:-}" ] && die "Usage: bash patch-host-gpu.sh <module>"
MODULE="$1"
META="/root/tappaas/${MODULE}.meta.json"
[ -f "$META" ] || die "Not found: $META"

echo ""
echo "=== TAPPaaS patch-host-gpu: $MODULE ==="
echo ""

# --- Read device info from meta.json ---
KFD_MAJOR=$(jq -r '.gpu.kfd_major'     "$META")
KFD_MINOR=$(jq -r '.gpu.kfd_minor'     "$META")
RENDER_NODE=$(jq -r '.gpu.render_node' "$META")
RENDER_MAJOR=$(jq -r '.gpu.render_major' "$META")
RENDER_MINOR=$(jq -r '.gpu.render_minor' "$META")
MODELS_SRC=$(jq -r '.models_bind_src'  "$META")

# --- Step 1: Check amdgpu kernel module ---
<<<<<<< HEAD

AMDGPU_LOADED=$(lsmod | grep -c "^amdgpu" || true)
if [ "$AMDGPU_LOADED" -gt 0 ]; then
=======
if lsmod | grep -q amdgpu; then
>>>>>>> addaf18 (fix: merge Erik's vllm-amd scripts + patch entrypoint bug)
  ok "amdgpu kernel module loaded"
else
  err "amdgpu module" "not loaded — check dmesg"
  die "amdgpu module required"
fi

# --- Step 2: Check /dev/kfd exists ---
if [ -c /dev/kfd ]; then
  ok "/dev/kfd present (${KFD_MAJOR}:${KFD_MINOR})"
else
  err "/dev/kfd" "not found — ROCm compute unavailable"
  die "/dev/kfd required"
fi

# --- Step 3: Check render node exists ---
if [ -c "/dev/dri/${RENDER_NODE}" ]; then
  ok "/dev/dri/${RENDER_NODE} present (${RENDER_MAJOR}:${RENDER_MINOR})"
else
  err "/dev/dri/${RENDER_NODE}" "not found"
  die "GPU render node required"
fi

# --- Step 4: Create render group if missing ---
if getent group render > /dev/null 2>&1; then
  ok "group 'render' exists"
else
  groupadd render
  ok "group 'render' created"
fi

# --- Step 5: Set /dev/kfd permissions ---
if chown root:render /dev/kfd && chmod 660 /dev/kfd; then
  ok "/dev/kfd permissions set (root:render 660)"
else
  err "/dev/kfd permissions" "chown/chmod failed"
fi

# --- Step 6: Set render node permissions ---
if chown root:render "/dev/dri/${RENDER_NODE}" && chmod 660 "/dev/dri/${RENDER_NODE}"; then
  ok "/dev/dri/${RENDER_NODE} permissions set (root:render 660)"
else
  err "/dev/dri/${RENDER_NODE} permissions" "chown/chmod failed"
fi

# --- Step 7: Create models directory ---
if mkdir -p "$MODELS_SRC"; then
  ok "models directory ready: $MODELS_SRC"
else
  err "models directory" "could not create $MODELS_SRC"
fi

# --- Step 8: Check cgroup2 is active (required for Proxmox LXC device passthrough) ---
if [ -d /sys/fs/cgroup/system.slice ]; then
  ok "cgroup2 active"
else
  err "cgroup2" "not active — check Proxmox host config"
fi

echo ""
echo "  === host GPU patch complete ==="
echo ""