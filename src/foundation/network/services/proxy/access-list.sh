#!/usr/bin/env bash
#
# TAPPaaS network:proxy — shared access-list helper (issue #206)
#
# Sourced by install-service.sh and update-service.sh. Resolves a module's
# `proxyAllowedZones` to an os-caddy access list that restricts which client
# networks may reach the proxied service, and (de)provisions it via
# caddy-manager. The caller attaches the result to its handler with
#   caddy-manager add-handler ... --access-list "<name>"
#
# proxyAllowedZones semantics:
#   - absent  → internal default: every Active "Service" zone plus home, work,
#               mgmt and the netbird overlay (NOT the internet) — zero-trust-by-
#               default. netbird (#367) admits WireGuard tunnel peers, which reach
#               Caddy with their own overlay source IP.
#   - a list  → exactly those zones. Include the literal "internet" to publish
#               the service publicly (no restriction); include "netbird" to keep
#               tunnel access on a service that otherwise narrows its zones.
#
# Expects the caller to provide info()/warn()/error() and have caddy-manager in
# PATH. All progress output goes to stderr so stdout carries only the resolved
# access-list name (empty = unrestricted/public).

# run_caddy <caddy-manager args...> — run caddy-manager with its (noisy) stdout
# routed to [Debug] (shown only when TAPPAAS_DEBUG=1). On failure the captured
# output is surfaced on stderr so real errors stay visible. Returns caddy's rc.
run_caddy() {
    local _out _rc _cl
    # Capture without tripping `set -e` on a non-zero caddy exit (bare
    # `x=$(cmd)` would abort before we can inspect $?).
    _out="$(caddy-manager "$@" 2>&1)" && _rc=0 || _rc=$?
    if [[ ${_rc} -ne 0 ]]; then
        if [[ -n "${_out}" ]]; then printf '%s\n' "${_out}" >&2; fi
        return "${_rc}"
    fi
    if [[ -n "${_out}" ]]; then
        # >&2 is LOAD-BEARING: this file's callers command-substitute the
        # resolved access-list name from stdout, and debug() prints to stdout —
        # without the redirect, TAPPAAS_DEBUG=1 leaks these lines INTO the
        # captured name, and the handler creation then fails with
        # "Access list '<multiline garbage>' not found" (broke the logging
        # module's proxy on the ADR-007 virgin-install test).
        while IFS= read -r _cl; do debug "  ${_cl}"; done <<<"${_out}" >&2
    fi
    return 0
}

