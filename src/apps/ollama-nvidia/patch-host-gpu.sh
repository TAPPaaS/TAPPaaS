#!/usr/bin/env bash
# patch-host-gpu.sh — TAPPaaS host GPU preparation for ollama-nvidia
#
# Run ON the target Proxmox node via SSH from install.sh.
# Reads GPU device info from <module>.meta.json.
# Usage: bash patch-host-gpu.sh <module>
#
# Mirrors vllm-amd/patch-host-gpu.sh's structure, adapted for NVIDIA's several
# character devices instead of AMD's /dev/kfd + one renderD* node. There is no
# NVIDIA equivalent of the "render" group convention; device nodes are simply
# made world-rw (666), which is the common convention for NVIDIA-in-LXC setups
# since nvidia-container-toolkit (inside the LXC) is what actually gates access
# for the Docker containers it manages.

set -euo pipefail

GN="\033[1;92m"; RD="\033[01;31m"; CL="\033[m"
ok()  { printf "${GN}  ✅ %-30s${CL}\n" "$1"; }
err() { printf "${RD}  ❌ %-30s — %s${CL}\n" "$1" "$2"; }
die() { printf "${RD}  ❌ FATAL: %s${CL}\n" "$1"; exit 1; }

[ -z "${1:-}" ] && die "Usage: bash patch-host-gpu.sh <module>"
MODULE="$1"
META="/root/tappaas/${MODULE}.meta.json"
[ -f "$META" ] || die "Not found: $META"

echo ""
echo "=== TAPPaaS patch-host-gpu: $MODULE ==="
echo ""

# --- Read device info from meta.json ---
MODELS_SRC=$(jq -r '.bindMounts[0].src // empty' "$META")

# --- Step 1: Check the host NVIDIA driver actually works ---
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
  ok "nvidia-smi reports a working driver"
else
  err "nvidia-smi" "not working — install/reload the NVIDIA driver on this host first"
  die "host NVIDIA driver required"
fi

# --- Step 1b: Ensure nvidia_uvm is loaded now and at every boot ---
# /dev/nvidia-uvm is created lazily (first CUDA context / module load), so
# after a host reboot it can be absent even with a healthy driver — the LXC
# then gets no uvm device and Ollama silently falls back to CPU. Load it now
# and persist via modules-load.d.
nvidia-modprobe -u -c=0 2>/dev/null || modprobe nvidia_uvm 2>/dev/null || true
if [ ! -f /etc/modules-load.d/ollama-nvidia.conf ]; then
  printf 'nvidia\nnvidia_uvm\n' > /etc/modules-load.d/ollama-nvidia.conf
  ok "modules-load.d persistence written (nvidia, nvidia_uvm)"
else
  ok "modules-load.d persistence already present"
fi

# --- Step 1c: Enable nvidia-persistenced if available ---
# Keeps the GPU initialized between CUDA contexts: avoids the multi-second
# driver re-init on every first request after idle, and keeps device nodes
# stable. Ships with the .run driver installer; skip quietly if absent.
if systemctl list-unit-files nvidia-persistenced.service &>/dev/null; then
  systemctl enable --now nvidia-persistenced 2>/dev/null \
    && ok "nvidia-persistenced enabled" \
    || echo "  (nvidia-persistenced present but could not be enabled — non-fatal)"
else
  echo "  (nvidia-persistenced not installed — optional, improves first-request latency)"
fi

# --- Step 2: Check the character devices exist ---
for dev in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm; do
  if [ -c "$dev" ]; then
    ok "$dev present"
  else
    err "$dev" "not found"
    die "$dev required"
  fi
done
if [ -c /dev/nvidia-uvm-tools ]; then
  ok "/dev/nvidia-uvm-tools present"
else
  echo "  (nvidia-uvm-tools not present yet — some driver versions create it lazily; not fatal)"
fi

