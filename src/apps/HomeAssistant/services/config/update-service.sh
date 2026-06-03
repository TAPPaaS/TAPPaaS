#!/usr/bin/env bash
#
# TAPPaaS HomeAssistant Config Service - Update
#
# Idempotent: re-applies trusted_proxies and external_url derived from current
# TAPPaaS SSoT. Safe to run on every update cycle.
#
# Usage: update-service.sh <module-name>
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
[[ -n "${MODULE}" ]] || { echo "Usage: $0 <module-name>"; exit 1; }

# Delegate to install-service (idempotent)
exec "${SCRIPT_DIR}/install-service.sh" "${MODULE}"
