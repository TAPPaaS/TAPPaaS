#!/usr/bin/env bash
#
# coturn:turn test-service
#
# Is this consumer's TURN relay usable? The two things its install relies on:
# coturn answers on 3478, and coturn's shared secret is published to the
# management plane, where the consumer (nextcloud-hpb, Talk) reads it to align
# its own.
#
# Usage: test-service.sh <consumer-module-name>

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

CONSUMER="${1:-}"
if [[ -z "${CONSUMER}" ]]; then
    error "Usage: test-service.sh <consumer-module-name>"
    exit 1
fi
info "coturn:turn test-service for consumer: ${BL}${CONSUMER}${CL}"

# The same provider the install resolved: coturn in the consumer's environment,
# else the shared one.
CONSUMER_JSON="${CONFIG_DIR:-/home/tappaas/config}/${CONSUMER}.json"
CONSUMER_ENV="$(jq -r '.environment // empty' "${CONSUMER_JSON}" 2>/dev/null || true)"
COTURN_JSON="${CONFIG_DIR:-/home/tappaas/config}/$(resolve_provider_module coturn "${CONSUMER_ENV}").json"
COTURN_HOST="$(jq -r '.vmname' "${COTURN_JSON}").$(jq -r '.zone0' "${COTURN_JSON}").internal"

FAILURES=0
if nc -z -w5 "${COTURN_HOST}" 3478 2>/dev/null; then
    info "  STUN/TURN 3478 (${COTURN_HOST}): ${GN}reachable${CL}"
else
    error "  STUN/TURN 3478 (${COTURN_HOST}): ${RD}unreachable${CL}"
    (( FAILURES++ )) || true
fi

if grep -q '^COTURN_SECRET=.' /home/tappaas/secrets/coturn.env 2>/dev/null; then
    info "  TURN secret published to the management plane: ${GN}yes${CL}"
else
    error "  TURN secret not in /home/tappaas/secrets/coturn.env — ${CONSUMER} cannot align its own (re-run: module-manager module update coturn)"
    (( FAILURES++ )) || true
fi

if (( FAILURES == 0 )); then
    info "${GN}coturn:turn test-service passed for ${CONSUMER}${CL}"
    exit 0
fi
error "coturn:turn test-service: ${FAILURES} check(s) failed for ${CONSUMER}"
exit 1
