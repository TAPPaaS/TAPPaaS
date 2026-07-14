#!/usr/bin/env bash
# TAPPaaS Module: ollama-nvidia — Update
#
# Updates the Ollama container image and applies system patches.
# Same overall shape as vllm-amd/update.sh: SSH+pct wrapper so this works both
# when invoked locally on the PVE host (by install.sh right after container
# creation) and when invoked later from tappaas-cicd by the periodic updater.
#
# Usage: ./update.sh ollama-nvidia

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f /home/tappaas/bin/common-install-routines.sh ]]; then
    . /home/tappaas/bin/common-install-routines.sh
fi

VMNAME="${1:-ollama-nvidia}"
CONFIG_FILE="${SCRIPT_DIR}/${VMNAME}.json"
VMID=$(jq -r '.vmid' "$CONFIG_FILE")

# Resolve live node and wrap pct as SSH call (pct only exists on Proxmox nodes)
_PRIMARY="tappaas1.mgmt.internal"
LXC_NODE="$(ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@${_PRIMARY}" \
    "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null" \
    | jq -r --argjson id "${VMID}" '.[] | select(.vmid==$id) | .node' 2>/dev/null)"
[[ -n "${LXC_NODE:-}" ]] || { echo "ERROR: cannot resolve node for LXC ${VMID}"; exit 1; }
pct() {
    local q
    printf -v q '%q ' "$@"
    ssh -n -o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new \
        "root@${LXC_NODE}.mgmt.internal" "pct ${q}"
}

echo ""
echo "=== Updating Ollama NVIDIA Module ==="
echo "VM: ${VMNAME} (VMID: ${VMID}, node: ${LXC_NODE})"

# The one-time bootstrap (Docker, nvidia-container-toolkit, matching in-LXC
# NVIDIA userspace libs) only runs while /root/tappaas/<module>.meta.json is
# still present on this host — install.sh ships it right before calling this
# script and deletes it right after, so it's only available on the very first
# (post-install) invocation, never on later periodic-update runs. That's
# exactly when the driver-version-matching step needs to happen anyway.
LOCAL_META="/root/tappaas/${VMNAME}.meta.json"
HOST_DRIVER_VERSION=""
if [[ -f "$LOCAL_META" ]]; then
    HOST_DRIVER_VERSION="$(jq -r '.nvidia_gpu.driver_version // empty' "$LOCAL_META")"
fi

# Step 0: Bootstrap Docker + nvidia-container-toolkit + /opt/ollama (idempotent)
echo ""
echo "=== Bootstrap ==="
pct exec "${VMID}" -- bash -c '
echo "LC_ALL=C.UTF-8" >> /etc/environment
export LC_ALL=C.UTF-8

if ! command -v docker &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates gnupg
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    echo "Docker installed."
else
    echo "Docker already present."
fi

if ! dpkg -l nvidia-container-toolkit &>/dev/null; then
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update -qq
    apt-get install -y -qq nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
    echo "nvidia-container-toolkit installed and Docker runtime configured."
else
    echo "nvidia-container-toolkit already present."
fi

mkdir -p /opt/ollama

if [ ! -f /opt/ollama/docker-compose.yml ]; then
    cat > /opt/ollama/docker-compose.yml <<EOF
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    volumes:
      - /opt/ollama/models:/models
      - ollama-data:/root/.ollama
    ports:
      - "11434:11434"
    environment:
      - OLLAMA_MODELS=/models
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=compute,utility
      - OLLAMA_MAX_LOADED_MODELS=4
      - OLLAMA_KEEP_ALIVE=24h
      - OLLAMA_LOAD_TIMEOUT=15m
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]

volumes:
  ollama-data:
EOF
    echo "docker-compose.yml created."
fi
'

# Step 0b: Install NVIDIA userspace driver libs inside the LXC, matching the
# host driver version exactly (--no-kernel-module: the LXC shares the host
# kernel, which already has the real kernel module loaded — this only needs
# the userspace libraries so nvidia-container-toolkit has something compatible
# to bind into the Docker containers it manages). Best-effort: if the exact
# .run URL doesn't resolve (patch version drift between what's hosted and what
# the host actually reports), warn and continue rather than aborting the whole
# update — see INSTALL.md troubleshooting if the later GPU checks fail.
if [[ -n "$HOST_DRIVER_VERSION" ]]; then
    echo ""
    echo "=== NVIDIA userspace driver (matching host: ${HOST_DRIVER_VERSION}) ==="
    pct exec "${VMID}" -- bash -c "
        if nvidia-smi &>/dev/null && [[ \"\$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null)\" == '${HOST_DRIVER_VERSION}' ]]; then
            echo 'Matching NVIDIA userspace driver already present.'
        else
            cd /tmp
            # Datacenter drivers (Tesla/A/H-series) are hosted under /tesla/,
            # consumer drivers (GeForce/RTX) under /XFree86/ — try both so the
            # module works regardless of which card class the host has.
            URL_DC=\"https://us.download.nvidia.com/tesla/${HOST_DRIVER_VERSION}/NVIDIA-Linux-x86_64-${HOST_DRIVER_VERSION}.run\"
            URL_CONSUMER=\"https://us.download.nvidia.com/XFree86/Linux-x86_64/${HOST_DRIVER_VERSION}/NVIDIA-Linux-x86_64-${HOST_DRIVER_VERSION}.run\"
            if curl -fsSL -o nvidia-driver.run \"\$URL_DC\" || curl -fsSL -o nvidia-driver.run \"\$URL_CONSUMER\"; then
                sh nvidia-driver.run --no-kernel-module --silent --no-nouveau-check --no-cc-version-check || \
                    echo 'WARNING: driver .run install reported errors — check /var/log/nvidia-installer.log'
                rm -f nvidia-driver.run
            else
                echo \"WARNING: could not fetch the ${HOST_DRIVER_VERSION} .run from either NVIDIA download path — install the matching userspace driver manually (see INSTALL.md).\"
            fi
        fi
    "
else
    echo ""
    echo "(No meta.json present — skipping one-time NVIDIA userspace driver install; already done on a prior run.)"
fi

# Step 1: OS updates inside LXC
echo ""
echo "=== System Updates ==="
pct exec "${VMID}" -- bash -c '
apt-get update && apt-get upgrade -y
apt-get autoremove -y
'

# Step 2: Pull latest Ollama image
echo ""
echo "=== Pulling Latest Ollama Image ==="
pct exec "${VMID}" -- bash -c '
cd /opt/ollama
OLD_IMAGE=$(docker inspect ollama --format "{{.Image}}" 2>/dev/null || echo "none")
docker compose pull

NEW_IMAGE=$(docker compose images -q ollama 2>/dev/null || echo "new")
if [[ "$OLD_IMAGE" != "$NEW_IMAGE" ]]; then
    echo "New image detected — recreating container..."
    docker compose up -d
    echo "Ollama container updated and restarted."
else
    echo "Image unchanged — no restart needed."
fi

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
ls -la /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm 2>/dev/null || echo "WARNING: GPU devices not accessible"
echo ""
echo "Disk usage:"
df -h / | tail -1
'

echo ""
echo "=== Update Complete ==="
