#!/usr/bin/env bash
# TAPPaaS Module: vllm-amd — Inspect
#
# Read-only status: which model is currently loaded/serving, and which
# models are present on disk under /mnt/models but not necessarily running.
# Analogous to tappaas-cluster-manager.sh inspect/inspect-vm — no mutation,
# safe to run anytime.
#
# Reuses the same ssh-to-node -> pct exec pattern as test.sh/test-model.sh
# (the sanctioned way to reach an LXC's contents from tappaas-cicd — do not
# ssh/pct raw outside a module script).
#
# Usage: ./scripts/inspect.sh [module]   (default: vllm-amd)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMNAME="${1:-vllm-amd}"
CONFIG_FILE="${SCRIPT_DIR}/${VMNAME}.json"
[[ -f "${CONFIG_FILE}" ]] || { echo "ERROR: ${CONFIG_FILE} not found — run from the module directory"; exit 1; }
VMID="${TAPPAAS_VMID_OVERRIDE:-$(jq -r '.vmid' "${CONFIG_FILE}")}"

_PRIMARY="tappaas1.mgmt.internal"
LXC_NODE="$(ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@${_PRIMARY}" \
    "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null" \
    | jq -r --argjson id "${VMID}" '.[] | select(.vmid==$id) | .node' 2>/dev/null)"
[[ -n "${LXC_NODE:-}" ]] || { echo "ERROR: cannot resolve the node hosting LXC ${VMID}"; exit 1; }
pct() { ssh -n -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@${LXC_NODE}.mgmt.internal" pct "$@"; }

echo ""
echo "=== vLLM AMD inspect (VMID: ${VMID} on ${LXC_NODE}) ==="
echo ""

echo "--- Currently serving (live API query) ---"
HTTP_CODE=$(pct exec "${VMID}" -- curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://127.0.0.1:8000/v1/models" 2>/dev/null || echo "000")
if [[ "${HTTP_CODE}" == "200" ]]; then
    pct exec "${VMID}" -- curl -s --connect-timeout 5 "http://127.0.0.1:8000/v1/models" 2>/dev/null \
        | jq -r '.data[] | "  - \(.id)  (max_model_len=\(.max_model_len // "?"))"'
else
    echo "  (vLLM API not responding — HTTP ${HTTP_CODE}; container may be stopped or model still loading)"
fi

echo ""
echo "--- Docker container status ---"
# Plain default output only — any shell-special char (pipe, braces) in a
# --format string gets reparsed/mangled across the ssh->pct->remote-shell
# double-hop (confirmed: '|' was interpreted as a real pipe operator).
pct exec "${VMID}" -- docker ps --filter name=vllm 2>/dev/null | sed 's/^/  /' \
    || echo "  (could not query docker)"

echo ""
echo "--- Models present on disk (/models — downloaded, not necessarily loaded) ---"
# NOTE: download-model.sh/test-model.sh assume /mnt/models, but the live
# instance actually serves from /models (confirmed 2026-07-02 — /mnt/models
# is empty). Those two scripts are stale relative to actual production;
# check both until download-model.sh is corrected.
pct exec "${VMID}" -- ls -la /models/ 2>/dev/null | tail -n +2 | sed 's/^/  /' \
    || echo "  (could not list /models)"
echo "  (also checking legacy /mnt/models path)"
pct exec "${VMID}" -- ls -la /mnt/models/ 2>/dev/null | tail -n +2 | sed 's/^/  /' \
    || true

echo ""
echo "--- docker-compose.yml active model reference ---"
pct exec "${VMID}" -- cat /opt/vllm/docker-compose.yml 2>/dev/null \
    | grep -E -- '--model|MODEL=' | sed 's/^/  /' \
    || echo "  (not found — check /opt/vllm/docker-compose.yml exists)"
echo ""
