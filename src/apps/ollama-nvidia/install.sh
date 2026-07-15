#!/usr/bin/env bash
# install.sh — TAPPaaS ollama-nvidia module installer (post-create steps only)
#
# Run FROM tappaas-cicd by install-module.sh AFTER the cluster:lxc service has
# created the container. Container creation, networking and DNS are owned by
# cluster:lxc (Create-TAPPaaS-LXC.sh + install-service.sh); this script only
# does the module-specific work that is NOT shared:
#   1. patch-host-gpu.sh  — prepare NVIDIA GPU devices/permissions on the host
#   2. update.sh          — install Docker + nvidia-container-toolkit + Ollama
#                            inside the container
#
# Run discover.sh first to (re)generate <module>.meta.json for this host's GPU.
# Usage: ./install.sh <module>   (e.g. ./install.sh ollama-nvidia)

# Remote ssh commands embed locally-computed values that expand client-side.
# shellcheck disable=SC2029
set -euo pipefail

GN="\033[1;92m"; RD="\033[01;31m"; CL="\033[m"
ok()  { printf "${GN}  ✅ %-30s${CL}\n" "$1"; }
die() { printf "${RD}  ❌ FATAL: %s${CL}\n" "$1"; exit 1; }

[ -z "${1:-}" ]         && die "Usage: ./install.sh <module>  (e.g. ./install.sh ollama-nvidia)"
[ -f "${1}.json" ]      || die "Not found: ${1}.json"
[ -f "${1}.meta.json" ] || die "Not found: ${1}.meta.json (ships with the module — restore it from the repo)"

MODULE="$1"
NODE=$(jq -r '.node'   "${MODULE}.json")
VMNAME=$(jq -r '.vmname' "${MODULE}.json")
ZONE=$(jq -r '.zone0'  "${MODULE}.json")
TARGET="root@${NODE}.mgmt.internal"
TAPPAAS_DIR="/root/tappaas"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "=== TAPPaaS install (post-create): $MODULE ==="
echo "    node      : $NODE"
echo "    container : ${VMNAME}.${ZONE}.internal"
echo ""

# cluster:lxc has already created the container; ship the module-specific
# helpers + meta/config the post-create steps need.
ok "copying meta + module scripts to $NODE"
ssh "$TARGET" "mkdir -p $TAPPAAS_DIR"
scp "${MODULE}.json"                  "${TARGET}:${TAPPAAS_DIR}/${MODULE}.json"
scp "${MODULE}.meta.json"             "${TARGET}:${TAPPAAS_DIR}/${MODULE}.meta.json"
scp "${SCRIPT_DIR}/patch-host-gpu.sh" "${TARGET}:${TAPPAAS_DIR}/patch-host-gpu.sh"
scp "${SCRIPT_DIR}/update.sh"         "${TARGET}:${TAPPAAS_DIR}/update.sh"

# Step 1: Prepare host GPU (auto-installs the NVIDIA driver if the GPU is
# present but driverless, then devices, permissions, models dir).
echo "  [1/3] Patching host GPU on $NODE..."
ssh "$TARGET" "bash ${TAPPAAS_DIR}/patch-host-gpu.sh ${MODULE}"

# Step 2: Discovery — now that the driver is guaranteed working, validate the
# GPU against the module's floors and record VRAM/driver/device info into the
# meta, then re-ship it so update.sh reads fresh values (not the seed's nulls).
echo "  [2/3] Running hardware discovery against $NODE..."
(cd "$SCRIPT_DIR" && ./discover.sh "$MODULE")
scp "${SCRIPT_DIR}/${MODULE}.meta.json" "${TARGET}:${TAPPAAS_DIR}/${MODULE}.meta.json"

# Step 3: Install Docker + nvidia-container-toolkit + Ollama inside the container.
echo "  [3/3] Installing Docker + Ollama inside the container..."
ssh "$TARGET" "bash ${TAPPAAS_DIR}/update.sh ${MODULE}"

# Cleanup shipped files.
ssh "$TARGET" "rm -f \
  ${TAPPAAS_DIR}/${MODULE}.json \
  ${TAPPAAS_DIR}/${MODULE}.meta.json \
  ${TAPPAAS_DIR}/patch-host-gpu.sh \
  ${TAPPAAS_DIR}/update.sh"
ok "cleanup done on $NODE"

echo ""
ok "install complete: $MODULE on $NODE"
echo ""
echo "  Ollama is running with no models loaded yet. Pull one with:"
echo "     ./pull-model.sh smoke   (or: prod | large | <ollama-library-tag>)"
echo ""
