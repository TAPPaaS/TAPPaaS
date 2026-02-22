#!/usr/bin/env bash
# discover.sh — TAPPaaS hardware discovery for vllm-amd module
# Repo: ErikDaniel007/private_tappaas
# Path: modules/vllm-amd/discover.sh
# Runs FROM management host / tappaas-cicd, discovers hardware ON tappaas2 via SSH

set -euo pipefail

NODE="${1:-tappaas2}"
MGMT="mgmt.internal"
TARGET="root@${NODE}.${MGMT}"
OUT_JSON="vllm-amd.json"
OUT_META="vllm-amd.meta.json"

REQUIRED_CPU_PATTERN="Ryzen AI MAX\+ 395"
REQUIRED_VRAM_MIN_MB=32768

# --- Require JSON arg ---
[ -z "${1:-}" ] && { echo "❌ Usage: ./discover.sh <module>  (e.g. ./discover.sh vllm-amd)"; exit 1; }
[ -f "${1}.json" ] || { echo "❌ Not found: ${1}.json — run from module directory"; exit 1; }

MODULE="$1"
NODE=$(jq -r '.node // "tappaas2"' "${MODULE}.json")
TARGET="root@${NODE}.mgmt.internal"

echo "=== TAPPaaS discover: vllm-amd (via SSH → $NODE) ==="

# --- Run all hardware checks remotely, return JSON ---
REMOTE_DATA=$(ssh "$TARGET" bash <<'ENDSSH'
set -euo pipefail

CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs | tr ' ' '_')
HOST_CORES=$(nproc --all)

VRAM_LINE=$(dmesg 2>/dev/null | grep -i "amdgpu.*VRAM" | tail -1 || true)
VRAM_MB=$(echo "$VRAM_LINE" | grep -oP '\d+(?=M)' | head -1 || echo "0")

GTT_LINE=$(dmesg 2>/dev/null | grep -i "amdgpu.*GTT" | tail -1 || true)
GTT_MB=$(echo "$GTT_LINE" | grep -oP '\d+(?=M)' | head -1 || echo "0")

RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_MB=$(( RAM_KB / 1024 ))

KFD_MAJOR=0; KFD_MINOR=0
[ -c /dev/kfd ] && KFD_MAJOR=$(printf '%d' "0x$(stat -c '%t' /dev/kfd)") \
               && KFD_MINOR=$(printf '%d' "0x$(stat -c '%T' /dev/kfd)")

RENDER_NODE=""; RENDER_MAJOR=0; RENDER_MINOR=0
RENDER_PATH=$(ls /dev/dri/renderD* 2>/dev/null | head -1 || true)
if [ -n "$RENDER_PATH" ]; then
  RENDER_NODE=$(basename "$RENDER_PATH")
  RENDER_MAJOR=$(printf '%d' "0x$(stat -c '%t' "$RENDER_PATH")")
  RENDER_MINOR=$(printf '%d' "0x$(stat -c '%T' "$RENDER_PATH")")
fi

cat <<EOF
CPU_MODEL=$CPU_MODEL
HOST_CORES=$HOST_CORES
VRAM_MB=$VRAM_MB
GTT_MB=$GTT_MB
RAM_MB=$RAM_MB
KFD_MAJOR=$KFD_MAJOR
KFD_MINOR=$KFD_MINOR
RENDER_NODE=$RENDER_NODE
RENDER_MAJOR=$RENDER_MAJOR
RENDER_MINOR=$RENDER_MINOR
EOF
ENDSSH
)

# --- Parse remote output ---
CPU_MODEL=$(echo "$REMOTE_DATA"    | grep '^CPU_MODEL='    | cut -d= -f2- | tr '_' ' ')
HOST_CORES=$(echo "$REMOTE_DATA"   | grep '^HOST_CORES='   | cut -d= -f2)
VRAM_MB=$(echo "$REMOTE_DATA"      | grep '^VRAM_MB='      | cut -d= -f2)
GTT_MB=$(echo "$REMOTE_DATA"       | grep '^GTT_MB='       | cut -d= -f2)
RAM_MB=$(echo "$REMOTE_DATA"       | grep '^RAM_MB='       | cut -d= -f2)
KFD_MAJOR=$(echo "$REMOTE_DATA"    | grep '^KFD_MAJOR='    | cut -d= -f2)
KFD_MINOR=$(echo "$REMOTE_DATA"    | grep '^KFD_MINOR='    | cut -d= -f2)
RENDER_NODE=$(echo "$REMOTE_DATA"  | grep '^RENDER_NODE='  | cut -d= -f2)
RENDER_MAJOR=$(echo "$REMOTE_DATA" | grep '^RENDER_MAJOR=' | cut -d= -f2)
RENDER_MINOR=$(echo "$REMOTE_DATA" | grep '^RENDER_MINOR=' | cut -d= -f2)

