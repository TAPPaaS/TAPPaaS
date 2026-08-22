#!/usr/bin/env bash
#
# TAPPaaS Nextcloud Service - Install
#
# Prerequisite gate, then the converge.
#
# The gate below is the ONLY install-only work here: a consumer must not be
# installed against a Nextcloud that is not up, so an unreachable provider is
# FATAL at install time. update-service.sh only warns in that case, because a
# re-apply must not fail a whole reconcile over a transiently unreachable peer.
#
# Everything else this service does — the ADR-COM-0002 OnlyOffice connector
# wiring — is convergent, so it lives in update-service.sh and is reached by the
# exec below (#495). Keeping it here as well is what made the connector converge
# on install only, the same defect class as #493/#494 (trusted_domains).
#
# Usage: install-service.sh <module-name>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
readonly CONFIG_DIR="/home/tappaas/config"
readonly CONSUMER_JSON="${CONFIG_DIR}/${MODULE}.json"
# Resolve Nextcloud's config environment-awarely: a consumer deployed into an
# environment pairs with the same-environment provider; fall back to the shared
# config otherwise. Was .variant until that field was retired (#438).
CONSUMER_ENV=""
[[ -n "${MODULE}" && -f "${CONSUMER_JSON}" ]] && \
    CONSUMER_ENV=$(jq -r '.environment // empty' "${CONSUMER_JSON}" 2>/dev/null || true)
NEXTCLOUD_JSON="${CONFIG_DIR}/$(resolve_provider_module nextcloud "${CONSUMER_ENV}").json"
readonly NEXTCLOUD_JSON

VMNAME=$(jq -r '.vmname' "${NEXTCLOUD_JSON}")
ZONE=$(jq -r '.zone0' "${NEXTCLOUD_JSON}")
INTERNAL_URL="http://${VMNAME}.${ZONE}.internal"

info "nextcloud:fileservice install-service — verifying Nextcloud is reachable for module: ${MODULE}"

if curl -sf --max-time 10 "${INTERNAL_URL}/status.php" | grep -q '"installed":true'; then
    info "${GN}✓${CL} Nextcloud is installed and reachable at ${INTERNAL_URL}"
else
    die "Nextcloud is not responding at ${INTERNAL_URL}/status.php — ensure the nextcloud module is fully installed"
fi

# Gate passed — hand off to the converge.
_NC_FS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${_NC_FS_DIR}/update-service.sh" "$@"
