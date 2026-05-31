#!/usr/bin/env bash
#
# TAPPaaS DNS Service - Update
#
# DNS host overrides are declarative and dns-manager's `add` updates an existing
# entry in place, so an update is identical to an install. This script therefore
# delegates to install-service.sh (idempotent). See issue #251.
#
# Usage: update-service.sh <module-name>
#

set -euo pipefail

# ── Logging ──────────────────────────────────────────────────────────

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

info "firewall:dns update-service delegating to install-service (idempotent) for: ${BL}${1:-}${CL}"

exec "${SCRIPT_DIR}/install-service.sh" "$@"
