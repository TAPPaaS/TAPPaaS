#!/usr/bin/env bash
#
# TAPPaaS coturn TURN Service - Delete
#
# A consumer of coturn:turn is being deleted: drop it from coturn's relay
# allow-list (coturn_allow_peer put it there), so its old address is not left
# reachable through TURN once the host is gone or the address is reused.
#
# Usage: delete-service.sh <module-name>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
[[ -n "${MODULE}" ]] || die "Usage: delete-service.sh <module-name>"
readonly CONFIG_DIR="/home/tappaas/config"
readonly CONSUMER_JSON="${CONFIG_DIR}/${MODULE}.json"

# The same provider the install/update picked: an environment consumer pairs
# with the same-environment coturn.
CONSUMER_ENV=""
[[ -f "${CONSUMER_JSON}" ]] && \
    CONSUMER_ENV=$(jq -r '.environment // empty' "${CONSUMER_JSON}" 2>/dev/null || true)
COTURN_JSON="${CONFIG_DIR}/$(resolve_provider_module coturn "${CONSUMER_ENV}").json"
readonly COTURN_JSON

info "coturn:turn delete-service for module: ${MODULE}"
if [[ ! -f "${COTURN_JSON}" ]]; then
    info "  coturn is not installed — nothing to remove"
    exit 0
fi

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/turn-common.sh"
# Never fail the consumer's delete over this: an unreachable coturn keeps a
# stale entry until its next restart reads the file, and says so.
coturn_forget_peer "${COTURN_JSON}" "${MODULE}" \
    || warn "  could not reach coturn — remove '${MODULE}' from /var/lib/coturn/allowed-peers there by hand"
