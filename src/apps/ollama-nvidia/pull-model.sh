#!/usr/bin/env bash
# pull-model.sh — TAPPaaS ollama-nvidia model puller + smoke test
#
# Replaces vllm-amd's download-model.sh + scripts/install-model.sh: Ollama has
# no HF-safetensors download step and no compose-file --model flag to patch —
# `ollama pull <tag>` is self-sufficient, so there's one script instead of two.
#
# Run FROM tappaas-cicd (resolves the LXC's live node via pvesh, same pattern
# as test.sh/update.sh).
#
# Usage:
#   ./pull-model.sh smoke  [module]  — qwen2.5:3b   (quick validation, ~2GB)
#   ./pull-model.sh prod   [module]  — qwen2.5:14b  (production, ~9GB Q4)
#   ./pull-model.sh large  [module]  — llama3.1:70b (~40GB Q4 — exercises the
#                                       hybrid GPU+CPU layer offload this
#                                       module exists for; vllm-amd cannot do
#                                       this at all on comparable hardware)
#   ./pull-model.sh <ollama-library-tag> [module]  — any tag from ollama.com/library

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -z "${1:-}" ] && { echo "Usage: $0 {smoke|prod|large|<tag>} [module]"; exit 1; }
ARG="$1"
VMNAME="${2:-ollama-nvidia}"
CONFIG_FILE="${SCRIPT_DIR}/${VMNAME}.json"
[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: ${CONFIG_FILE} not found — run from the module directory"; exit 1; }
VMID="${TAPPAAS_VMID_OVERRIDE:-$(jq -r '.vmid' "$CONFIG_FILE")}"

case "$ARG" in
    smoke) TAG="qwen2.5:3b" ;;
    prod)  TAG="qwen2.5:14b" ;;
    large) TAG="llama3.1:70b" ;;
    help|--help|-h)
        echo "Usage: $0 {smoke|prod|large|<tag>} [module]"
        echo ""
        echo "  smoke  — qwen2.5:3b   (~2GB, quick validation)"
        echo "  prod   — qwen2.5:14b  (~9GB Q4, fully GPU-resident on 12GB VRAM)"
        echo "  large  — llama3.1:70b (~40GB Q4, hybrid GPU+CPU offload — the"
        echo "           capability vllm-amd cannot offer at all on this hardware)"
        echo "  <tag>  — any tag from https://ollama.com/library"
        exit 0
        ;;
    *) TAG="$ARG" ;;
esac

_PRIMARY="tappaas1.mgmt.internal"
LXC_NODE="$(ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@${_PRIMARY}" \
    "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null" \
    | jq -r --argjson id "${VMID}" '.[] | select(.vmid==$id) | .node' 2>/dev/null)"
[[ -n "${LXC_NODE:-}" ]] || { echo "ERROR: cannot resolve the node hosting LXC ${VMID}"; exit 1; }
pct() { ssh -n -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@${LXC_NODE}.mgmt.internal" pct "$@"; }

echo ""
echo "=== Pulling ${TAG} into ollama-nvidia (VMID: ${VMID}) ==="
echo ""
# ollama pull streams progress to stdout; give it plenty of time for large tags.
pct exec "${VMID}" -- docker exec ollama ollama pull "${TAG}"

echo ""
echo "=== Smoke test: ${TAG} ==="
RESPONSE=$(pct exec "${VMID}" -- curl -s --connect-timeout 30 --max-time 300 \
    -X POST "http://127.0.0.1:11434/v1/chat/completions" \
    -H "Content-Type:application/json" \
    -d "'{\"model\":\"${TAG}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in exactly 3 words.\"}],\"max_tokens\":20}'" \
    2>/dev/null || true)

if echo "$RESPONSE" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
    echo "OK — response: $(echo "$RESPONSE" | jq -r '.choices[0].message.content')"
else
    echo "WARNING: smoke test did not return a valid completion."
    echo "  Raw response: ${RESPONSE}"
    echo "  (For 'large' tags this can simply mean the CPU-offloaded layers"
    echo "   are still loading — retry the curl by hand after a minute.)"
fi
