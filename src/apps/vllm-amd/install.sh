#!/usr/bin/env bash
# install.sh — TAPPaaS vllm-amd module installer (post-create steps only)
# Repo: ErikDaniel007/private_tappaas
# Path: src/apps/vllm-amd/install.sh
#
# Run FROM tappaas-cicd by install-module.sh AFTER the cluster:lxc service has
# created the container (issue #203). Container creation, networking and DNS are
# now owned by cluster:lxc (Create-TAPPaaS-LXC.sh + install-service.sh); this
# script only does the module-specific work that is NOT shared:
#   1. patch-host-gpu.sh  — prepare GPU devices/permissions on the host
#   2. update.sh          — install Docker + vLLM inside the container
#
# Run discover.sh first to (re)generate <module>.meta.json for this host's GPU.
# Usage: ./install.sh <module>   (e.g. ./install.sh vllm-amd)

# Remote ssh commands embed locally-computed values that expand client-side.
# shellcheck disable=SC2029
set -euo pipefail

GN="\033[1;92m"; RD="\033[01;31m"; CL="\033[m"
ok()  { printf "${GN}  ✅ %-30s${CL}\n" "$1"; }
die() { printf "${RD}  ❌ FATAL: %s${CL}\n" "$1"; exit 1; }

[ -z "${1:-}" ]         && die "Usage: ./install.sh <module>  (e.g. ./install.sh vllm-amd)"
[ -f "${1}.json" ]      || die "Not found: ${1}.json"
[ -f "${1}.meta.json" ] || die "Not found: ${1}.meta.json — run discover.sh first"

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
# helpers + meta/config the post-create steps need (cluster:lxc removes the
# meta after creation, so re-ship it here).
ok "copying meta + module scripts to $NODE"
ssh "$TARGET" "mkdir -p $TAPPAAS_DIR"
scp "${MODULE}.json"                        "${TARGET}:${TAPPAAS_DIR}/${MODULE}.json"
scp "${MODULE}.meta.json"                   "${TARGET}:${TAPPAAS_DIR}/${MODULE}.meta.json"
scp "${SCRIPT_DIR}/patch-host-gpu.sh"       "${TARGET}:${TAPPAAS_DIR}/patch-host-gpu.sh"
scp "${SCRIPT_DIR}/update.sh"               "${TARGET}:${TAPPAAS_DIR}/update.sh"

# Step 1: Prepare host GPU (devices, render group, permissions, models dir).
echo "  [1/2] Patching host GPU on $NODE..."
ssh "$TARGET" "bash ${TAPPAAS_DIR}/patch-host-gpu.sh ${MODULE}"

# Step 2: Install Docker + vLLM inside the (already created) container.
echo "  [2/2] Installing Docker + vLLM inside the container..."
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
echo "  ⚠️  One manual step:"
echo "     Set your model in /opt/vllm/docker-compose.yml inside the LXC"
echo "     Then: pct exec <vmid> -- bash -c 'cd /opt/vllm && docker compose up -d'"
echo ""
