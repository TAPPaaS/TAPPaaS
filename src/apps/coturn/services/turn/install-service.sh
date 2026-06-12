#!/usr/bin/env bash
#
# TAPPaaS coturn TURN Service - Install
#
# Verifies the coturn STUN/TURN server is reachable on port 3478
# before dependent modules (nextcloud-hpb) install.
#
# Usage: install-service.sh <module-name>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
readonly CONFIG_DIR="/home/tappaas/config"
readonly CONSUMER_JSON="${CONFIG_DIR}/${MODULE}.json"

# Resolve coturn's own config variant-awarely. A consumer deployed as a variant
# (e.g. nextcloud-hpb-test) pairs with the SAME-variant provider (coturn-test);
# there may be no base coturn.json at all. Fall back to the base for production.
VARIANT=""
[[ -n "${MODULE}" && -f "${CONSUMER_JSON}" ]] && \
    VARIANT=$(jq -r '.variant // empty' "${CONSUMER_JSON}" 2>/dev/null || true)
if [[ -n "${VARIANT}" && -f "${CONFIG_DIR}/coturn-${VARIANT}.json" ]]; then
    readonly COTURN_JSON="${CONFIG_DIR}/coturn-${VARIANT}.json"
else
    readonly COTURN_JSON="${CONFIG_DIR}/coturn.json"
fi

VMNAME=$(jq -r '.vmname' "${COTURN_JSON}")
ZONE=$(jq -r '.zone0' "${COTURN_JSON}")

info "coturn:turn install-service — verifying coturn STUN/TURN is reachable for module: ${MODULE}"

if nc -z -w5 "${VMNAME}.${ZONE}.internal" 3478 2>/dev/null; then
    info "${GN}✓${CL} coturn STUN/TURN is reachable at ${VMNAME}.${ZONE}.internal:3478"
else
    die "coturn is not responding on port 3478 — ensure the coturn module is fully installed"
fi

# ── Publish coturn's shared TURN secret to the management plane ───────────────
# coturn is the source of truth for the TURN secret (NixOS-generated on the coturn
# VM). The consumer (e.g. nextcloud-hpb) reads COTURN_SECRET from here and aligns
# its own turn-secret to it. Provider-wires-consumer (ADR-COM-0002 pattern): coturn
# does NOT push into the consumer's VM — the consumer pulls and configures itself.
readonly COTURN_HOST="${VMNAME}.${ZONE}.internal"
readonly MGMT_SECRETS="/home/tappaas/secrets/coturn.env"
COTURN_SECRET=$(ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no \
    "tappaas@${COTURN_HOST}" \
    "sudo grep '^COTURN_SECRET=' /etc/secrets/coturn.env 2>/dev/null | cut -d= -f2-" || true)
if [[ -n "${COTURN_SECRET}" ]]; then
    mkdir -p "$(dirname "${MGMT_SECRETS}")"
    { grep -v '^COTURN_SECRET=' "${MGMT_SECRETS}" 2>/dev/null || true; printf 'COTURN_SECRET=%s\n' "${COTURN_SECRET}"; } > "${MGMT_SECRETS}.tmp"
    mv "${MGMT_SECRETS}.tmp" "${MGMT_SECRETS}"
    info "${GN}✓${CL} COTURN_SECRET published to management plane for ${MODULE}"
else
    warn "Could not read COTURN_SECRET from ${COTURN_HOST} — ${MODULE} may fail to align its TURN secret"
fi