# proxy_resolve_access_list <module> <module_json> <zones_file> <description>
# Echoes the access-list name to attach (empty string when public). Returns
# non-zero on a hard error (caller should die).
proxy_resolve_access_list() {
    local module="$1" module_json="$2" zones_file="$3" description="$4"
    local al_name="tappaas-${module}"
    local -a zones=()

    # Normalize to flat form so this works whether module_json is flat or Pattern A (#207).
    mapfile -t zones < <(normalize_module_config < "${module_json}" 2>/dev/null | jq -r '.proxyAllowedZones // [] | .[]' 2>/dev/null)

    if [[ ${#zones[@]} -eq 0 ]]; then
        if [[ -f "${zones_file}" ]]; then
            # mgmt and netbird are always included (both state=Manual, not Active):
            # mgmt is the control plane; netbird is the WireGuard admin overlay whose
            # peers terminate on OPNsense with their own 100.70.x.x source (issue #367)
            # — without it tunnel peers are 403'd by Caddy. Plus every Active Service
            # zone and the home/work client zones.
            mapfile -t zones < <(jq -r '
                to_entries[]
                | select(
                    .key == "mgmt"
                    or .key == "netbird"
                    or (.value.state == "Active"
                        and (.value.type == "Service" or .key == "home" or .key == "work"))
                  )
                | .key' "${zones_file}" 2>/dev/null)
        fi
        debug "  Access: ${BL}default internal zones${CL} (${zones[*]:-none})" >&2
    else
        debug "  Access: ${BL}${zones[*]}${CL}" >&2
    fi

    # Internet exposure → no restriction; drop any prior allow-list.
    local z
    for z in "${zones[@]}"; do
        if [[ "${z}" == "internet" ]]; then
            debug "  '${module}' is exposed to the ${BL}internet${CL} — no access restriction" >&2
            caddy-manager delete-accesslist "${al_name}" --no-ssl-verify >/dev/null 2>&1 || true
            printf ''
            return 0
        fi
    done

    # Resolve zone names → CIDRs from zones.json.
    #
    # An UNRESOLVABLE ENTRY IS A HARD ERROR (issue #419). This used to warn and
    # continue, so a module with a stale zone name deployed "successfully" while
    # silently granting access to FEWER zones than it declared — e.g. hass with
    # proxyAllowedZones ["mgmt","home"] on a system where 'home' had been renamed
    # away installed clean and locked every private-zone client out of Home
    # Assistant. A reduced allow-list is a security-relevant divergence from the
    # declared intent, and the operator must be told, not left to discover it.
    local cidrs="" cidr
    local -a unresolved=()
    for z in "${zones[@]}"; do
        cidr=$(jq -r --arg z "${z}" '.[$z].ip // empty' "${zones_file}" 2>/dev/null)
        if [[ -z "${cidr}" ]]; then
            unresolved+=("${z}")
            continue
        fi
        cidrs="${cidrs:+${cidrs},}${cidr}"
    done

    if [[ ${#unresolved[@]} -gt 0 ]]; then
        error "proxyAllowedZones for '${module}' names ${#unresolved[@]} zone(s) that do not resolve in ${zones_file}: ${unresolved[*]}" >&2
        error "  A partial allow-list would silently grant access to fewer zones than declared, so this is refused." >&2
        error "  Fix the module's proxyAllowedZones, or check the zone name against:" >&2
        error "    network-manager list" >&2
        return 1
    fi

    if [[ -z "${cidrs}" ]]; then
        error "proxyAllowedZones for '${module}' resolved to no networks — refusing to create an empty allow-list (it would block everything)" >&2
        return 1
    fi

    debug "  Access list ${BL}${al_name}${CL}: allow only ${BL}${cidrs}${CL}" >&2

    # Guard 1: caddy-manager binary must be present — if it's missing entirely
    # that is a hard error (the whole proxy service is broken, not just access lists).
    if ! command -v caddy-manager >/dev/null 2>&1; then
        error "  caddy-manager not found in PATH — cannot create access list" >&2
        return 1
    fi

    # Guard 2: add-accesslist is only available in caddy-manager >= 2.x.
    # If the subcommand is absent, degrade gracefully: warn and skip the
    # restriction rather than aborting the entire proxy install.
    local al_help
    if ! al_help="$(caddy-manager add-accesslist --help 2>/dev/null)"; then
        warn "  caddy-manager does not support 'add-accesslist' — zone restriction skipped." >&2
        warn "  Update caddy-manager to enable per-domain IP allow-lists." >&2
        printf ''
        return 0
    fi

    # A 403 with no body is a blank page, and a blank page is indistinguishable
    # from the service being down — which is what every list on every estate
    # served until now (#696). The text deliberately does NOT name the allowed
    # zones: this body is served to whoever was refused, and the zone names are
    # internal topology. An operator who wants the specifics sets
    # TAPPAAS_ACCESS_DENIED_MESSAGE, or passes --message by hand.
    #
    # Same graceful degrade as Guard 2, one release narrower: the binary is
    # rebuilt from this repo, but a converge can run against a manager from
    # before the flag existed, and an unrecognised argument would fail the whole
    # proxy install for the sake of a sentence.
    local -a msg_arg=()
    if [[ "${al_help}" == *--message* ]]; then
        # No apostrophe in the default: inside "${var:-word}" bash takes it as
        # an opening quote and swallows the rest of the file.
        msg_arg=(--message "${TAPPAAS_ACCESS_DENIED_MESSAGE:-Access to this service is limited to approved networks. Connect from an allowed network, or over the site VPN, and try again.}")
    else
        warn "  caddy-manager has no --message — blocked clients will get an empty 403 body." >&2
    fi

    if ! run_caddy add-accesslist "${al_name}" \
            --clients "${cidrs}" \
            --matcher remote_ip \
            --response-code 403 \
            "${msg_arg[@]}" \
            --description "${description} (allowed zones)" \
            --no-ssl-verify; then
        error "Failed to create/update Caddy access list ${al_name}" >&2
        return 1
    fi

    printf '%s' "${al_name}"
}

# proxy_split_horizon_target <domain> [zones_file]
#
# Echo the split-horizon DNS target for a published name. This is a THIN
# WRAPPER — the rule lives in one place, `network-manager split-horizon-target`
# (ADR-021 D5), and every writer calls it rather than re-deriving the address.
#
# It used to derive the address here, from the module's primary authorized
# CLIENT zone (#504, ADR-005 §6), while acme-setup.sh and environment-manager
# each derived it from a SERVICE zone. Three transcriptions of one rule, and on
# a live site they disagreed (#577). ADR-021 D2 replaced the rule itself: the
# answer is the DMZ gateway, for every caller, always — reachability is the
# firewall's caddy-reach rule (D3) and authorization is Caddy's ACL plus the
# identity gate, neither of which belongs in a DNS answer.
#
# stdout carries only the IP. Exit code is the interface, and callers MUST tell
# the two failures apart (ADR-021 R3):
#   0  published    → stdout is the address to register
#   3  unpublished  → no public DNS for this name: no cert, nothing to serve.
#                     A supported configuration, NOT an error.
#   1  error        → the site cannot express an answer (e.g. no dmz zone).
proxy_split_horizon_target() {
    local domain="$1" zones_file="${2:-}"
    local -a args=(split-horizon-target "${domain}")
    [[ -n "${zones_file}" ]] && args+=(--zones "${zones_file}")

    # stdout is the address; network-manager writes its diagnostics to stderr.
    # For 0 and 3 they are detail — the caller reports the outcome in its own
    # words — so they go to [Debug]; an error's diagnostics pass through as-is.
    # Captured without tripping `set -e` on the exits that are the contract.
    local out rc=0 err
    err="$(mktemp)"
    out="$(network-manager "${args[@]}" 2>"${err}")" || rc=$?
    if [[ ${rc} -eq 0 || ${rc} -eq 3 ]]; then
        # >&2: this function's stdout is the address its callers capture.
        while IFS= read -r _l; do debug "  ${_l}" >&2; done < "${err}"
    else
        cat "${err}" >&2
    fi
    rm -f "${err}"
    [[ ${rc} -eq 0 ]] && printf '%s' "${out}"
    return ${rc}
}

# proxy_unbound_add <host> <domain> <ip> <description>
#
# Register a split-horizon host override. unbound-manager narrates every call
# ("Already up to date: …"); on success that is detail, so it goes to [Debug],
# and on failure it is printed as-is for the caller's warning to point at.
proxy_unbound_add() {
    local out rc=0
    out="$(unbound-manager --no-ssl-verify add "$1" "$2" "$3" --description "$4" 2>&1)" || rc=$?
    if [[ ${rc} -eq 0 ]]; then
        [[ -n "${out}" ]] && while IFS= read -r _l; do debug "    ${_l}"; done <<< "${out}"
    else
        printf '%s\n' "${out}" >&2
    fi
    return ${rc}
}

# proxy_add_routes <description> <domain> <upstream> <dns_mode>
#
# Publish the module's additional proxyRoutes (#597). Each {name, port} entry in
# the module config becomes a route <name>.<domain> → <upstream>:<port> with its
# own description "<description>#<name>" (the primary keeps the bare
# "<description>"). Handlers are keyed by description, so a distinct one per route
# is what stops route N from overwriting route 1's handler.
#
# Routes inherit the module's access list (ACL_ARGS) and TLS/domain settings
# (CADDY_DOMAIN_ARGS) from the caller, and the proxyUpstream* upstream flags from
# the module config. Under per-service TLS each route FQDN also gets a
# split-horizon Unbound override, with the same wildcard-redirect-zone collision
# guard as the primary (#474/#504). Finally any previously-published route no
# longer declared is swept (prefix prune) — an empty proxyRoutes removes them all.
#
# Reads the module config from $JSON. Uses caller globals: MODULE, MODULE_JSON,
# ZONES_FILE, ACL_ARGS, CADDY_DOMAIN_ARGS.
proxy_add_routes() {
    local description="$1" domain="$2" upstream="$3" dns_mode="$4"

    # Upstream flags, re-derived from the module config so a route gets them even
    # in code paths (update) that do not build them for the primary handler.
    local -a tls_args=() http1_args=() preserve_args=()
    [[ "$(get_config_value 'proxyUpstreamTls' 'false')" == "true" ]] && tls_args=(--upstream-tls)
    [[ "$(get_config_value 'proxyUpstreamHttp1' 'false')" == "true" ]] && http1_args=(--upstream-http1)
    [[ "$(get_config_value 'proxyPreserveHost' 'false')" == "true" ]] && preserve_args=(--preserve-host)

    # The split-horizon gateway is the same for every route (same module/zones);
    # resolved once, on the first route that needs it — a module without
    # proxyRoutes never asks. An unpublished domain (rc 3) leaves gw empty and
    # the per-route override below is skipped, as for the primary handler.
    local gw="" gw_looked=0

    local -a keep_fqdns=()
    local name port fqdn route_desc wc
    while IFS=$'\t' read -r name port; do
        [[ -z "${name}" ]] && continue
        # A malformed entry is a config error — fail loudly rather than push
        # broken config to Caddy.
        if [[ ! "${name}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
            die "Invalid proxyRoutes name '${name}' (must be a DNS label)"
        fi
        if [[ ! "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            die "Invalid proxyRoutes port '${port}' for '${name}' (must be 1-65535)"
        fi
        fqdn="${name}.${domain}"
        route_desc="${description}#${name}"
        keep_fqdns+=(--keep "${fqdn}")
        debug "  Additional route: ${BL}${fqdn}${CL} -> ${BL}${upstream}:${port}${CL} (${route_desc})"

        if [[ "${dns_mode}" == "per-service" ]]; then
            if wc="$(unbound_wildcard_covers "${name}" "${domain}")"; then
                debug "    wildcard *.${wc} already covers ${fqdn} — skipping per-service override"
            else
                if (( ! gw_looked )); then
                    gw="$(proxy_split_horizon_target "${domain}" "${ZONES_FILE}" || true)"
                    gw_looked=1
                fi
                if [[ -n "${gw}" ]]; then
                    proxy_unbound_add "${name}" "${domain}" "${gw}" "${route_desc}" \
                        || warn "    Could not register ${fqdn} in Unbound (register manually)"
                else
                    warn "    No split-horizon gateway for ${fqdn} — register DNS manually"
                fi
            fi
        fi

        run_caddy add-domain "${fqdn}" \
            --description "${route_desc}" \
            "${CADDY_DOMAIN_ARGS[@]+"${CADDY_DOMAIN_ARGS[@]}"}" \
            --no-ssl-verify || die "Failed to create Caddy domain ${fqdn}"

        run_caddy add-handler "${fqdn}" \
            --upstream "${upstream}" \
            --port "${port}" \
            --description "${route_desc}" \
            "${ACL_ARGS[@]+"${ACL_ARGS[@]}"}" \
            "${tls_args[@]+"${tls_args[@]}"}" \
            "${http1_args[@]+"${http1_args[@]}"}" \
            "${preserve_args[@]+"${preserve_args[@]}"}" \
            --no-ssl-verify || die "Failed to create Caddy handler ${fqdn}"
    done < <(echo "${JSON}" | jq -rc '.proxyRoutes // [] | .[] | [.name, (.port|tostring)] | @tsv')

    # Sweep any route this module previously published but no longer declares.
    # Empty keep list (no proxyRoutes) removes every "<description>#*" route.
    debug "  Pruning undeclared routes for ${MODULE} (prefix '${description}#')..."
    run_caddy prune-domains --description-prefix "${description}#" \
        "${keep_fqdns[@]+"${keep_fqdns[@]}"}" \
        --no-ssl-verify || warn "Could not prune undeclared routes for ${MODULE} (non-fatal)"
}
