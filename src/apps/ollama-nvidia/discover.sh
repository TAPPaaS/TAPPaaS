#!/usr/bin/env bash
# discover.sh — TAPPaaS hardware discovery for ollama-nvidia module
# Runs FROM management host / tappaas-cicd, discovers hardware ON the module's
# node (read from <module>.json) via SSH
#
# Unlike vllm-amd's discover.sh (hardcoded to one exact AMD APU model), this
# validates a minimum VRAM floor and minimum driver version rather than an
# exact GPU model string — the module works on any NVIDIA card meeting the
# floors (min_vram_mb / min_driver_version in the meta), so a GPU upgrade
# needs no code change, just a re-run of discovery.

set -euo pipefail

# discover only updates the meta (device majors are boot-dynamic); the curated
# cluster:lxc <module>.json is left untouched (same convention as vllm-amd,
# issue #203).
OUT_META="ollama-nvidia.meta.json"

# --- Require JSON arg ---
[ -z "${1:-}" ] && { echo "❌ Usage: ./discover.sh <module>  (e.g. ./discover.sh ollama-nvidia)"; exit 1; }
[ -f "${1}.json" ] || { echo "❌ Not found: ${1}.json — run from module directory"; exit 1; }
[ -f "${1}.meta.json" ] || { echo "❌ Not found: ${1}.meta.json — cannot merge discovery into it"; exit 1; }

MODULE="$1"
NODE=$(jq -r '.node // empty' "${MODULE}.json")
[ -n "$NODE" ] || { echo "❌ No 'node' set in ${MODULE}.json — set the target Proxmox node first"; exit 1; }
TARGET="root@${NODE}.mgmt.internal"

REQUIRED_VRAM_MIN_MB=$(jq -r '.min_vram_mb // 8192' "${MODULE}.meta.json")
REQUIRED_DRIVER_MIN=$(jq -r '.min_driver_version // 570' "${MODULE}.meta.json")

echo "=== TAPPaaS discover: ollama-nvidia (via SSH → $NODE) ==="

# --- Run all hardware checks remotely, return JSON ---
REMOTE_DATA=$(ssh "$TARGET" bash <<'ENDSSH'
set -euo pipefail

HOST_CORES=$(nproc --all)
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_MB=$(( RAM_KB / 1024 ))

GPU_NAME="none"; VRAM_MB=0; COMPUTE_CAP="0"; DRIVER_VERSION="0"
if command -v nvidia-smi &>/dev/null; then
  QUERY=$(nvidia-smi --query-gpu=name,memory.total,compute_cap,driver_version \
            --format=csv,noheader,nounits 2>/dev/null | head -1 || true)
  if [ -n "$QUERY" ]; then
    GPU_NAME=$(echo "$QUERY"        | cut -d, -f1 | xargs | tr ' ' '_')
    VRAM_MB=$(echo "$QUERY"         | cut -d, -f2 | xargs)
    COMPUTE_CAP=$(echo "$QUERY"     | cut -d, -f3 | xargs)
    DRIVER_VERSION=$(echo "$QUERY"  | cut -d, -f4 | xargs)
  fi
fi

# /dev/nvidia-uvm is created lazily (on first CUDA context / nvidia_uvm module
# load), so on a freshly booted host it's often absent even though the driver
# is fine. Load it before checking devices; patch-host-gpu.sh makes this
# persistent across reboots via modules-load.d.
nvidia-modprobe -u -c=0 2>/dev/null || modprobe nvidia_uvm 2>/dev/null || true

dev_majmin() {
  # $1: device path -> prints "major minor" or "0 0" if absent
  if [ -c "$1" ]; then
    printf '%d %d' "0x$(stat -c '%t' "$1")" "0x$(stat -c '%T' "$1")"
  else
    echo "0 0"
  fi
}
read -r NV0_MAJ NV0_MIN   <<<"$(dev_majmin /dev/nvidia0)"
read -r NVCTL_MAJ NVCTL_MIN <<<"$(dev_majmin /dev/nvidiactl)"
read -r UVM_MAJ UVM_MIN   <<<"$(dev_majmin /dev/nvidia-uvm)"
read -r UVMT_MAJ UVMT_MIN <<<"$(dev_majmin /dev/nvidia-uvm-tools)"

cat <<EOF
HOST_CORES=$HOST_CORES
RAM_MB=$RAM_MB
GPU_NAME=$GPU_NAME
VRAM_MB=$VRAM_MB
COMPUTE_CAP=$COMPUTE_CAP
DRIVER_VERSION=$DRIVER_VERSION
NV0_MAJ=$NV0_MAJ
NV0_MIN=$NV0_MIN
NVCTL_MAJ=$NVCTL_MAJ
NVCTL_MIN=$NVCTL_MIN
UVM_MAJ=$UVM_MAJ
UVM_MIN=$UVM_MIN
UVMT_MAJ=$UVMT_MAJ
UVMT_MIN=$UVMT_MIN
EOF
ENDSSH
)

