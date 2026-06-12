#!/usr/bin/env bash
#
# TAPPaaS Euro-Office — Sync JWT Secret to Nextcloud
#
# Reads JWT_SECRET from /etc/secrets/euro-office.env on the euro-office VM
# and writes it (plus all connector URLs) to the Nextcloud Euro-Office app config.
#
# Run this after manually rotating the JWT_SECRET in /etc/secrets/euro-office.env
# and restarting the podman-euro-office service.
#
# Usage: ./sync-jwt.sh
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

EUROOFFICE_HOST="euro-office.srv.internal"
NEXTCLOUD_HOST="nextcloud.srv.internal"
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONLYOFFICE_URL="https://$(jq -r '.proxyDomain' "${_SCRIPT_DIR}/euro-office.json")"
NEXTCLOUD_URL="https://$(jq -r '.proxyDomain' "${_SCRIPT_DIR}/../nextcloud/nextcloud.json")/"
unset _SCRIPT_DIR

info "Reading JWT_SECRET from ${EUROOFFICE_HOST}…"
JWT_SECRET=$(ssh -o BatchMode=yes -o ConnectTimeout=15 \
    "tappaas@${EUROOFFICE_HOST}" \
    "sudo grep '^JWT_SECRET=' /etc/secrets/euro-office.env | cut -d= -f2-") || JWT_SECRET=""

if [[ -z "${JWT_SECRET}" ]]; then
    error "JWT_SECRET not found in /etc/secrets/euro-office.env on ${EUROOFFICE_HOST}"
    exit 1
fi

info "JWT_SECRET read (${#JWT_SECRET} characters). Writing to Nextcloud Euro-Office connector…"

ssh -o BatchMode=yes -o ConnectTimeout=15 "tappaas@${NEXTCLOUD_HOST}" \
    "sudo -u nextcloud nextcloud-occ config:app:set onlyoffice DocumentServerUrl         --value='${ONLYOFFICE_URL}' > /tmp/occ.out 2>&1
     sudo -u nextcloud nextcloud-occ config:app:set onlyoffice DocumentServerInternalUrl --value='http://euro-office.srv.internal/' >> /tmp/occ.out 2>&1
     sudo -u nextcloud nextcloud-occ config:app:set onlyoffice StorageUrl                --value='${NEXTCLOUD_URL}' >> /tmp/occ.out 2>&1
     sudo -u nextcloud nextcloud-occ config:app:set onlyoffice jwt_secret                --value='${JWT_SECRET}' >> /tmp/occ.out 2>&1
     sudo -u nextcloud nextcloud-occ config:app:set onlyoffice jwt_header                --value='Authorization' >> /tmp/occ.out 2>&1
     cat /tmp/occ.out" \
    && info "  JWT secret synced to Nextcloud successfully." \
    || { error "  Failed to sync JWT to Nextcloud."; exit 1; }
