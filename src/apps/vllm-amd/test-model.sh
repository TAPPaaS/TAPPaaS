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
# Models directory as seen inside the LXC: the dst of the models bind mount that
# discover.sh records. There is no .models_bind_dst key — reading it yielded the
# string "null", so every path became "null/<model>" and the download landed
# outside the mount (or failed outright).
MODELS_DST=$(jq -r '.bindMounts[0].dst' "${MODULE}.meta.json")
[ -n "${MODELS_DST}" ] && [ "${MODELS_DST}" != "null" ] \
  || die "No models bind mount in ${MODULE}.meta.json (.bindMounts[0].dst) — run discover.sh"
GFX_TARGET=$(jq -r '.rocm_gfx_target' "${MODULE}.meta.json")
TARGET="root@${NODE}.mgmt.internal"
# Two different paths for the same files, do not mix them up:
#   MODEL_PATH      — LXC side, where hf download writes (the bind mount)
#   MODEL_PATH_CTR  — Docker side, what vLLM sees; compose maps the mount to /models
MODEL_PATH="${MODELS_DST}/${MODEL_DIR_NAME}"
MODEL_PATH_CTR="/models/${MODEL_DIR_NAME}"
# What the OpenAI API answers to. vLLM serves under --served-model-name, not
# under the model's path, so a request keyed by either path above gets a 404.
# Must match --served-model-name in the compose template (update.sh).
SERVED_NAME="vllm"

echo ""
echo "=== TAPPaaS test-model: $MODEL_ID ==="
echo "    node : $NODE  |  LXC VMID: $VMID"
echo "    path : $MODEL_PATH"
echo ""

# --- Step 1: Install huggingface_hub in LXC ---
echo "  [1/4] Installing hf CLI in LXC..."
ssh "$TARGET" "pct exec $VMID -- bash -c '
  apt-get install -y -qq python3-pip > /dev/null 2>&1
  pip3 install -q --break-system-packages huggingface_hub
'" && ok "hf CLI ready" || die "huggingface_hub install failed"

# --- Step 2: Download model ---
echo "  [2/4] Downloading $MODEL_ID (~3GB, please wait)..."
# pct exec runs a non-login shell whose PATH is /sbin:/bin:/usr/sbin:/usr/bin —
# pip puts the hf CLI in /usr/local/bin, which is absent from it.
# `hf`, not `huggingface-cli`: the latter is deprecated and hard-fails on
# huggingface_hub >= 1.0. --local-dir-use-symlinks went away in the same release.
ssh "$TARGET" "pct exec $VMID -- bash -c '
  export PATH=/usr/local/bin:\$PATH
  hf download $MODEL_ID --local-dir $MODEL_PATH
'" && ok "model downloaded: $MODEL_PATH" || die "model download failed"

# --- Step 3: Update docker-compose.yml with model path ---
echo "  [3/4] Updating docker-compose.yml with model path..."
# Rewrite whatever --model currently points at, then VERIFY. The old pattern
# matched '--model /opt/models/your-model-name', a string the compose template
# never writes (it emits '--model /models/YOUR_MODEL_HERE'), so the sed was a
# silent no-op that still reported success — vLLM then started on the
# placeholder and the failure only surfaced as an unhealthy container.
ssh "$TARGET" "pct exec $VMID -- bash -c '
  sed -i -E \"s|--model[[:space:]]+\\S+|--model $MODEL_PATH_CTR|\" /opt/vllm/docker-compose.yml
  grep -qF -- \"--model $MODEL_PATH_CTR\" /opt/vllm/docker-compose.yml
'" && ok "docker-compose.yml updated → $MODEL_PATH_CTR" || die "could not set --model in docker-compose.yml"

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
    'curl -s -o /dev/null -w \"%{http_code}\" http://localhost:8000/health'") || STATUS=000
  [ -n "$STATUS" ] || STATUS=000
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
      \\\"model\\\": \\\"$SERVED_NAME\\\",
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