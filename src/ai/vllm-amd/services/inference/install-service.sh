#!/usr/bin/env bash
#
# TAPPaaS vLLM-AMD Inference Service - Install
#
# Hook called when a consuming module declares dependsOn ['vllm-amd:inference'].
# There is no create-only work here — publishing the endpoint to the consumer is
# convergent, so it lives in update-service.sh and this execs it (#495/#503).
# The cross-zone ingress pinhole (services/inference/pinhole.json) is synthesised
# separately by rules-manager.
#
# Usage: install-service.sh <module-name>
#

set -euo pipefail

_VLLM_SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${_VLLM_SVC_DIR}/update-service.sh" "$@"