echo "[CPU]  $CPU_MODEL"

# --- Validate ---
ERRORS=()
echo "$CPU_MODEL" | grep -qiE "$REQUIRED_CPU_PATTERN" \
  || ERRORS+=("CPU mismatch: got '$CPU_MODEL'")
[ "${VRAM_MB:-0}" -ge "$REQUIRED_VRAM_MIN_MB" ] \
  || ERRORS+=("VRAM too low: ${VRAM_MB}M, need >= ${REQUIRED_VRAM_MIN_MB}M")
[ "${KFD_MAJOR:-0}" -gt 0 ] \
  || ERRORS+=("ROCm: /dev/kfd not found on $NODE")
[ -n "${RENDER_NODE:-}" ] \
  || ERRORS+=("DRI: no renderD* node found on $NODE")

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo ""
  echo "❌ Hardware check FAILED:"
  for ERR in "${ERRORS[@]}"; do echo "  • $ERR"; done
  exit 1
fi

# --- Sizing ---
LXC_CORES=$(( HOST_CORES > 16 ? HOST_CORES - 8 : HOST_CORES / 2 ))
LXC_MEM_MB=$(( (RAM_MB * 75 / 100 / 1024) * 1024 ))

# --- Summary ---
GN="\033[1;92m"; RD="\033[01;31m"; CL="\033[m"

ok()  { printf "${GN}  ✅ %-22s: %s${CL}\n" "$1" "$2"; }
err() { printf "${RD}  ❌ %-22s: %s (threshold: %s)${CL}\n" "$1" "$2" "$3"; }

chk() {
  local label="$1" display="$2" value="$3" threshold="$4"
  [ "$value" -ge "$threshold" ] && ok "$label" "$display" || err "$label" "$display" ">= ${threshold}MB / $(( threshold / 1024 ))GB"
}

echo ""
echo "  === sizing summary ==="
chk "VRAM (BIOS)"      "${VRAM_MB}MB / $(( VRAM_MB / 1024 ))GB"         "$VRAM_MB"      32768
chk "GTT buffer"       "${GTT_MB}MB / $(( GTT_MB / 1024 ))GB"           "$GTT_MB"       16384
chk "Linux RAM"        "${RAM_MB}MB / $(( RAM_MB / 1024 ))GB"           "$RAM_MB"       16384
chk "LXC memory"       "${LXC_MEM_MB}MB / $(( LXC_MEM_MB / 1024 ))GB"  "$LXC_MEM_MB"  16384
[ "$LXC_CORES" -ge 8 ] \
  && ok  "LXC vCPUs"      "$LXC_CORES (of $HOST_CORES host cores)" \
  || err "LXC vCPUs"      "$LXC_CORES (of $HOST_CORES host cores)" ">= 8 cores"
[ "${KFD_MAJOR:-0}" -gt 0 ] \
  && ok  "/dev/kfd"       "${KFD_MAJOR}:${KFD_MINOR}" \
  || err "/dev/kfd"       "not found" "required for ROCm compute"
[ -n "${RENDER_NODE:-}" ] \
  && ok  "GPU render node" "$RENDER_NODE (${RENDER_MAJOR}:${RENDER_MINOR})" \
  || err "GPU render node" "not found" "required for GPU passthrough"
echo ""

# --- Write JSON ---
cat > "$OUT_JSON" <<EOF
{
  "version": "0.5.0",
  "node": "${NODE}",
  "vmid": 200,
  "vmtag": "TAPPaaS, AI, GPU, vLLM",
  "vmname": "vllm-amd",
  "cores": ${LXC_CORES},
  "memory": "${LXC_MEM_MB}",
  "diskSize": "32G",
  "storage": "local-lvm",
  "ostype": "debian",
  "bridge0": "lan",
  "zone0": "srv",
  "description": "vLLM AMD ROCm inference — Ryzen AI MAX+ 395 (${NODE})"
}
EOF

cat > "$OUT_META" <<EOF
{
  "module": "vllm-amd",
  "gpu": {
    "apu": "Ryzen AI MAX+ 395",
    "vram_mb": ${VRAM_MB},
    "gtt_mb": ${GTT_MB},
    "kfd_major": ${KFD_MAJOR},
    "kfd_minor": ${KFD_MINOR},
    "render_node": "${RENDER_NODE}",
    "render_major": ${RENDER_MAJOR},
    "render_minor": ${RENDER_MINOR}
  },
  "host_ram_mb": ${RAM_MB},
  "lxc_mem_mb": ${LXC_MEM_MB},
  "rocm_gfx_target": "gfx1151",
  "vllm_image": "kyuz0/vllm-therock-gfx1151:latest",
  "models_bind_src": "/mnt/models",
  "models_bind_dst": "/opt/models"
}
EOF

echo ""
echo "✅ Hardware OK — written: $OUT_JSON + $OUT_META"
echo "Next: run ./install.sh"