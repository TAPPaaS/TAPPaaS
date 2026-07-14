#!/usr/bin/env bash
# patch-host-gpu.sh — TAPPaaS host GPU preparation for ollama-nvidia
#
# Run ON the Proxmox host (tappaas1) via SSH from install.sh.
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

# --- Step 6: Reconcile the LXC cgroup device allow list to the LIVE device majors ---
# Same rationale as vllm-amd: NVIDIA device majors can also shift across a host
# reboot/driver reload, but the LXC conf's lxc.cgroup2.devices.allow entries are
# only written at container-create time. Re-sync here; restart only if changed.
#
# NOTE: Create-TAPPaaS-LXC.sh's own gpu-block auto-wiring (which vllm-amd relies
# on to seed the *initial* cgroup/mount lines at container-create time) is keyed
# to AMD's kfd/render field names and does not recognize this module's NVIDIA
# gpu-block shape — so unlike vllm-amd's patch script, this one cannot assume
# the lines already exist. Each device is appended on first sight and replaced
# (by matching on its minor, which is stable across reboots — only the major
# shifts) on subsequent runs.
MODULE_JSON="/root/tappaas/${MODULE}.json"
VMID="$(jq -r '.vmid // empty' "$MODULE_JSON" 2>/dev/null)"
CONF="/etc/pve/lxc/${VMID}.conf"
if [ -n "$VMID" ] && [ -f "$CONF" ]; then
  changed=0
  for dev in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
    [ -c "$dev" ] || continue
    LIVE_MAJ="$(printf '%d' "0x$(stat -c '%t' "$dev")")"
    LIVE_MIN="$(printf '%d' "0x$(stat -c '%T' "$dev")")"

    if ! grep -qF "lxc.mount.entry: ${dev} ${dev#/} none bind,optional,create=file" "$CONF"; then
      echo "lxc.mount.entry: ${dev} ${dev#/} none bind,optional,create=file" >> "$CONF"
      changed=1
    fi

    if grep -q "^lxc\.cgroup2\.devices\.allow: c [0-9]\+:${LIVE_MIN} rwm$" "$CONF"; then
      if ! grep -q "^lxc.cgroup2.devices.allow: c ${LIVE_MAJ}:${LIVE_MIN} rwm$" "$CONF"; then
        sed -i -E "s|^lxc\.cgroup2\.devices\.allow: c [0-9]+:${LIVE_MIN} rwm\$|lxc.cgroup2.devices.allow: c ${LIVE_MAJ}:${LIVE_MIN} rwm|" "$CONF"
        changed=1
      fi
    else
      echo "lxc.cgroup2.devices.allow: c ${LIVE_MAJ}:${LIVE_MIN} rwm" >> "$CONF"
      changed=1
    fi
  done
  if [ "$changed" -eq 1 ]; then
    ok "LXC ${VMID} cgroup allow / mount entries re-synced to live majors"
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
