#!/usr/bin/env bash
# test-var-prov:svc delete-service — no-op provider hook for the variant E2E test.
set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh
CONSUMER="${1:-}"
[[ -n "${CONSUMER}" ]] || { error "Usage: delete-service.sh <consumer-module-name>"; exit 1; }
info "test-var-prov:svc delete-service for consumer '${CONSUMER}' — no-op."
