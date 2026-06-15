#!/usr/bin/env bash
#
# TAPPaaS vLLM-AMD Inference Service - Install
#
# Hook called when a consuming module declares dependsOn ['vllm-amd:inference'].
# The cross-zone ingress pinhole (services/inference/pinhole.json) is synthesised
# by rules-manager; this hook is a no-op placeholder for per-consumer provisioning.
#
# Usage: install-service.sh <module-name>
#

set -euo pipefail

echo "vllm-amd:inference install-service called for module: ${1:-unknown} (no per-consumer provisioning needed)"
exit 0
