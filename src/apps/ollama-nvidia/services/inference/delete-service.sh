#!/usr/bin/env bash
#
# TAPPaaS Ollama-NVIDIA Inference Service - Delete
#
# Hook called when a consuming module of ollama-nvidia:inference is removed.
# No-op placeholder; the ingress pinhole is withdrawn by rules-manager.
#
# Usage: delete-service.sh <module-name>
#

set -euo pipefail

echo "ollama-nvidia:inference delete-service called for module: ${1:-unknown} (no per-consumer provisioning needed)"
exit 0
