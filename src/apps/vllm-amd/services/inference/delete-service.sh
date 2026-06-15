#!/usr/bin/env bash
#
# TAPPaaS vLLM-AMD Inference Service - Delete
#
# Hook called when a consuming module of vllm-amd:inference is removed.
# No-op placeholder; the ingress pinhole is withdrawn by rules-manager.
#
# Usage: delete-service.sh <module-name>
#

set -euo pipefail

echo "vllm-amd:inference delete-service called for module: ${1:-unknown} (no per-consumer provisioning needed)"
exit 0
