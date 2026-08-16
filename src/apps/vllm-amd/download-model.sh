#!/usr/bin/env bash
# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# This file incorporates work covered by the following copyright and permission notice:
# Copyright (c) 2021-2025 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
#
# TAPPaaS Module: vllm-amd — Model Downloader
#
# Downloads models into the vLLM models bind mount (/opt/vllm/models) for serving.
# Run INSIDE the LXC container (or anywhere with the hf CLI).
#
# Usage:
#   ./download-model.sh smoke      — Qwen2.5-3B (quick validation, ~2GB)
#   ./download-model.sh prod       — Qwen2.5-14B (production, ~28GB)
#   ./download-model.sh eagle      — Qwen2.5-14B + EAGLE-3 draft (~31GB total)
#   ./download-model.sh <hf-repo>  — Any HuggingFace model

set -euo pipefail

# Must match the models bind mount dst that discover.sh records in
# <module>.meta.json (.bindMounts[0].dst). /mnt/models is not mounted — models
# written there stay inside the container's rootfs, invisible to vLLM and off
# the backing storage. Override with MODEL_DIR= for a non-standard layout.
MODEL_DIR="${MODEL_DIR:-/opt/vllm/models}"

# Ensure the `hf` CLI is available. Debian 12's Python is PEP 668
# externally-managed, so a bare `pip install` aborts; this LXC is dedicated to
# vLLM, so installing into the system environment is fine. The CLI is `hf` —
# `huggingface-cli` is deprecated and hard-fails on huggingface_hub >= 1.0.
if ! command -v hf &> /dev/null; then
    echo "Installing huggingface_hub..."
    pip install -q --break-system-packages huggingface_hub
    # pip installs console scripts into /usr/local/bin, which is absent from a
    # non-login shell's PATH (as used by `pct exec ... bash -c`).
    export PATH="/usr/local/bin:${PATH}"
fi

download() {
    local repo="$1"
    local target="$2"
    echo ""
    echo "=== Downloading: ${repo} ==="
    echo "    Target: ${MODEL_DIR}/${target}"
    echo ""
    hf download "$repo" --local-dir "${MODEL_DIR}/${target}"
    echo "=== Done: ${repo} → ${MODEL_DIR}/${target} ==="
}

mkdir -p "$MODEL_DIR"

case "${1:-help}" in
    smoke)
        download "Qwen/Qwen2.5-3B-Instruct" "qwen2.5-3b"
        echo ""
        echo "Smoke test ready. Start with:"
        echo "  MODEL=qwen2.5-3b docker compose -f /opt/vllm/docker-compose.yml up -d"
        ;;
    prod)
        download "Qwen/Qwen2.5-14B-Instruct" "qwen2.5-14b"
        echo ""
        echo "Production model ready. Start with:"
        echo "  docker compose -f /opt/vllm/docker-compose.yml up -d"
        ;;
    eagle)
        download "Qwen/Qwen2.5-14B-Instruct" "qwen2.5-14b"
        download "ruipeterpan/Qwen2.5-14B-Instruct_EAGLE3_UltraChat" "qwen2.5-14b-eagle3"
        echo ""
        echo "EAGLE-3 speculative decoding ready. Start with:"
        echo "  docker compose -f /opt/vllm/docker-compose.yml --profile eagle up -d"
        ;;
    help|--help|-h)
        echo "Usage: $0 {smoke|prod|eagle|<hf-repo>}"
        echo ""
        echo "  smoke  — Qwen2.5-3B-Instruct (~2GB, quick validation)"
        echo "  prod   — Qwen2.5-14B-Instruct (~28GB, production)"
        echo "  eagle  — 14B + EAGLE-3 draft model (~31GB, speculative decoding)"
        echo "  <repo> — Any HuggingFace repo (e.g. meta-llama/Llama-3.3-70B-Instruct)"
        echo ""
        echo "Models downloaded to: ${MODEL_DIR}/"
        exit 0
        ;;
    *)
        # Custom HF repo — derive dir name from repo
        REPO="$1"
        DIR_NAME=$(echo "$REPO" | sed 's|.*/||' | tr '[:upper:]' '[:lower:]')
        download "$REPO" "$DIR_NAME"
        echo ""
        echo "Start with:"
        echo "  MODEL=${DIR_NAME} docker compose -f /opt/vllm/docker-compose.yml up -d"
        ;;
esac
