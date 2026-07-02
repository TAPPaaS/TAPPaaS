#!/usr/bin/env bash
# TAPPaaS Module: vllm-amd — Install Model
#
# Generalizes test-model.sh's (hardcoded to Qwen2.5-3B-Instruct) working
# orchestration into a parameterized installer for any HuggingFace repo:
# download into the LXC, point docker-compose.yml at it, (re)start vLLM,
# wait for health, run a one-line smoke test.
#
# Run FROM tappaas-cicd. Downloading a 14B+ model can take a while —
# consider running with run_in_background if invoked from an agent session.
#
# Usage:
#   ./scripts/install-model.sh <hf-repo> [--dir-name <name>] [module]
#
# Examples:
#   ./scripts/install-model.sh Qwen/Qwen2.5-3B-Instruct
#   ./scripts/install-model.sh Qwen/Qwen3.6-14B-Instruct --dir-name qwen3.6-14b

set -euo pipefail

GN="\033[1;92m"; RD="\033[01;31m"; YL="\033[1;93m"; CL="\033[m"
ok()   { printf "${GN}  ✅ %-30s${CL}\n" "$1"; }
warn() { printf "${YL}  ⚠️  %-30s — %s${CL}\n" "$1" "$2"; }
die()  { printf "${RD}  ❌ FATAL: %s${CL}\n" "$1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MODEL_ID=""
DIR_NAME=""
MODULE="vllm-amd"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir-name) DIR_NAME="$2"; shift 2 ;;
        -h|--help)
            sed -n '/^# Usage:/,/^set /p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *)
            if [[ -z "${MODEL_ID}" ]]; then MODEL_ID="$1"; else MODULE="$1"; fi
            shift ;;
    esac
done

[[ -n "${MODEL_ID}" ]] || die "usage: install-model.sh <hf-repo> [--dir-name <name>] [module]"
[[ -z "${DIR_NAME}" ]] && DIR_NAME="$(echo "${MODEL_ID}" | sed 's|.*/||' | tr '[:upper:]' '[:lower:]')"

CONFIG_FILE="${SCRIPT_DIR}/${MODULE}.json"
[[ -f "${CONFIG_FILE}" ]] || die "${CONFIG_FILE} not found — run from the module directory"
NODE=$(jq -r '.node' "${CONFIG_FILE}")
VMID=$(jq -r '.vmid' "${CONFIG_FILE}")
TARGET="root@${NODE}.mgmt.internal"
# NOTE: download-model.sh uses /mnt/models, but the live instance actually
# serves from /models (confirmed 2026-07-02 — /mnt/models is empty on the
# running LXC). Matching the ACTUAL production convention, not the stale
# script default.
MODEL_PATH="/models/${DIR_NAME}"

echo ""
echo "=== TAPPaaS install-model: ${MODEL_ID} ==="
echo "    node : ${NODE}  |  LXC VMID: ${VMID}"
echo "    path : ${MODEL_PATH}"
echo ""

# --- Step 1: huggingface-cli ready ---
echo "  [1/4] Ensuring huggingface-cli is available in LXC..."
ssh "${TARGET}" "pct exec ${VMID} -- bash -c '
  command -v huggingface-cli >/dev/null 2>&1 || pip install -q huggingface_hub[cli]
'" && ok "huggingface-cli ready" || die "huggingface-cli install failed"

# --- Step 2: download ---
echo "  [2/4] Downloading ${MODEL_ID} into ${MODEL_PATH}..."
ssh "${TARGET}" "pct exec ${VMID} -- bash -c '
  huggingface-cli download ${MODEL_ID} --local-dir ${MODEL_PATH}
'" && ok "model downloaded: ${MODEL_PATH}" || die "model download failed"

# --- Step 3: point docker-compose.yml at it ---
echo "  [3/4] Updating docker-compose.yml model path..."
ssh "${TARGET}" "pct exec ${VMID} -- bash -c '
  sed -i -E \"s|--model [^[:space:]]+|--model ${MODEL_PATH}|\" /opt/vllm/docker-compose.yml
'" && ok "docker-compose.yml updated" || die "sed on docker-compose.yml failed"

# --- Step 4: (re)start ---
echo "  [4/4] Restarting vLLM..."
ssh "${TARGET}" "pct exec ${VMID} -- bash -c '
  cd /opt/vllm && docker compose up -d
'" && ok "vLLM container (re)started" || die "docker compose up failed"

# --- Wait for readiness ---
echo ""
echo "  Waiting for vLLM API to be ready (max 120s — larger models take longer)..."
READY=0
for _ in $(seq 1 24); do
    STATUS=$(ssh "${TARGET}" "pct exec ${VMID} -- bash -c \
        'curl -s -o /dev/null -w \"%{http_code}\" http://localhost:8000/health || echo 000'")
    [[ "${STATUS}" == "200" ]] && { READY=1; break; }
    sleep 5
done
[[ "${READY}" -eq 1 ]] || { warn "vLLM health check" "not ready after 120s — check: pct exec ${VMID} -- docker logs vllm"; exit 1; }
ok "vLLM API healthy (HTTP 200)"

# --- Smoke test ---
echo ""
echo "  === smoke test ==="
RESPONSE=$(ssh "${TARGET}" "pct exec ${VMID} -- curl -s http://localhost:8000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{\"model\":\"${MODEL_PATH}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with one word: working\"}],\"max_tokens\":10}'")
ANSWER=$(echo "${RESPONSE}" | jq -r '.choices[0].message.content // "no response"')

if [[ "${ANSWER}" != "no response" && -n "${ANSWER}" ]]; then
    ok "vLLM response: \"${ANSWER}\""
    ok "smoke test PASSED"
else
    warn "smoke test" "unexpected response: ${RESPONSE}"
fi

echo ""
echo "  Model : ${MODEL_ID}"
echo "  Path  : ${MODEL_PATH}"
echo "  API   : http://<LXC-IP>:8000/v1"
echo ""
echo "  Verify via: ./scripts/inspect.sh ${MODULE}"
