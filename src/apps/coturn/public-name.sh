#!/usr/bin/env bash
#
# TAPPaaS Module: coturn — the one TURN name, in every horizon (publicDomain)
#
# Sourced by install.sh and update.sh (never executed). Expects
# common-install-routines.sh to be loaded and the module config to be loaded
# ($JSON, i.e. get_config_value works).
#
# Clients must be handed a TURN host they can ALL resolve: a 5G phone cannot
# resolve coturn.dmz.internal, and an office laptop that resolves the public
# name to the WAN IP hairpins into a NAT that does not reflect. So coturn gets
# ONE public name — `publicDomain`, defaulting to turn.<site domain> — with a
# split-horizon record inside the site that answers with coturn's OWN DMZ
# address (NOT the Caddy gateway network:proxy uses: TURN is not HTTP).
# Consumers advertise this name: Nextcloud Talk through the `talk` connector,
# the HPB and its Janus through coturn:turn's stamped `turnHost`.
#
#   coturn_converge_public_name <effective-module-name> <coturn-internal-fqdn>
#
# Sets COTURN_PUBLIC (the name, or "" when no site domain is known). Idempotent:
# persists the default into the deployed config once, re-asserts the resolver
# record on every run (a record that was pruned or never written comes back on
# the next converge).
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
            # Persist the default so every reader (consumers, tests, the next
            # update) sees the SAME name; a site that wants another sets
            # publicDomain itself (declared in module-fields.json).
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

    # Split-horizon: inside the site the public name answers with coturn's OWN
    # address (media goes to the relay, not to a proxy). A plain host override
    # on the site resolver, owned by this module — the same writer network:proxy
    # uses for its per-service records (#577: one writer per record).
    coturn_ip="$(getent hosts "${coturn_host}" | awk '{print $1; exit}' || true)"
    if [[ -z "${coturn_ip}" ]]; then
        warn "  could not resolve ${coturn_host} — split-horizon record for ${COTURN_PUBLIC} not registered"
        return 0
    fi
    if ! command -v unbound-manager >/dev/null 2>&1; then
        warn "  unbound-manager not on PATH — register manually: ${COTURN_PUBLIC} -> ${coturn_ip}"
        return 0
    fi
    if unbound-manager --no-ssl-verify add "${COTURN_PUBLIC%%.*}" "${COTURN_PUBLIC#*.}" "${coturn_ip}" \
            --description "TAPPaaS: ${module} TURN split-horizon" >/dev/null 2>&1; then
        info "  split-horizon DNS: ${COTURN_PUBLIC} -> ${coturn_ip} (Unbound)"
    else
        warn "  could not register ${COTURN_PUBLIC} -> ${coturn_ip} in Unbound — internal clients will hairpin via the WAN IP; add it manually:"
        warn "    unbound-manager --no-ssl-verify add '${COTURN_PUBLIC%%.*}' '${COTURN_PUBLIC#*.}' '${coturn_ip}'"
    fi
}
