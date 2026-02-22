#!/usr/bin/env bash
# install.sh — TAPPaaS vllm-amd module installer
# Repo: ErikDaniel007/private_tappaas
# Path: src/apps/vllm-amd/install.sh
#
# Run FROM tappaas-cicd AFTER running discover.sh
# Reads node, vmname, zone0 from <module>.json
# Usage: ./install.sh <module>  (e.g. ./install.sh vllm-amd)

set -euo pipefail

# --- Color codes ---
GN="\033[1;92m"; RD="\033[01;31m"; CL="\033[m"
ok()  { printf "${GN}  ✅ %-30s${CL}\n" "$1"; }
die() { printf "${RD}  ❌ FATAL: %s${CL}\n" "$1"; exit 1; }

# --- Check argument and JSON files ---
[ -z "${1:-}" ]      && die "Usage: ./install.sh <module>  (e.g. ./install.sh vllm-amd)"
[ -f "${1}.json" ]   || die "Not found: ${1}.json — run discover.sh first"
[ -f "${1}.meta.json" ] || die "Not found: ${1}.meta.json — run discover.sh first"

MODULE="$1"

# --- Read node and hostname info from JSON ---
NODE=$(jq -r '.node'   "${MODULE}.json")
VMNAME=$(jq -r '.vmname' "${MODULE}.json")
ZONE=$(jq -r '.zone0'  "${MODULE}.json")
TARGET="root@${NODE}.mgmt.internal"
TAPPAAS_DIR="/root/tappaas"

# --- Find scripts (same dir first, then ../bin) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

find_script() {
  local name="$1"
  local found=""
  [ -f "${SCRIPT_DIR}/${name}" ]                       && found="${SCRIPT_DIR}/${name}"
  [ -z "$found" ] && [ -f "${SCRIPT_DIR}/../../bin/${name}" ] && found="${SCRIPT_DIR}/../../bin/${name}"
  [ -n "$found" ] || die "Script not found: ${name} (checked ${SCRIPT_DIR} and ../../bin)"
  echo "$found"
}

LXC_SCRIPT=$(find_script "Create-TAPPaaS-LXC.sh")
PATCH_SCRIPT=$(find_script "patch-host-gpu.sh")
UPDATE_SCRIPT=$(find_script "update.sh")

echo ""
echo "=== TAPPaaS install: $MODULE ==="
echo "    node      : $NODE"
echo "    container : ${VMNAME}.${ZONE}.internal"
echo ""

# --- Copy JSON and scripts to node ---
ok "copying config and scripts to $NODE"
ssh "$TARGET" "mkdir -p $TAPPAAS_DIR"
scp "${MODULE}.json"         "${TARGET}:${TAPPAAS_DIR}/${MODULE}.json"
scp "${MODULE}.meta.json"    "${TARGET}:${TAPPAAS_DIR}/${MODULE}.meta.json"
scp "$PATCH_SCRIPT"          "${TARGET}:${TAPPAAS_DIR}/patch-host-gpu.sh"
scp "$LXC_SCRIPT"            "${TARGET}:${TAPPAAS_DIR}/Create-TAPPaaS-LXC.sh"
scp "$UPDATE_SCRIPT"         "${TARGET}:${TAPPAAS_DIR}/update.sh"

# --- Step 1: Patch host GPU permissions ---
echo "  [1/3] Patching host GPU on $NODE..."
ssh "$TARGET" "bash ${TAPPAAS_DIR}/patch-host-gpu.sh ${MODULE}"

# --- Step 2: Create LXC container ---
echo "  [2/3] Creating LXC container on $NODE..."
ssh "$TARGET" "bash ${TAPPAAS_DIR}/Create-TAPPaaS-LXC.sh ${MODULE}"

# --- Step 3: Install Docker + vLLM inside LXC ---
echo "  [3/3] Installing Docker + vLLM inside LXC..."
ssh "$TARGET" "bash ${TAPPAAS_DIR}/update.sh ${MODULE}"

# --- Cleanup ---
ssh "$TARGET" "rm -f \
  ${TAPPAAS_DIR}/${MODULE}.json \
  ${TAPPAAS_DIR}/${MODULE}.meta.json \
  ${TAPPAAS_DIR}/patch-host-gpu.sh \
  ${TAPPAAS_DIR}/Create-TAPPaaS-LXC.sh \
  ${TAPPAAS_DIR}/update.sh"
ok "cleanup done on $NODE"

echo ""
ok "install complete: $MODULE on $NODE"
echo ""
echo "  ⚠️  One manual step:"
echo "     Set your model in /opt/vllm/docker-compose.yml inside the LXC"
echo "     Then: pct exec <vmid> -- bash -c 'cd /opt/vllm && docker compose up -d'"
echo ""