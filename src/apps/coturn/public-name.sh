#!/usr/bin/env bash
#
# TAPPaaS Module: coturn — the one TURN name, in every horizon (publicDomain)
#
# Sourced by install.sh and update.sh. Expects common-install-routines.sh and a
# loaded module config ($JSON).
#
# Every client must resolve the same TURN host: a 5G phone cannot resolve
# coturn.dmz.internal, and an internal client sent to the WAN IP hairpins into a
# NAT that does not reflect. Hence one publicDomain plus a split-horizon record
# answering with coturn's OWN address (not the Caddy gateway — TURN is not HTTP).
#
#   coturn_converge_public_name <effective-module-name> <coturn-internal-fqdn>
#
# Sets COTURN_PUBLIC ("" when no site domain is known). Idempotent.
coturn_converge_public_name() {
    local module="$1" coturn_host="$2"
    local cfg="/home/tappaas/config/${module}.json"
    local site_domain tmp coturn_ip

    COTURN_PUBLIC="$(get_config_value publicDomain '')"
    if [[ -z "${COTURN_PUBLIC}" ]]; then
        site_domain="$(jq -r '.domain // empty' <<<"$(get_variant_config "$(get_config_value environment '')" 2>/dev/null || echo '{}')")"
        [[ -z "${site_domain}" && -f /home/tappaas/config/configuration.json ]] && \
            site_domain="$(jq -r '.tappaas.domain // empty' /home/tappaas/config/configuration.json 2>/dev/null || true)"
        if [[ -n "${site_domain}" ]]; then
            COTURN_PUBLIC="turn.${site_domain}"
            # Persist it so every reader sees the same name.
            if [[ -f "${cfg}" ]]; then
                tmp="$(mktemp "${cfg}.XXXXXX")"
                if jq --arg d "${COTURN_PUBLIC}" '.publicDomain = $d' "${cfg}" > "${tmp}"; then
                    mv "${tmp}" "${cfg}"
                else
                    rm -f "${tmp}"
                fi
            fi
            info "  publicDomain defaulted to ${COTURN_PUBLIC}"
        fi
    fi

    if [[ -z "${COTURN_PUBLIC}" ]]; then
        warn "  No site domain known — set 'publicDomain' on this module and create its public A record,"
        warn "  or external Talk clients get a TURN host (${coturn_host}) they cannot resolve."
        return 0
    fi

    coturn_ip="$(getent hosts "${coturn_host}" | awk '{print $1; exit}' || true)"
    if [[ -z "${coturn_ip}" ]]; then
        warn "  could not resolve ${coturn_host} — split-horizon record for ${COTURN_PUBLIC} not registered"
        return 0
    fi
    if ! command -v unbound-manager >/dev/null 2>&1; then
        warn "  unbound-manager not on PATH — register manually: ${COTURN_PUBLIC} -> ${coturn_ip}"
        return 0
    fi
    # A per-host override only helps where no wildcard covers the domain; under a
    # wildcard Unbound refuses it outright (#649), and it is not needed: internal
    # clients are given the internal TURN endpoint alongside the public one.
    if unbound-manager --no-ssl-verify add "${COTURN_PUBLIC%%.*}" "${COTURN_PUBLIC#*.}" "${coturn_ip}" \
            --description "TAPPaaS: ${module} TURN split-horizon" >/dev/null 2>&1; then
        info "  split-horizon DNS: ${COTURN_PUBLIC} -> ${coturn_ip} (Unbound)"
    else
        info "  no split-horizon record for ${COTURN_PUBLIC} (a wildcard covers the domain) — internal clients use the internal TURN endpoint"
    fi
}
