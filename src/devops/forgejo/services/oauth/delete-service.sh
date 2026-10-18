#!/usr/bin/env bash
#
# TAPPaaS Forgejo OAuth Service — Delete
#
# Removes the consumer's OAuth2 application from Forgejo (so nobody can sign in
# to it with Forgejo any more), its kept secret on tappaas-cicd, and
# /etc/secrets/forgejo-oauth.env on the consumer's VM.
#
# Usage: delete-service.sh <consuming-module-name> [--dry-run]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../../service-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../service-lib.sh"

DRY_RUN=0
CONSUMING_MODULE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --force) shift ;;
        -*) die "unknown option: $1" ;;
        *) CONSUMING_MODULE="$1"; shift ;;
    esac
done
[[ -n "${CONSUMING_MODULE}" ]] || die "Usage: $0 <consuming-module-name> [--dry-run]"

fsvc_init "${CONSUMING_MODULE}"
APP="tappaas-${CONSUMING_VMNAME}"
STORE="/home/tappaas/secrets/forgejo-oauth-${CONSUMING_VMNAME}.env"

info "${BOLD}forgejo:oauth delete-service${CL}: unwiring ${BL}${CONSUMING_MODULE}${CL}"
if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "  ${YW}[dry-run]${CL} would delete the OAuth2 application ${APP}, ${STORE} and /etc/secrets/forgejo-oauth.env on ${CONSUMING_HOST}"
    exit 0
fi

if [[ -s "${FSVC_TOKEN_FILE}" ]]; then
    TOKEN="$(cat "${FSVC_TOKEN_FILE}")"
    for id in $(fsvc_api GET "/user/applications/oauth2?limit=50" 2>/dev/null | jq -r --arg n "${APP}" '.[] | select(.name == $n) | .id' 2>/dev/null); do
        fsvc_api DELETE "/user/applications/oauth2/${id}" >/dev/null \
            && info "  ${GN}✓${CL} OAuth2 application ${APP} deleted" || warn "  could not delete the OAuth2 application ${id}"
    done
else
    warn "  no token for ${FSVC_USER} — no application to delete"
fi
rm -f "${STORE}"
ssh "${FSVC_SSH_OPTS[@]}" "tappaas@${CONSUMING_HOST}" 'sudo rm -f /etc/secrets/forgejo-oauth.env' \
    && info "  ${GN}✓${CL} /etc/secrets/forgejo-oauth.env removed on ${CONSUMING_HOST}" \
    || warn "  ${CONSUMING_HOST} unreachable — its /etc/secrets/forgejo-oauth.env goes with the VM"
