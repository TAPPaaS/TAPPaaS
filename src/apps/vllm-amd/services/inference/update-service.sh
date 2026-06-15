#!/usr/bin/env bash
#
# TAPPaaS vLLM-AMD Inference Service - Update
#
# Hook called when a consuming module of vllm-amd:inference is updated.
# No-op placeholder; the ingress pinhole is reconciled by rules-manager.
#
# Usage: update-service.sh <module-name>
#

set -euo pipefail

echo "vllm-amd:inference update-service called for module: ${1:-unknown} (no per-consumer provisioning needed)"
exit 0
