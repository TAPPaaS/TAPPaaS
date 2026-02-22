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
NODE=$(jq -r '.node // "tappaas2"' "$CONFIG_FILE")

echo ""
echo "=== Updating vLLM AMD Module ==="
echo "VM: ${VMNAME} (VMID: ${VMID})"

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
if [ ! -f /opt/vllm/docker-compose.yml ]; then
    cat > /opt/vllm/docker-compose.yml <<EOF
services:
  vllm:
    image: kyuz0/vllm-therock-gfx1151:latest
    container_name: vllm
    restart: unless-stopped
    entrypoint: ["python", "-m", "vllm.entrypoints.openai.api_server"]
    devices:
      - /dev/kfd:/dev/kfd
      - /dev/dri/renderD128:/dev/dri/renderD128
    group_add:
      - render
    volumes:
      - /mnt/models:/models
    ports:
      - "8000:8000"
    environment:
      - HSA_OVERRIDE_GFX_VERSION=11.5.1
    command: >
      --model /models/YOUR_MODEL_HERE
      --served-model-name vllm
      --host 0.0.0.0
      --port 8000
EOF
    echo "docker-compose.yml created — set your model path!"
fi
'

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
