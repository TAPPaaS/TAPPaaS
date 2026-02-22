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
# Downloads models to /mnt/models/ for vLLM serving.
# Run INSIDE the LXC container (or anywhere with huggingface-cli).
#
# Usage:
#   ./download-model.sh smoke      — Qwen2.5-3B (quick validation, ~2GB)
#   ./download-model.sh prod       — Qwen2.5-14B (production, ~28GB)
#   ./download-model.sh eagle      — Qwen2.5-14B + EAGLE-3 draft (~31GB total)
#   ./download-model.sh <hf-repo>  — Any HuggingFace model

set -euo pipefail

MODEL_DIR="/mnt/models"

# Ensure huggingface-cli is available
if ! command -v huggingface-cli &> /dev/null; then
    echo "Installing huggingface_hub..."
    pip install -q huggingface_hub
fi

download() {
    local repo="$1"
    local target="$2"
    echo ""
    echo "=== Downloading: ${repo} ==="
    echo "    Target: ${MODEL_DIR}/${target}"
    echo ""
    huggingface-cli download "$repo" --local-dir "${MODEL_DIR}/${target}"
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
