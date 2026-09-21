#!/usr/bin/env bash
# TAPPaaS Module: nextcloud-hpb — Pre-installation
#
# Place the HPB in the same zone as the Nextcloud it serves, unless the operator
# named one. Co-location means the signaling server reaches Nextcloud over the
# zone's existing edge to the reverse proxy with no extra egress, and it keeps
# the HPB out of a default zone that may not carry guests on its node.
#
# Runs before zone0 is resolved, so the value written here is honoured as an
# explicit .zone0. Idempotent.

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-nextcloud-hpb}"
CFG="/home/tappaas/config/${MODULE}.json"
[[ -f "${CFG}" ]] || exit 0

if [[ -n "$(jq -r '.zone0 // empty' "${CFG}" 2>/dev/null)" ]]; then
    debug "  zone0 already set on ${MODULE} — leaving the operator's choice alone"
    exit 0
fi

ENVIRONMENT="$(jq -r '.environment // empty' "${CFG}" 2>/dev/null || true)"
NC_JSON="/home/tappaas/config/$(resolve_provider_module nextcloud "${ENVIRONMENT}").json"
NC_ZONE="$(jq -r '.zone0 // empty' "${NC_JSON}" 2>/dev/null || true)"

if [[ -z "${NC_ZONE}" ]]; then
    warn "  Could not read the Nextcloud provider's zone from ${NC_JSON} — falling back to the engine's default placement"
    exit 0
fi

_tmp="$(mktemp "${CFG}.XXXXXX")"
if jq --arg z "${NC_ZONE}" '.zone0 = $z' "${CFG}" > "${_tmp}"; then
    mv "${_tmp}" "${CFG}"
    info "  zone0 → ${NC_ZONE} (co-located with the Nextcloud it serves)"
else
    rm -f "${_tmp}"
    die "Could not write zone0 into ${CFG}"
fi
