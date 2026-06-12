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

# Variant-aware: derive hosts/URLs from the deployed configs, never hardcode the
# zone (modules deploy to srv, srvWork, srvCust …). Pair Nextcloud by variant.
MODULE="${1:-euro-office}"
CONFIG_DIR="/home/tappaas/config"
EO_JSON="${CONFIG_DIR}/${MODULE}.json"
VARIANT="$(jq -r '.variant // empty' "${EO_JSON}" 2>/dev/null || true)"
NC_JSON="${CONFIG_DIR}/nextcloud.json"
[[ -n "${VARIANT}" && -f "${CONFIG_DIR}/nextcloud-${VARIANT}.json" ]] && NC_JSON="${CONFIG_DIR}/nextcloud-${VARIANT}.json"

_fqdn()  { echo "$(jq -r '.vmname' "$1").$(jq -r '.zone0' "$1").internal"; }
_proxy() { jq -r '.config["firewall:proxy"].proxyDomain // .proxyDomain // empty' "$1"; }

EUROOFFICE_HOST="$(_fqdn "${EO_JSON}")"
NEXTCLOUD_HOST="$(_fqdn "${NC_JSON}")"
ONLYOFFICE_URL="https://$(_proxy "${EO_JSON}")"
NEXTCLOUD_URL="https://$(_proxy "${NC_JSON}")/"

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
     sudo -u nextcloud nextcloud-occ config:app:set onlyoffice DocumentServerInternalUrl --value='http://${EUROOFFICE_HOST}/' >> /tmp/occ.out 2>&1
     sudo -u nextcloud nextcloud-occ config:app:set onlyoffice StorageUrl                --value='${NEXTCLOUD_URL}' >> /tmp/occ.out 2>&1
     sudo -u nextcloud nextcloud-occ config:app:set onlyoffice jwt_secret                --value='${JWT_SECRET}' >> /tmp/occ.out 2>&1
     sudo -u nextcloud nextcloud-occ config:app:set onlyoffice jwt_header                --value='Authorization' >> /tmp/occ.out 2>&1
     cat /tmp/occ.out" \
    && info "  JWT secret synced to Nextcloud successfully." \
    || { error "  Failed to sync JWT to Nextcloud."; exit 1; }
