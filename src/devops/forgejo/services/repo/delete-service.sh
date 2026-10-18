#!/usr/bin/env bash
#
# TAPPaaS Forgejo Repo Service — Delete
#
# Takes the consumer's read-only deploy key off its repository and removes
# /etc/secrets/forgejo-repo.* from the consumer's VM. The repository itself is
# KEPT: it is the site owner's content. Delete it in Forgejo when it is no
# longer wanted.
#
# Usage: delete-service.sh <consuming-module-name> [--dry-run]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

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

CONSUMING_JSON="${CONFIG_DIR}/${CONSUMING_MODULE}.json"
[[ -f "${CONSUMING_JSON}" ]] || die "consuming module config not found: ${CONSUMING_JSON}"
CONSUMING_VMNAME="$(jq -r '.vmname' "${CONSUMING_JSON}")"
CONSUMING_HOST="${CONSUMING_VMNAME}.$(jq -r '.zone0' "${CONSUMING_JSON}").internal"
PROVIDER_MODULE="$(resolve_provider_module "forgejo" "$(jq -r '.environment // ""' "${CONSUMING_JSON}")")"
PROVIDER_JSON="${CONFIG_DIR}/${PROVIDER_MODULE}.json"
ORG="websites"; REPO="${CONSUMING_VMNAME}"; KEY_TITLE="tappaas-${CONSUMING_VMNAME}"
TOKEN_FILE="/home/tappaas/secrets/forgejo-sites.token"

info "${BOLD}forgejo:repo delete-service${CL}: unwiring ${BL}${CONSUMING_MODULE}${CL} (the repository ${ORG}/${REPO} is kept)"
if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "  ${YW}[dry-run]${CL} would remove deploy key ${KEY_TITLE} and /etc/secrets/forgejo-repo.* on ${CONSUMING_HOST}"
    exit 0
fi

if [[ -f "${PROVIDER_JSON}" && -s "${TOKEN_FILE}" ]]; then
    API="http://$(jq -r '.vmname' "${PROVIDER_JSON}").$(jq -r '.zone0' "${PROVIDER_JSON}").internal:3000/api/v1"
    AUTH="Authorization: token $(cat "${TOKEN_FILE}")"
    for id in $(curl -sf --max-time 20 -H "${AUTH}" "${API}/repos/${ORG}/${REPO}/keys" \
                | jq -r --arg t "${KEY_TITLE}" '.[] | select(.title == $t) | .id' 2>/dev/null); do
        curl -sf --max-time 20 -X DELETE -H "${AUTH}" "${API}/repos/${ORG}/${REPO}/keys/${id}" >/dev/null \
            && info "  ${GN}✓${CL} deploy key ${KEY_TITLE} removed" || warn "  could not remove deploy key ${id}"
    done
else
    warn "  Forgejo (${PROVIDER_MODULE}) or its token is gone — no deploy key to remove"
fi

ssh -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes \
    "tappaas@${CONSUMING_HOST}" 'sudo rm -f /etc/secrets/forgejo-repo.env /etc/secrets/forgejo-repo.known_hosts /etc/secrets/forgejo-repo.key /etc/secrets/forgejo-repo.key.pub' \
    && info "  ${GN}✓${CL} /etc/secrets/forgejo-repo.* removed on ${CONSUMING_HOST}" \
    || warn "  ${CONSUMING_HOST} unreachable — its /etc/secrets/forgejo-repo.* go with the VM"