# --- Parse remote output ---
HOST_CORES=$(echo "$REMOTE_DATA"     | grep '^HOST_CORES='     | cut -d= -f2)
RAM_MB=$(echo "$REMOTE_DATA"         | grep '^RAM_MB='         | cut -d= -f2)
GPU_NAME=$(echo "$REMOTE_DATA"       | grep '^GPU_NAME='       | cut -d= -f2 | tr '_' ' ')
VRAM_MB=$(echo "$REMOTE_DATA"        | grep '^VRAM_MB='        | cut -d= -f2)
COMPUTE_CAP=$(echo "$REMOTE_DATA"    | grep '^COMPUTE_CAP='    | cut -d= -f2)
DRIVER_VERSION=$(echo "$REMOTE_DATA" | grep '^DRIVER_VERSION=' | cut -d= -f2)
NV0_MAJ=$(echo "$REMOTE_DATA"        | grep '^NV0_MAJ='        | cut -d= -f2)
NV0_MIN=$(echo "$REMOTE_DATA"        | grep '^NV0_MIN='        | cut -d= -f2)
NVCTL_MAJ=$(echo "$REMOTE_DATA"      | grep '^NVCTL_MAJ='      | cut -d= -f2)
NVCTL_MIN=$(echo "$REMOTE_DATA"      | grep '^NVCTL_MIN='      | cut -d= -f2)
UVM_MAJ=$(echo "$REMOTE_DATA"        | grep '^UVM_MAJ='        | cut -d= -f2)
UVM_MIN=$(echo "$REMOTE_DATA"        | grep '^UVM_MIN='        | cut -d= -f2)
UVMT_MAJ=$(echo "$REMOTE_DATA"       | grep '^UVMT_MAJ='       | cut -d= -f2)
UVMT_MIN=$(echo "$REMOTE_DATA"       | grep '^UVMT_MIN='       | cut -d= -f2)

echo "[GPU]  ${GPU_NAME} (compute ${COMPUTE_CAP}, driver ${DRIVER_VERSION})"

# --- Validate ---
ERRORS=()
[ "$GPU_NAME" != "none" ] \
  || ERRORS+=("No NVIDIA GPU detected on $NODE (nvidia-smi missing or empty)")
[ "${VRAM_MB:-0}" -ge "$REQUIRED_VRAM_MIN_MB" ] \
  || ERRORS+=("GPU memory too low: ${VRAM_MB}M, need >= ${REQUIRED_VRAM_MIN_MB}M")
DRIVER_MAJOR="${DRIVER_VERSION%%.*}"
[ "${DRIVER_MAJOR:-0}" -ge "$REQUIRED_DRIVER_MIN" ] 2>/dev/null \
  || ERRORS+=("Driver too old: ${DRIVER_VERSION}, need >= ${REQUIRED_DRIVER_MIN}.xx (Ollama's floor for this compute capability range)")
[ "${NV0_MAJ:-0}" -gt 0 ] \
  || ERRORS+=("/dev/nvidia0 not found on $NODE")
[ "${NVCTL_MAJ:-0}" -gt 0 ] \
  || ERRORS+=("/dev/nvidiactl not found on $NODE")
[ "${UVM_MAJ:-0}" -gt 0 ] \
  || ERRORS+=("/dev/nvidia-uvm not found on $NODE")

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo ""
  echo "❌ Hardware check FAILED:"
  for ERR in "${ERRORS[@]}"; do echo "  • $ERR"; done
  exit 1
