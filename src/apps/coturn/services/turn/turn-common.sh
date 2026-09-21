#!/usr/bin/env bash
#
# TAPPaaS coturn TURN Service — shared routines for install/update-service.sh
#
# Sourced, not executed. Expects common-install-routines.sh to be loaded.
#

# A site's wildcard split-horizon answers every public name with the reverse
# proxy, which runs no TURN, so one name cannot serve both sides. Consumers get
# both endpoints and let ICE pick: the public one works from outside, the
# internal one from any zone with a pinhole.

# coturn_turn_host <coturn-config.json> — the name EXTERNAL clients use.
coturn_turn_host() {
    local cfg="$1" pub
    pub="$(jq -r '.publicDomain // empty' "${cfg}" 2>/dev/null || true)"
    if [[ -n "${pub}" ]]; then
        printf '%s:3478\n' "${pub}"
        return 0
    fi
    coturn_turn_host_internal "${cfg}"
}

# coturn_turn_host_internal <coturn-config.json> — the name INTERNAL clients and
# server-side consumers (Janus) use.
coturn_turn_host_internal() {
    local cfg="$1" vmname zone
    vmname="$(jq -r '.vmname // "coturn"' "${cfg}" 2>/dev/null || echo coturn)"
    zone="$(jq -r '.zone0 // "dmz"' "${cfg}" 2>/dev/null || echo dmz)"
    printf '%s.%s.internal:3478\n' "${vmname}" "${zone}"
}

# coturn_stamp_turn_host <consumer-config.json> <turnHost>
#
# Record the fact in the consumer's deployed config so its .nix can read it from
# the companion JSON. Idempotent; the consumer never authors this field.
coturn_stamp_turn_host() {
    local cfg="$1" host="$2" internal="$3" tmp
    [[ -f "${cfg}" ]] || return 0
    if [[ "$(jq -r '.turnHost // empty' "${cfg}")" == "${host}" \
       && "$(jq -r '.turnHostInternal // empty' "${cfg}")" == "${internal}" ]]; then
        return 0
    fi
    tmp="$(mktemp "${cfg}.XXXXXX")"
    if jq --arg h "${host}" --arg i "${internal}" '.turnHost = $h | .turnHostInternal = $i' "${cfg}" > "${tmp}"; then
        mv "${tmp}" "${cfg}"
        info "  ${GN}✓${CL} turnHost=${host} (internal ${internal}) recorded in $(basename "${cfg}")"
    else
        rm -f "${tmp}"
        warn "  could not record turnHost in ${cfg}"
    fi
}
