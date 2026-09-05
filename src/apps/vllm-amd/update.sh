#!/usr/bin/env bash
# TAPPaaS Module: vllm-amd — Update
#
# Updates vLLM container image and applies system patches
#
# Usage: ./update.sh vllm-amd

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f /home/tappaas/bin/common-install-routines.sh ]]; then
    . /home/tappaas/bin/common-install-routines.sh
fi
# Fallbacks: the source above is conditional, so never assume the house logger
# is present. Same levels, same gate (TAPPAAS_DEBUG) either way.
type info  >/dev/null 2>&1 || info()  { echo -e "\033[32m[Info]\033[m $*"; }
type warn  >/dev/null 2>&1 || warn()  { echo -e "\033[33m[Warning]\033[m $*"; }
type debug >/dev/null 2>&1 || debug() { [[ "${TAPPAAS_DEBUG:-0}" == "1" ]] || return 0; echo -e "\033[34m[Debug]\033[m $*"; }

# A converge step runs INSIDE the LXC, so its echoes cannot call the host's
# logger. Pipe a step's output through this to give every line a level:
#   pct exec … | _tag info     (news)      pct exec … | _tag debug   (detail)
# Blank lines are dropped — the remote blocks use them for spacing that the
# tagged form does not need.
# A WARNING:/ERROR: line is promoted to warn whatever level the caller asked
# for — detail may be demoted to debug, but a problem inside it must never be
# demoted with it.
_tag() {
    local _lvl="$1" _l
    while IFS= read -r _l; do
        [[ -n "${_l//[[:space:]]/}" ]] || continue
        case "${_l}" in
            WARNING:*|ERROR:*) warn "  ${_l}" ;;
            *)                 "${_lvl}" "  ${_l}" ;;
        esac
    done
    return 0
}

VMNAME="${1:-vllm-amd}"
CONFIG_FILE="${SCRIPT_DIR}/${VMNAME}.json"
VMID=$(jq -r '.vmid' "$CONFIG_FILE")

# Resolve live node and wrap pct as SSH call (pct only exists on Proxmox nodes)
_PRIMARY="tappaas1.mgmt.internal"
LXC_NODE="$(ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@${_PRIMARY}" \
    "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null" \
    | jq -r --argjson id "${VMID}" '.[] | select(.vmid==$id) | .node' 2>/dev/null)"
[[ -n "${LXC_NODE:-}" ]] || { echo "ERROR: cannot resolve node for LXC ${VMID}"; exit 1; }
# Use printf %q to shell-quote each arg before SSH join, preventing word-split
# of multi-word bash -c arguments across the ssh→pct double-hop.
pct() {
    local q
    printf -v q '%q ' "$@"
    ssh -n -o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new \
        "root@${LXC_NODE}.mgmt.internal" "pct ${q}"
}

info "Updating ${VMNAME} (VMID ${VMID} on ${LXC_NODE})"

# Step 0: Bootstrap Docker + /opt/vllm (idempotent)
debug "  bootstrap (docker + /opt/vllm)..."
pct exec "${VMID}" -- bash -c '
# Locale fix
echo "LC_ALL=C.UTF-8" >> /etc/environment
export LC_ALL=C.UTF-8

# Docker installeren als niet aanwezig
if ! command -v docker &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    echo "installed Docker"
fi

# /opt/vllm aanmaken als niet aanwezig
mkdir -p /opt/vllm

# docker-compose.yml aanmaken als niet aanwezig
#
# --enable-auto-tool-choice + --tool-call-parser are REQUIRED for OpenWebUI (and
# any OpenAI-compatible client that sends tools). Without them vLLM rejects every
# request carrying tool_choice:"auto" with
#   BadRequestError: "auto" tool choice requires --enable-auto-tool-choice and
#                    --tool-call-parser to be set
# which surfaces to the user as a failed chat, not as a configuration problem.
# `hermes` is the parser for Qwen2.5-style models (the qwen3_* parsers are for
# Qwen3). Change it if you serve a model family with a different tool format.
if [ ! -f /opt/vllm/docker-compose.yml ]; then
    cat > /opt/vllm/docker-compose.yml <<EOF
services:
  vllm:
    image: kyuz0/vllm-therock-gfx1151@sha256:f56f8d66c3efcf2de024251f6ff2328c5aa94b3ae34b2f74a36740b970f98d9c
    container_name: vllm
    restart: unless-stopped
    entrypoint: ["python", "-m", "vllm.entrypoints.openai.api_server"]
    devices:
      - /dev/kfd:/dev/kfd
      - /dev/dri/renderD128:/dev/dri/renderD128
    group_add:
      - render
    volumes:
      # Must be the LXC-side models bind mount that discover.sh records in
      # <module>.meta.json (.bindMounts[0].dst) and cluster:lxc creates as mp0.
      # /mnt/models is not mounted — it is plain container rootfs, so models
      # written there are invisible to vLLM and never reach the backing storage.
      - /opt/vllm/models:/models
    ports:
      - "8000:8000"
    environment:
      - HSA_OVERRIDE_GFX_VERSION=11.5.1
    command: >
      --model /models/YOUR_MODEL_HERE
      --served-model-name vllm
      --host 0.0.0.0
      --port 8000
      --enable-auto-tool-choice
      --tool-call-parser hermes
