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

echo ""
echo "=== Updating vLLM AMD Module ==="
echo "VM: ${VMNAME} (VMID: ${VMID}, node: ${LXC_NODE})"

# Step 0: Bootstrap Docker + /opt/vllm (idempotent)
echo ""
echo "=== Bootstrap ==="
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
    echo "Docker installed."
else
    echo "Docker already present."
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
    echo "docker-compose.yml created — set your model path!"
fi
'

# Step 0b: Pin image digest in live docker-compose.yml (idempotent).
# Uses SSH heredoc to the Proxmox node to avoid pct-wrapper word-split issues
# when passing complex sed replacement strings through the SSH→pct chain.
echo ""
echo "=== Pin Image Digest ==="
PINNED_IMAGE="kyuz0/vllm-therock-gfx1151@sha256:f56f8d66c3efcf2de024251f6ff2328c5aa94b3ae34b2f74a36740b970f98d9c"
ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
    "root@${LXC_NODE}.mgmt.internal" << NODEEOF
if pct exec ${VMID} -- test -f /opt/vllm/docker-compose.yml 2>/dev/null; then
    pct exec ${VMID} -- sed -i 's|image: kyuz0/vllm-therock-gfx1151.*|image: ${PINNED_IMAGE}|' /opt/vllm/docker-compose.yml
    echo "Pinned: \$(pct exec ${VMID} -- grep 'image:' /opt/vllm/docker-compose.yml)"
else
    echo "WARNING: /opt/vllm/docker-compose.yml not found in LXC ${VMID}"
fi
NODEEOF

# Step 1: OS updates inside LXC
echo ""
echo "=== System Updates ==="
pct exec "${VMID}" -- bash -c '
apt-get update && apt-get upgrade -y
apt-get autoremove -y
'

# Step 2: Pull latest vLLM container image
echo ""
echo "=== Pulling Latest vLLM Image ==="
pct exec "${VMID}" -- bash -c '
cd /opt/vllm
OLD_IMAGE=$(docker inspect vllm --format "{{.Image}}" 2>/dev/null || echo "none")
docker compose pull

# Recreate only if image changed
NEW_IMAGE=$(docker compose images -q vllm 2>/dev/null || echo "new")
if [[ "$OLD_IMAGE" != "$NEW_IMAGE" ]]; then
    echo "New image detected — recreating container..."
    docker compose up -d
    echo "vLLM container updated and restarted."
else
    echo "Image unchanged — no restart needed."
fi

# Cleanup old images
docker image prune -f
'

# Step 3: Show status
echo ""
echo "=== Status ==="
pct exec "${VMID}" -- bash -c '
echo "Docker containers:"
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
echo ""
echo "GPU access:"
ls -la /dev/kfd /dev/dri/renderD128 2>/dev/null || echo "WARNING: GPU devices not accessible"
echo ""
echo "Disk usage:"
df -h / | tail -1
'

echo ""
echo "=== Update Complete ==="
