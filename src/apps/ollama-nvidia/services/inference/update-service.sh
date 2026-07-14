#!/usr/bin/env bash
#
# TAPPaaS Ollama-NVIDIA Inference Service - Update
#
# Hook called when a consuming module of ollama-nvidia:inference is updated.
# No-op placeholder; the ingress pinhole is reconciled by rules-manager.
#
# Usage: update-service.sh <module-name>
#

set -euo pipefail

echo "ollama-nvidia:inference update-service called for module: ${1:-unknown} (no per-consumer provisioning needed)"
exit 0