# --- Step 3: Permissions — world-rw, no group convention on NVIDIA like AMD's 'render' ---
for dev in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
  [ -e "$dev" ] || continue
  if chmod 666 "$dev"; then
    ok "$dev permissions set (666)"
  else
    err "$dev permissions" "chmod failed"
  fi
done

# --- Step 4: Create models directory ---
if mkdir -p "$MODELS_SRC"; then
  ok "models directory ready: $MODELS_SRC"
else
  err "models directory" "could not create $MODELS_SRC"
fi

# --- Step 5: Check cgroup2 is active (required for Proxmox LXC device passthrough) ---
if [ -d /sys/fs/cgroup/system.slice ]; then
  ok "cgroup2 active"
else
  err "cgroup2" "not active — check Proxmox host config"
fi

# --- Step 6: Reconcile the LXC GPU passthrough conf to the LIVE device majors ---
# Same rationale as vllm-amd: nvidia_uvm's major is dynamically allocated at
# module load and can shift across host reboots (nvidia0/nvidiactl's major 195
# is registered and stable), but the LXC conf is only written once. Unlike
# vllm-amd, Create-TAPPaaS-LXC.sh does NOT seed these lines at create time —
# this module's meta deliberately names its device block `nvidia_gpu`, not
# `gpu`, because the provisioner's AMD-shaped `.gpu` handler would emit
# malformed conf lines (empty kfd/render majors) that break pct start. This
# script is therefore the sole owner of the passthrough conf.
#
# The section is managed as a sentinel-delimited block, rebuilt from live
# device state on every run and rewritten only when its content changed.
# (Match-by-minor replacement doesn't work here: /dev/nvidia0 and
# /dev/nvidia-uvm both have minor 0 on different majors.)
MODULE_JSON="/root/tappaas/${MODULE}.json"
VMID="$(jq -r '.vmid // empty' "$MODULE_JSON" 2>/dev/null)"
CONF="/etc/pve/lxc/${VMID}.conf"
BEGIN_MARK="# BEGIN ollama-nvidia GPU passthrough (managed by patch-host-gpu.sh)"
END_MARK="# END ollama-nvidia GPU passthrough"
if [ -n "$VMID" ] && [ -f "$CONF" ]; then
  NEW_BLOCK="$BEGIN_MARK"
  for dev in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
    [ -c "$dev" ] || continue
    LIVE_MAJ="$(printf '%d' "0x$(stat -c '%t' "$dev")")"
    LIVE_MIN="$(printf '%d' "0x$(stat -c '%T' "$dev")")"
    NEW_BLOCK="${NEW_BLOCK}
lxc.cgroup2.devices.allow: c ${LIVE_MAJ}:${LIVE_MIN} rwm
lxc.mount.entry: ${dev} ${dev#/} none bind,optional,create=file"
  done
  NEW_BLOCK="${NEW_BLOCK}
${END_MARK}"

  OLD_BLOCK="$(sed -n "\|^${BEGIN_MARK}\$|,\|^${END_MARK}\$|p" "$CONF")"
  if [ "$OLD_BLOCK" = "$NEW_BLOCK" ]; then
    ok "LXC ${VMID} GPU passthrough conf already matches live majors"
  else
    tmp=$(mktemp)
    sed "\|^${BEGIN_MARK}\$|,\|^${END_MARK}\$|d" "$CONF" > "$tmp"
    printf '%s\n' "$NEW_BLOCK" >> "$tmp"
    cat "$tmp" > "$CONF"
    rm -f "$tmp"
    ok "LXC ${VMID} GPU passthrough conf re-synced to live majors"
    if pct status "${VMID}" 2>/dev/null | grep -q running; then
      pct reboot "${VMID}" && ok "LXC ${VMID} restarted to apply cgroup change"
    fi
  fi
else
  err "cgroup reconcile" "VMID/conf not resolved (${MODULE_JSON}) — skipped"
fi

echo ""
echo "  === host GPU patch complete ==="
echo ""
