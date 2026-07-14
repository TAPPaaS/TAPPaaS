#!/usr/bin/env bash
# TAPPaaS Module: ollama-nvidia — Inspect
#
# Read-only status: which models are pulled, which are currently VRAM-resident,
# and Docker/container health. Analogous to vllm-amd/scripts/inspect.sh — no
# mutation, safe to run anytime.
#
# Ollama serves multiple models dynamically (unlike vllm-amd's one-model-per-
# container-start), so there's no single "active model" compose-file line to
# grep — `ollama ps` (via docker exec) is the live equivalent, showing what's
# currently loaded into VRAM/RAM right now.
#
# Usage: ./scripts/inspect.sh [module]   (default: ollama-nvidia)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VMNAME="${1:-ollama-nvidia}"
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
echo "=== Ollama NVIDIA inspect (VMID: ${VMID} on ${LXC_NODE}) ==="
echo ""

echo "--- Pulled models (on disk, /models) ---"
HTTP_CODE=$(pct exec "${VMID}" -- curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://127.0.0.1:11434/api/tags" 2>/dev/null || echo "000")
if [[ "${HTTP_CODE}" == "200" ]]; then
    pct exec "${VMID}" -- curl -s --connect-timeout 5 "http://127.0.0.1:11434/api/tags" 2>/dev/null \
        | jq -r '.models[] | "  - \(.name)  (size=\(.size))"'
else
    echo "  (Ollama API not responding — HTTP ${HTTP_CODE}; container may be stopped)"
fi

echo ""
echo "--- Currently loaded (VRAM/RAM-resident right now) ---"
pct exec "${VMID}" -- docker exec ollama ollama ps 2>/dev/null | sed 's/^/  /' \
    || echo "  (could not query 'ollama ps')"

echo ""
echo "--- Docker container status ---"
# Plain default output only — special chars in --format get reparsed across
# the ssh->pct->remote-shell double-hop (confirmed on vllm-amd's inspect.sh).
pct exec "${VMID}" -- docker ps --filter name=ollama 2>/dev/null | sed 's/^/  /' \
    || echo "  (could not query docker)"

echo ""
echo "--- GPU status (nvidia-smi inside container) ---"
pct exec "${VMID}" -- docker exec ollama nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv 2>/dev/null | sed 's/^/  /' \
    || echo "  (could not query nvidia-smi)"
echo ""
