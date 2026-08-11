#!/usr/bin/env bash
#
# TAPPaaS nextcloud-hpb VM Service - Install
#
# Verifies the HPB VM is reachable before dependent modules install.
#
# Usage: install-service.sh <module-name>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
readonly CONFIG_DIR="/home/tappaas/config"
readonly CONSUMER_JSON="${CONFIG_DIR}/${MODULE}.json"
# Resolve HPB's config environment-awarely: a consumer deployed into an
# environment pairs with the same-environment provider; fall back to the shared
# config otherwise. Was .variant until that field was retired (#438).
CONSUMER_ENV=""
[[ -n "${MODULE}" && -f "${CONSUMER_JSON}" ]] && \
    CONSUMER_ENV=$(jq -r '.environment // empty' "${CONSUMER_JSON}" 2>/dev/null || true)
HPB_JSON="${CONFIG_DIR}/$(resolve_provider_module nextcloud-hpb "${CONSUMER_ENV}").json"
readonly HPB_JSON

VMNAME=$(jq -r '.vmname' "${HPB_JSON}")
ZONE=$(jq -r '.zone0' "${HPB_JSON}")

info "nextcloud-hpb:vm install-service — verifying HPB is reachable for module: ${MODULE}"

if nc -z -w5 "${VMNAME}.${ZONE}.internal" 8080 2>/dev/null; then
    info "${GN}✓${CL} nextcloud-hpb is reachable at ${VMNAME}.${ZONE}.internal:8080"
else
    die "nextcloud-hpb is not responding on port 8080 — ensure the nextcloud-hpb module is fully installed"
fi