fi

# --- Sizing (same formula as vllm-amd's discover.sh) ---
LXC_CORES=$(( HOST_CORES > 16 ? HOST_CORES - 8 : HOST_CORES / 2 ))
LXC_MEM_MB=$(( (RAM_MB * 75 / 100 / 1024) * 1024 ))

# --- Summary ---
GN="\033[1;92m"; CL="\033[m"
ok()  { printf "${GN}  ✅ %-22s: %s${CL}\n" "$1" "$2"; }

echo ""
echo "  === sizing summary ==="
ok "GPU"            "${GPU_NAME}"
ok "VRAM"           "${VRAM_MB}MB / $(( VRAM_MB / 1024 ))GB (floor: $(( REQUIRED_VRAM_MIN_MB / 1024 ))GB)"
ok "Compute cap"    "${COMPUTE_CAP}"
ok "Driver"         "${DRIVER_VERSION} (floor: ${REQUIRED_DRIVER_MIN}.xx)"
ok "Linux RAM"      "${RAM_MB}MB / $(( RAM_MB / 1024 ))GB"
ok "LXC sizing ref" "${LXC_CORES} vCPUs, ${LXC_MEM_MB}MB (of ${HOST_CORES} host cores) — set in ollama-nvidia.json"
ok "/dev/nvidia0"       "${NV0_MAJ}:${NV0_MIN}"
ok "/dev/nvidiactl"     "${NVCTL_MAJ}:${NVCTL_MIN}"
ok "/dev/nvidia-uvm"    "${UVM_MAJ}:${UVM_MIN}"
[ "${UVMT_MAJ:-0}" -gt 0 ] \
  && ok "/dev/nvidia-uvm-tools" "${UVMT_MAJ}:${UVMT_MIN}" \
  || echo "  (nvidia-uvm-tools not present — some driver versions create it lazily on first CUDA context)"
echo ""

# --- Merge discovered values into the existing meta.json (same discipline as
# vllm-amd: NEVER touch the curated <module>.json, merge-not-overwrite meta).
# The key is nvidia_gpu, NOT gpu: Create-TAPPaaS-LXC.sh fires its AMD-shaped
# passthrough block on any non-empty .gpu key and would write malformed conf
# lines (empty kfd/render majors) that break pct start. ---
tmp=$(mktemp)
jq --arg name "$GPU_NAME" --argjson vram "${VRAM_MB:-0}" \
   --arg cc "$COMPUTE_CAP" --arg drv "$DRIVER_VERSION" \
   --argjson nv0maj "${NV0_MAJ:-0}" --argjson nv0min "${NV0_MIN:-0}" \
   --argjson nvctlmaj "${NVCTL_MAJ:-0}" --argjson nvctlmin "${NVCTL_MIN:-0}" \
   --argjson uvmmaj "${UVM_MAJ:-0}" --argjson uvmmin "${UVM_MIN:-0}" \
   --argjson uvmtmaj "${UVMT_MAJ:-0}" --argjson uvmtmin "${UVMT_MIN:-0}" \
   --argjson ram "${RAM_MB}" \
   '.nvidia_gpu.name = $name | .nvidia_gpu.vram_mb = $vram | .nvidia_gpu.compute_cap = $cc | .nvidia_gpu.driver_version = $drv
    | .nvidia_gpu.nvidia0_major = $nv0maj | .nvidia_gpu.nvidia0_minor = $nv0min
    | .nvidia_gpu.nvidiactl_major = $nvctlmaj | .nvidia_gpu.nvidiactl_minor = $nvctlmin
    | .nvidia_gpu.uvm_major = $uvmmaj | .nvidia_gpu.uvm_minor = $uvmmin
    | .nvidia_gpu.uvm_tools_major = $uvmtmaj | .nvidia_gpu.uvm_tools_minor = $uvmtmin
    | .host_ram_mb = $ram' \
   "$OUT_META" > "$tmp" && mv "$tmp" "$OUT_META"

echo ""
echo "✅ Hardware OK — merged GPU discovery into: $OUT_META"
echo "Next: run install-module.sh ollama-nvidia"