EOF
    echo "created docker-compose.yml — set your model path!"
fi
' | _tag info

# Step 0b: Pin image digest in live docker-compose.yml (idempotent).
# Uses SSH heredoc to the Proxmox node to avoid pct-wrapper word-split issues
# when passing complex sed replacement strings through the SSH→pct chain.
debug "  pinning image digest..."
PINNED_IMAGE="kyuz0/vllm-therock-gfx1151@sha256:f56f8d66c3efcf2de024251f6ff2328c5aa94b3ae34b2f74a36740b970f98d9c"
# `bash -s` (not a bare heredoc): without a command ssh starts a LOGIN shell,
# which prints the node's MOTD — the Debian licence banner that used to appear
# mid-update under this heading. Passing a command makes the session
# non-interactive, so no MOTD, and the heredoc still arrives on stdin.
{ ssh -T -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
    "root@${LXC_NODE}.mgmt.internal" bash -s << NODEEOF
if pct exec ${VMID} -- test -f /opt/vllm/docker-compose.yml 2>/dev/null; then
    pct exec ${VMID} -- sed -i 's|image: kyuz0/vllm-therock-gfx1151.*|image: ${PINNED_IMAGE}|' /opt/vllm/docker-compose.yml
    echo "Pinned: \$(pct exec ${VMID} -- grep 'image:' /opt/vllm/docker-compose.yml)"
else
    echo "WARNING: /opt/vllm/docker-compose.yml not found in LXC ${VMID}"
fi
NODEEOF
} | _tag debug

# Step 1: OS updates inside LXC
debug "  applying OS updates..."
# -qq: silent when there is nothing to do (the common case on a converge run),
# and still prints the package actions when there ARE any. The default level
# emitted a dozen "Reading package lists/Building dependency tree" lines per
# invocation whether or not anything changed.
pct exec "${VMID}" -- bash -c '
export DEBIAN_FRONTEND=noninteractive
apt-get -qq update && apt-get -qq upgrade -y
apt-get -qq autoremove -y
' | _tag info

# Step 2: Pull latest vLLM container image
debug "  pulling latest vLLM image..."
# The pull and the prune are progress/housekeeping, not news: their output goes
# to the log only. What the operator needs is the one-line verdict — whether
# the container was actually recreated — so only that is echoed.
pct exec "${VMID}" -- bash -c '
cd /opt/vllm
OLD_IMAGE=$(docker inspect vllm --format "{{.Image}}" 2>/dev/null || echo "none")
docker compose pull -q

# Recreate only if image changed
NEW_IMAGE=$(docker compose images -q vllm 2>/dev/null || echo "new")
if [[ "$OLD_IMAGE" != "$NEW_IMAGE" ]]; then
    # compose writes its progress to stderr, which would bypass the tag pipe
    # and land untagged; the verdict below is what the operator needs, and a
    # failure says so explicitly rather than being swallowed.
    if docker compose up -d >/dev/null 2>&1; then
        echo "new image pulled — vLLM container recreated and restarted"
    else
        echo "ERROR: new image pulled but docker compose up failed"
        exit 1
    fi
fi

# Cleanup old images
docker image prune -f >/dev/null 2>&1 || true
' | _tag info

# Step 3: Status dump — DIAGNOSTIC detail, not a result. test.sh is what
# asserts the module is healthy; printing a container/GPU/disk report on every
# converge said nothing an operator acts on. Skipped entirely unless debugging,
# which also saves the round-trip into the LXC.
if [[ "${TAPPAAS_DEBUG:-0}" == "1" ]]; then
    debug "  status:"
    pct exec "${VMID}" -- bash -c '
    echo "containers: $(docker ps --format "{{.Names}} {{.Image}} ({{.Status}})" | paste -sd "; " -)"
    if ls /dev/kfd /dev/dri/renderD128 >/dev/null 2>&1; then
        echo "gpu: /dev/kfd + /dev/dri/renderD128 present"
    else
        echo "WARNING: GPU devices not accessible"
    fi
    echo "disk: $(df -h / | tail -1 | awk "{print \$3\" used of \"\$2\" (\"\$5\")\"}")"
    ' | _tag debug
fi

info "${VMNAME} converged"
