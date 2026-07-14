#!/usr/bin/env bash
#
# TAPPaaS Ollama-NVIDIA Inference Service - Install
#
# Hook called when a consuming module declares dependsOn ['ollama-nvidia:inference'].
# The cross-zone ingress pinhole (services/inference/pinhole.json) is synthesised
# by rules-manager; this hook is a no-op placeholder for per-consumer provisioning.
#
# Usage: install-service.sh <module-name>
#

set -euo pipefail

echo "ollama-nvidia:inference install-service called for module: ${1:-unknown} (no per-consumer provisioning needed)"
exit 0
