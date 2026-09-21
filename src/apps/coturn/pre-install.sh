#!/usr/bin/env bash
# TAPPaaS Module: coturn — Pre-installation
#
# Generates module secrets before dependency service installers run.
# Called automatically by install-module.sh before Step 4.

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh

SECRETS_FILE="/home/tappaas/secrets/coturn.env"
if [[ ! -f "${SECRETS_FILE}" ]]; then
    info "Creating ${SECRETS_FILE}..."
    touch "${SECRETS_FILE}"
    chmod 600 "${SECRETS_FILE}"
    info "  ${GN}✓${CL} ${SECRETS_FILE} created"
else
    info "  ${GN}✓${CL} ${SECRETS_FILE} already exists — skipping"
fi

# Settle the public TURN name here, before any dependency service or connector
# reads it: Nextcloud's `talk` connector and coturn:turn both advertise it, and
# they run before the module's own converge.
MODULE="${1:-coturn}"
CFG="/home/tappaas/config/${MODULE}.json"
if [[ -f "${CFG}" && -z "$(jq -r '.publicDomain // empty' "${CFG}" 2>/dev/null)" ]]; then
    _env="$(jq -r '.environment // empty' "${CFG}" 2>/dev/null || true)"
    _dom="$(jq -r '.domain // empty' <<<"$(get_variant_config "${_env}" 2>/dev/null || echo '{}')")"
    [[ -z "${_dom}" && -f /home/tappaas/config/configuration.json ]] && \
        _dom="$(jq -r '.tappaas.domain // empty' /home/tappaas/config/configuration.json 2>/dev/null || true)"
    if [[ -n "${_dom}" ]]; then
        _tmp="$(mktemp "${CFG}.XXXXXX")"
        if jq --arg d "turn.${_dom}" '.publicDomain = $d' "${CFG}" > "${_tmp}"; then
            mv "${_tmp}" "${CFG}"
            info "  ${GN}✓${CL} publicDomain → turn.${_dom}"
        else
            rm -f "${_tmp}"
        fi
    fi
fi
