#!/usr/bin/env bash
# patch-host-gpu.sh — TAPPaaS host GPU preparation
# Repo: ErikDaniel007/private_tappaas
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
# Host models directory comes from the first bind-mount (see <module>.meta.json
# bindMounts[]); falls back to legacy models_bind_src for older meta files.
MODELS_SRC=$(jq -r '.bindMounts[0].src // .models_bind_src // empty' "$META")

# --- Step 1: Check amdgpu kernel module ---
# Capture lsmod first: 'lsmod | grep -q' is a false negative under set -o
# pipefail because grep -q exits on first match, lsmod gets SIGPIPE (141),
# and pipefail propagates that as a pipeline failure.
LOADED_MODS="$(lsmod)"
if grep -q '^amdgpu' <<< "$LOADED_MODS"; then
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

# --- Step 9: Reconcile the LXC cgroup device allow to the LIVE device majors ---
# /dev/kfd's major is assigned dynamically at host boot, but the LXC conf's
# `lxc.cgroup2.devices.allow` is written only at container-create time
# (Create-TAPPaaS-LXC.sh). So after a host reboot — or if the container was
# created from a stale committed meta — the conf can pin a major the kernel
# denies: the bind-mounted /dev/kfd is then visible (ls passes) but unusable
# → "No HIP GPUs are available". Re-sync the conf to the live majors here;
# restart the container only when something actually changed. Idempotent.
MODULE_JSON="/root/tappaas/${MODULE}.json"
VMID="$(jq -r '.vmid // empty' "$MODULE_JSON" 2>/dev/null)"
CONF="/etc/pve/lxc/${VMID}.conf"
if [ -n "$VMID" ] && [ -f "$CONF" ]; then
  LIVE_KFD_MAJ="$(printf '%d' "0x$(stat -c '%t' /dev/kfd)")"
  LIVE_REN_MAJ="$(printf '%d' "0x$(stat -c '%t' "/dev/dri/${RENDER_NODE}")")"
  LIVE_REN_MIN="$(printf '%d' "0x$(stat -c '%T' "/dev/dri/${RENDER_NODE}")")"
  changed=0
  # kfd line is the only allow with minor :0; render line carries the render minor.
  if ! grep -q "^lxc.cgroup2.devices.allow: c ${LIVE_KFD_MAJ}:0 rwm$" "$CONF"; then
    sed -i -E "s|^lxc\.cgroup2\.devices\.allow: c [0-9]+:0 rwm$|lxc.cgroup2.devices.allow: c ${LIVE_KFD_MAJ}:0 rwm|" "$CONF"
    changed=1
  fi
  if ! grep -q "^lxc.cgroup2.devices.allow: c ${LIVE_REN_MAJ}:${LIVE_REN_MIN} rwm$" "$CONF"; then
    sed -i -E "s|^lxc\.cgroup2\.devices\.allow: c [0-9]+:${LIVE_REN_MIN} rwm$|lxc.cgroup2.devices.allow: c ${LIVE_REN_MAJ}:${LIVE_REN_MIN} rwm|" "$CONF"
    changed=1
  fi
  if [ "$changed" -eq 1 ]; then
    ok "LXC ${VMID} cgroup allow re-synced (kfd ${LIVE_KFD_MAJ}:0, ${RENDER_NODE} ${LIVE_REN_MAJ}:${LIVE_REN_MIN})"
    if pct status "${VMID}" 2>/dev/null | grep -q running; then
      pct reboot "${VMID}" && ok "LXC ${VMID} restarted to apply cgroup change"
    fi
  else
    ok "LXC ${VMID} cgroup allow already matches live majors"
  fi
else
  err "cgroup reconcile" "VMID/conf not resolved (${MODULE_JSON}) — skipped"
fi

echo ""
echo "  === host GPU patch complete ==="
echo ""
