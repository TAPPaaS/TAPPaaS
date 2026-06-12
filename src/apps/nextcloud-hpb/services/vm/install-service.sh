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
readonly HPB_JSON="/home/tappaas/config/nextcloud-hpb.json"

VMNAME=$(jq -r '.vmname' "${HPB_JSON}")
ZONE=$(jq -r '.zone0' "${HPB_JSON}")

info "nextcloud-hpb:vm install-service — verifying HPB is reachable for module: ${MODULE}"

if nc -z -w5 "${VMNAME}.${ZONE}.internal" 8080 2>/dev/null; then
    info "${GN}✓${CL} nextcloud-hpb is reachable at ${VMNAME}.${ZONE}.internal:8080"
else
    die "nextcloud-hpb is not responding on port 8080 — ensure the nextcloud-hpb module is fully installed"
fi
