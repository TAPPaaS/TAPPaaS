#!/usr/bin/env bash
# test-model.sh — TAPPaaS vllm-amd model download + smoke test
# Repo: ErikDaniel007/private_tappaas
# Path: src/apps/vllm-amd/test-model.sh
#
# Run FROM tappaas-cicd after install.sh
# Downloads Qwen2.5-3B-Instruct into LXC, starts vLLM, runs a test prompt
# Usage: ./test-model.sh <module>

set -euo pipefail

# --- Color codes ---
GN="\033[1;92m"; RD="\033[01;31m"; YL="\033[1;93m"; CL="\033[m"
ok()   { printf "${GN}  ✅ %-30s${CL}\n" "$1"; }
warn() { printf "${YL}  ⚠️  %-30s — %s${CL}\n" "$1" "$2"; }
die()  { printf "${RD}  ❌ FATAL: %s${CL}\n" "$1"; exit 1; }

# --- Check argument ---
[ -z "${1:-}" ]         && die "Usage: ./test-model.sh <module>  (e.g. ./test-model.sh vllm-amd)"
[ -f "${1}.json" ]      || die "Not found: ${1}.json — run discover.sh first"
[ -f "${1}.meta.json" ] || die "Not found: ${1}.meta.json — run discover.sh first"

MODULE="$1"
MODEL_ID="Qwen/Qwen2.5-3B-Instruct"
MODEL_DIR_NAME="Qwen2.5-3B-Instruct"

# --- Read config ---
NODE=$(jq -r '.node'             "${MODULE}.json")
VMID=$(jq -r '.vmid'             "${MODULE}.json")
MODELS_DST=$(jq -r '.models_bind_dst' "${MODULE}.meta.json")
GFX_TARGET=$(jq -r '.rocm_gfx_target' "${MODULE}.meta.json")
TARGET="root@${NODE}.mgmt.internal"
MODEL_PATH="${MODELS_DST}/${MODEL_DIR_NAME}"

echo ""
echo "=== TAPPaaS test-model: $MODEL_ID ==="
echo "    node : $NODE  |  LXC VMID: $VMID"
echo "    path : $MODEL_PATH"
echo ""

# --- Step 1: Install huggingface_hub in LXC ---
echo "  [1/4] Installing huggingface-cli in LXC..."
ssh "$TARGET" "pct exec $VMID -- bash -c '
  apt-get install -y -qq python3-pip > /dev/null 2>&1
  pip3 install -q huggingface_hub[cli]
'" && ok "huggingface-cli ready" || die "huggingface-cli install failed"

# --- Step 2: Download model ---
echo "  [2/4] Downloading $MODEL_ID (~3GB, please wait)..."
ssh "$TARGET" "pct exec $VMID -- bash -c '
  huggingface-cli download $MODEL_ID \
    --local-dir $MODEL_PATH \
    --local-dir-use-symlinks False
'" && ok "model downloaded: $MODEL_PATH" || die "model download failed"

# --- Step 3: Update docker-compose.yml with model path ---
echo "  [3/4] Updating docker-compose.yml with model path..."
ssh "$TARGET" "pct exec $VMID -- bash -c '
  sed -i \"s|--model /opt/models/your-model-name|--model $MODEL_PATH|\" /opt/vllm/docker-compose.yml
'" && ok "docker-compose.yml updated" || die "sed on docker-compose.yml failed"

# --- Step 4: Start vLLM ---
echo "  [4/4] Starting vLLM..."
ssh "$TARGET" "pct exec $VMID -- bash -c '
  cd /opt/vllm && docker compose up -d
'" && ok "vLLM container started" || die "docker compose up failed"

# --- Wait for vLLM to be ready ---
echo ""
echo "  Waiting for vLLM API to be ready (max 60s)..."
READY=0
for i in $(seq 1 12); do
  STATUS=$(ssh "$TARGET" "pct exec $VMID -- bash -c \
    'curl -s -o /dev/null -w \"%{http_code}\" http://localhost:8000/health || echo 000'")
  if [ "$STATUS" = "200" ]; then
    READY=1
    break
  fi
  sleep 5
done

if [ "$READY" -eq 0 ]; then
  warn "vLLM health check" "not ready after 60s — check: pct exec $VMID -- docker logs vllm"
  exit 1
fi
ok "vLLM API healthy (HTTP 200)"

# --- Smoke test: send a prompt ---
echo ""
echo "  === smoke test ==="
RESPONSE=$(ssh "$TARGET" "pct exec $VMID -- bash -c '
  curl -s http://localhost:8000/v1/chat/completions \
    -H \"Content-Type: application/json\" \
    -d \"{
      \\\"model\\\": \\\"$MODEL_PATH\\\",
      \\\"messages\\\": [{\\\"role\\\": \\\"user\\\", \\\"content\\\": \\\"Reply with one word: working\\\"}],
      \\\"max_tokens\\\": 10
    }\"
'")

ANSWER=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // "no response"')

if [ "$ANSWER" != "no response" ] && [ -n "$ANSWER" ]; then
  ok "vLLM response: \"$ANSWER\""
  echo ""
  ok "smoke test PASSED — vLLM is working"
else
  warn "smoke test" "unexpected response: $RESPONSE"
fi

echo ""
echo "  Model : $MODEL_ID"
echo "  API   : http://<LXC-IP>:8000/v1"
echo "  Docs  : http://<LXC-IP>:8000/docs"
echo ""