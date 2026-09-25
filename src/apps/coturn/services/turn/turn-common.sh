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
    # Into this service's own config block, never also the header: a field set in
    # both fails the engine's validation as ambiguous.
    if [[ "$(jq -r '.config["coturn:turn"].turnHost // empty' "${cfg}")" == "${host}" \
       && "$(jq -r '.config["coturn:turn"].turnHostInternal // empty' "${cfg}")" == "${internal}" ]] \
       && ! jq -e 'has("turnHost") or has("turnHostInternal")' "${cfg}" >/dev/null; then
        return 0
    fi
    tmp="$(mktemp "${cfg}.XXXXXX")"
    if jq --arg h "${host}" --arg i "${internal}" \
        'del(.turnHost, .turnHostInternal) | .config["coturn:turn"].turnHost = $h | .config["coturn:turn"].turnHostInternal = $i' \
        "${cfg}" > "${tmp}"; then
        mv "${tmp}" "${cfg}"
        info "  ${GN}✓${CL} turnHost=${host} (internal ${internal}) recorded in $(basename "${cfg}")"
    else
        rm -f "${tmp}"
        warn "  could not record turnHost in ${cfg}"
    fi
}

# coturn_allow_peer <coturn-config.json> <consumer-config.json>
#
# coturn denies relaying to private addresses, which includes the consumer's own
# media server (the HPB's Janus). Record the consumer's IP on the coturn VM so
# coturn.nix emits an allowed-peer-ip for exactly that host, and restart coturn
# only when the entry changed. Warns rather than fails: calls still work for
# clients that reach the media server directly.
coturn_allow_peer() {
    local coturn_cfg="$1" cfg="$2" module host ip turn
    [[ -f "${cfg}" ]] || return 0
    module="$(basename "${cfg}" .json)"
    host="$(jq -r '.vmname' "${cfg}").$(jq -r '.zone0' "${cfg}").internal"
    ip="$(getent hosts "${host}" | awk '{print $1; exit}')"
    turn="$(jq -r '.vmname' "${coturn_cfg}").$(jq -r '.zone0' "${coturn_cfg}").internal"
    if [[ ! "${ip}" =~ ^[0-9.]+$ ]]; then
        warn "  cannot resolve ${host} — coturn will not relay to ${module}'s media server"
        return 0
    fi
    # shellcheck disable=SC2029  # module and ip are expanded here on purpose
    if ssh -o BatchMode=yes -o ConnectTimeout=10 "tappaas@${turn}" "
        f=/var/lib/coturn/allowed-peers
        new=\$( { sudo grep -v '^${module} ' \$f 2>/dev/null || true; echo '${module} ${ip}'; } | sort )
        if [ \"\$new\" != \"\$(sudo cat \$f 2>/dev/null)\" ]; then
            printf '%s\\n' \"\$new\" | sudo tee \$f >/dev/null && sudo systemctl restart coturn.service && echo changed
        fi" | grep -q changed; then
        info "  ${GN}✓${CL} coturn may relay to ${module} (${ip}); coturn restarted"
    else
        info "  ${GN}✓${CL} coturn already relays to ${module} (${ip})"
    fi
}

