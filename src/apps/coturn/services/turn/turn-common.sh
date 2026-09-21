#!/usr/bin/env bash
#
# TAPPaaS coturn TURN Service — shared routines for install/update-service.sh
#
# Sourced, not executed. Expects common-install-routines.sh to be loaded.
#

# coturn_turn_host <coturn-config.json>
#
# The ONE name clients use for TURN, in every horizon: coturn's `publicDomain`
# when declared (split-horizon DNS resolves it to the coturn VM inside the
# site; the public A record to the WAN IP outside), else the internal FQDN —
# which only in-network clients can resolve, so external Talk media fails.
# Always with the TURN port, so consumers paste it as-is.
coturn_turn_host() {
    local cfg="$1" pub vmname zone
    pub="$(jq -r '.publicDomain // empty' "${cfg}" 2>/dev/null || true)"
    if [[ -n "${pub}" ]]; then
        printf '%s:3478\n' "${pub}"
        return 0
    fi
    vmname="$(jq -r '.vmname // "coturn"' "${cfg}" 2>/dev/null || echo coturn)"
    zone="$(jq -r '.zone0 // "dmz"' "${cfg}" 2>/dev/null || echo dmz)"
    printf '%s.%s.internal:3478\n' "${vmname}" "${zone}"
}

# coturn_stamp_turn_host <consumer-config.json> <turnHost>
#
# Write the fact into the CONSUMER's deployed config (top-level, Pattern A) so
# the consumer's .nix reads it from the companion JSON update-os.sh ships to
# /etc/nixos. Idempotent; a no-op when the value already matches. The consumer
# does not author this field (declared in services/turn/fields.json).
coturn_stamp_turn_host() {
    local cfg="$1" host="$2" tmp current
    [[ -f "${cfg}" ]] || return 0
    current="$(jq -r '.turnHost // empty' "${cfg}" 2>/dev/null || true)"
    [[ "${current}" == "${host}" ]] && return 0
    tmp="$(mktemp "${cfg}.XXXXXX")"
    if jq --arg h "${host}" '.turnHost = $h' "${cfg}" > "${tmp}"; then
        mv "${tmp}" "${cfg}"
        info "  ${GN}✓${CL} turnHost=${host} recorded in $(basename "${cfg}")"
    else
        rm -f "${tmp}"
        warn "  could not record turnHost in ${cfg}"
    fi
}
