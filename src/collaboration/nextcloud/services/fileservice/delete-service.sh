#!/usr/bin/env bash
#
# TAPPaaS Nextcloud Service - Delete
#
# A consumer of nextcloud:fileservice is being deleted: take its connector out of
# Nextcloud, so Nextcloud stops pointing at a server that is gone. What the
# converge (update-service.sh) put there, per connector:
#
#   onlyoffice  /etc/secrets/onlyoffice.env, and the eurooffice app settings
#               nextcloud-configure-eurooffice applied through occ
#               (DocumentServerUrl, DocumentServerInternalUrl, StorageUrl,
#               jwt_secret, jwt_header — and settings_error, the check's verdict)
#   talk        /etc/secrets/talk.env, and Talk's turn_servers / stun_servers
#               (Talk falls back to its default STUN server)
#   hpb         /etc/secrets/hpb.env, and Talk's signaling_servers / secret
#
# The env file goes first: every configure unit is gated on its file, so nothing
# re-applies the settings at the next boot. Only this consumer's wiring is taken:
# the file must name the consumer (its internal host, or for the HPB its public
# name). A file that names another consumer is left alone, settings included.
#
# Never fails the consumer's delete: an unreachable Nextcloud keeps the stale
# settings, and the warning says how to remove them by hand.
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
# with the same-environment Nextcloud.
CONSUMER_ENV=""
[[ -f "${CONSUMER_JSON}" ]] && \
    CONSUMER_ENV=$(jq -r '.environment // empty' "${CONSUMER_JSON}" 2>/dev/null || true)
NEXTCLOUD_JSON="${CONFIG_DIR}/$(resolve_provider_module nextcloud "${CONSUMER_ENV}").json"
readonly NEXTCLOUD_JSON

info "nextcloud:fileservice delete-service for module: ${MODULE}"
if [[ ! -f "${NEXTCLOUD_JSON}" ]]; then
    info "  Nextcloud is not installed — nothing to remove"
    exit 0
fi

CONNECTOR=""
[[ -f "${CONSUMER_JSON}" ]] && \
    CONNECTOR=$(jq -r '.config["nextcloud:fileservice"].connector // .connector // empty' "${CONSUMER_JSON}" 2>/dev/null || true)

# What each connector left on the Nextcloud VM, and how its env file names it.
VMNAME_C=$(jq -r '.vmname // empty' "${CONSUMER_JSON}" 2>/dev/null || true)
ZONE_C=$(jq -r '.zone0 // empty' "${CONSUMER_JSON}" 2>/dev/null || true)
CONSUMER_HOST="${VMNAME_C:-${MODULE}}.${ZONE_C:-mgmt}.internal"
case "${CONNECTOR}" in
    onlyoffice)
        ENV_FILE="onlyoffice.env"; UNIT="nextcloud-configure-eurooffice.service"; APP="eurooffice"
        KEYS="DocumentServerUrl DocumentServerInternalUrl StorageUrl jwt_secret jwt_header settings_error"
        MARKER="${CONSUMER_HOST}" ;;
    talk)
        ENV_FILE="talk.env"; UNIT="nextcloud-configure-talk-turn.service"; APP="spreed"
        KEYS="turn_servers stun_servers"
        MARKER="${CONSUMER_HOST}" ;;
    hpb)
        ENV_FILE="hpb.env"; UNIT="nextcloud-configure-hpb.service"; APP="spreed"
        KEYS="signaling_servers signaling_secret"
        MARKER="$(module_public_domain "${VMNAME_C}" "${CONSUMER_ENV}" "$(cat "${CONSUMER_JSON}" 2>/dev/null)")"
        MARKER="${MARKER:-${CONSUMER_HOST}}" ;;
    "")
        info "  ${MODULE} declares no connector — nothing to remove"
        exit 0 ;;
    *)
        warn "  ${MODULE} declares connector '${CONNECTOR}', which this service does not know — nothing removed"
        exit 0 ;;
esac

NC_HOST="$(jq -r '.vmname' "${NEXTCLOUD_JSON}").$(jq -r '.zone0' "${NEXTCLOUD_JSON}").internal"

# One ssh: the file must be ours (or gone); then file, unit and settings go.
# nextcloud-occ runs through systemd-run --pty: without a terminal its writes
# still take effect (update-service.sh measured it), only its output is lost.
remote="
f=/etc/secrets/${ENV_FILE}
if sudo test -f \"\$f\"; then
    sudo grep -qF -- '${MARKER}' \"\$f\" || { echo OTHER; exit 0; }
    sudo rm -f \"\$f\"
fi
sudo systemctl stop ${UNIT} 2>/dev/null || true
for k in ${KEYS}; do sudo nextcloud-occ --no-interaction config:app:delete ${APP} \"\$k\" >/dev/null 2>&1 || true; done
echo REMOVED"
if ! out=$(ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR \
        "tappaas@${NC_HOST}" "${remote}" 2>/dev/null); then
    warn "  could not reach Nextcloud at ${NC_HOST} — ${MODULE}'s ${CONNECTOR} connector stays configured there."
    warn "  By hand: rm /etc/secrets/${ENV_FILE}; nextcloud-occ config:app:delete ${APP} <key> for: ${KEYS}"
    exit 0
fi
case "${out}" in
    *OTHER*)   info "  /etc/secrets/${ENV_FILE} on ${NC_HOST} is wired to another ${CONNECTOR} consumer — left as it is" ;;
    *REMOVED*) info "  ${GN}✓${CL} ${CONNECTOR} connector removed from Nextcloud (${ENV_FILE}; ${APP}: ${KEYS// /, })" ;;
    *)         warn "  removing the ${CONNECTOR} connector on ${NC_HOST} gave no answer — check /etc/secrets/${ENV_FILE} there" ;;
esac
exit 0
