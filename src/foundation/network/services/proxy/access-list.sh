#!/usr/bin/env bash
#
# TAPPaaS network:proxy — shared access-list helper (issue #206)
#
# Sourced by install-service.sh, update-service.sh and delete-service.sh. Resolves a module's
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

# proxy_prune_domains <caddy-manager prune-domains args...> — prune stale routes
# AND the per-service Unbound override of every name pruned. The one prune path
# for install, update and unpublish: update had none, so an old domain stayed in
# Caddy after a proxyDomain change, and the override kept the name resolving (#809).
#
# Only an override carrying the same description is removed: the old name may
# since have been taken by something else (coturn's "turn" is one), and its
# record must survive this module letting the name go.
proxy_prune_domains() {
    local _out _rc _fqdn _desc="" _prefix=0 _i
    local -a _args=("$@")
    for ((_i = 0; _i < ${#_args[@]}; _i++)); do
        case "${_args[_i]}" in
            --description) _desc="${_args[_i + 1]:-}" ;;
            --description-prefix) _desc="${_args[_i + 1]:-}"; _prefix=1 ;;
        esac
    done
    _out="$(caddy-manager prune-domains "$@" 2>&1)" && _rc=0 || _rc=$?
    if [[ ${_rc} -ne 0 ]]; then
        [[ -n "${_out}" ]] && printf '%s\n' "${_out}" >&2
        return "${_rc}"
    fi
    while IFS= read -r _fqdn; do
        [[ -n "${_fqdn}" ]] || continue
        info "  Retired stale reverse-proxy route ${_fqdn}" >&2
        proxy_unbound_prune_owned "${_fqdn%%.*}" "${_fqdn#*.}" "${_desc}" "${_prefix}" >&2
    done < <(sed -n 's/^Deleted stale domain: //p' <<<"${_out}")
    return 0
}

# proxy_unbound_prune_owned <host> <zone> <description> <prefix:0|1>
# Delete the Unbound override <host>.<zone> if its description is <description>
# (or starts with it, when prefix=1). `unbound-manager list` columns:
# HOST DOMAIN TYPE VALUE DESCRIPTION — the description may contain spaces.
proxy_unbound_prune_owned() {
    local host="$1" zone="$2" desc="$3" prefix="$4"
    [[ -z "${host}" || "${host}" == "*" || -z "${desc}" ]] && return 0
    if unbound-manager --no-ssl-verify list 2>/dev/null | awk -v h="${host}" -v z="${zone}" \
        -v d="${desc}" -v p="${prefix}" '
            $1 == h && $2 == z {
                s = $0
                for (i = 0; i < 4; i++) sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, "", s)
                sub(/[[:space:]]+$/, "", s)
                if (s == d || (p == 1 && index(s, d) == 1)) f = 1
            }
            END { exit !f }'; then
        debug "  Pruning per-service Unbound override ${host}.${zone}..."
        unbound-manager --no-ssl-verify delete "${host}" "${zone}" >/dev/null 2>&1 \
            || warn "  Could not prune Unbound override ${host}.${zone}"
    fi
}

# proxy_cidr_kind <entry> — "cidr" for a well-formed IPv4 or IPv6 network
# (a.b.c.d/n, n ≤ 32; or hex groups with ':' and /n, n ≤ 128), "bad" for an entry
# that tries to be one and is malformed, "" for anything else (a zone name).
# Pure; the caller decides what a "bad" means (a hard error, like #419).
proxy_cidr_kind() {
    local e="$1" a b c d n
    if [[ "${e}" == */* || "${e}" =~ ^[0-9.]+$ || "${e}" == *:* ]]; then
        if [[ "${e}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]]; then
            a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]} c=${BASH_REMATCH[3]} d=${BASH_REMATCH[4]} n=${BASH_REMATCH[5]}
            (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 && 10#$n <= 32 )) && { echo cidr; return; }
        elif [[ "${e}" =~ ^[0-9a-fA-F:]+/([0-9]{1,3})$ && "${e}" == *:* ]]; then
            n=${BASH_REMATCH[1]}
            (( 10#$n <= 128 )) && [[ "${e}" != *:::* ]] && { echo cidr; return; }
        fi
        echo bad
        return
    fi
    echo ""
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

    proxy_zone_access_list "${module}" "${al_name}" "${zones_file}" "${description}" "${zones[@]}"
}

# proxy_zone_access_list <module> <list-name> <zones_file> <description> <zone|network>...
# The access list for one route: `internet` → no restriction (the list is
# deleted, '' echoed); otherwise every zone's network and every named network in
# one remote_ip list called <list-name>, whose name is echoed. Returns non-zero on
# a hard error (an unknown zone, a malformed network, an empty result).
proxy_zone_access_list() {
    local module="$1" al_name="$2" zones_file="$3" description="$4"
    shift 4
    local -a zones=("$@")

    # `none` (ADR-023 D3): no one, except through the route's path rules. One
    # shared inverted list for every such route; never deleted per module.
    local z
    for z in "${zones[@]}"; do
        [[ "${z}" == "none" ]] || continue
        if [[ ${#zones[@]} -ne 1 ]]; then
            error "proxyAllowedZones for '${module}': 'none' means no one — it cannot be combined with ${zones[*]}" >&2
            return 1
        fi
        run_caddy add-accesslist tappaas-none --clients "0.0.0.0/0,::/0" --invert \
            --matcher remote_ip --response-code 403 \
            --message "${TAPPAAS_ACCESS_DENIED_MESSAGE:-This address only serves the paths it publishes.}" \
            --description "TAPPaaS: no one (routes that publish only some paths)" \
            --no-ssl-verify >/dev/null || { error "Failed to create the shared deny-all list tappaas-none" >&2; return 1; }
        printf '%s' tappaas-none
        return 0
    done

    # Internet exposure → no restriction; drop any prior allow-list.
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
    # An entry may also be a network itself (#656): a provider's published
    # caller range, for an endpoint one cloud service must reach. It goes into
    # the same remote_ip list as the zones' networks. A malformed one is refused
    # like an unknown zone — a typo must not widen or empty the list.
    local cidrs="" cidr
    local -a unresolved=() malformed=()
    for z in "${zones[@]}"; do
        case "$(proxy_cidr_kind "${z}")" in
            cidr) cidrs="${cidrs:+${cidrs},}${z}"; continue ;;
            bad)  malformed+=("${z}"); continue ;;
        esac
        cidr=$(jq -r --arg z "${z}" '.[$z].ip // empty' "${zones_file}" 2>/dev/null)
        if [[ -z "${cidr}" ]]; then
            unresolved+=("${z}")
            continue
        fi
        cidrs="${cidrs:+${cidrs},}${cidr}"
    done

    if [[ ${#malformed[@]} -gt 0 ]]; then
        error "proxyAllowedZones for '${module}' has ${#malformed[@]} malformed network(s): ${malformed[*]}" >&2
        error "  Write a network as a.b.c.d/n (IPv4) or x:y::/n (IPv6) — refused rather than guessed." >&2
        return 1
    fi

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
# A route may declare its own proxyAllowedZones (ADR-023 D2, #643): it then gets
# its own access list, tappaas-<module>#<route>. Without one it inherits the
# module's access list (ACL_ARGS), as before. Routes take TLS/domain settings
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

    local -a keep_fqdns=() keep_lists=() route_acl_args=() route_zones=()
    # Lists the routes' path rules keep (tappaas-<module>#<route>:<zones>): they
    # share the route lists' prefix, so the route-list prune below must keep them.
    PATH_RULE_LISTS=()
    local name port zones_json access_json fqdn route_desc wc route_acl
    # Fields joined by US (\x1f), not tab: bash merges consecutive tabs, so an
    # absent zones field (empty) would shift the rules into its place.
    while IFS=$'\x1f' read -r name port zones_json access_json; do
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

        # This route's own zones, or the module's list.
        route_acl_args=("${ACL_ARGS[@]+"${ACL_ARGS[@]}"}")
        if [[ -n "${zones_json}" ]]; then
            mapfile -t route_zones < <(jq -r '.[]' <<< "${zones_json}")
            [[ ${#route_zones[@]} -gt 0 ]] || die "proxyRoutes '${name}': proxyAllowedZones is empty — leave it out to inherit the module's, or name who may reach it"
            route_acl="$(proxy_zone_access_list "${MODULE}" "tappaas-${MODULE}#${name}" "${ZONES_FILE}" "${route_desc}" "${route_zones[@]}")" \
                || die "proxyRoutes '${name}': its proxyAllowedZones cannot be resolved (see above)"
            route_acl_args=()
            if [[ -n "${route_acl}" ]]; then
                route_acl_args=(--access-list "${route_acl}")
                # Only the module's own lists are pruned; tappaas-none is shared.
                [[ "${route_acl}" == "tappaas-${MODULE}#"* ]] && keep_lists+=(--keep "${route_acl}")
            fi
            # The #643 trap: a second name for the SAME port, more open than the
            # primary, publishes the whole app under that name.
            if [[ "${port}" == "${PROXY_PORT:-}" && ${#ACL_ARGS[@]} -gt 0 && -z "${route_acl}" ]]; then
                warn "  proxyRoutes '${name}' serves the primary port ${port} to the internet while the module itself is restricted — the whole app is public under ${fqdn}"
            fi
        fi
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
            "${route_acl_args[@]+"${route_acl_args[@]}"}" \
            "${tls_args[@]+"${tls_args[@]}"}" \
            "${http1_args[@]+"${http1_args[@]}"}" \
            "${preserve_args[@]+"${preserve_args[@]}"}" \
            --no-ssl-verify || die "Failed to create Caddy handler ${fqdn}"

        # This route's path rules (ADR-023), against its own zones or the module's.
        proxy_add_path_rules "${MODULE}" "${route_desc}" "${fqdn}" "${upstream}" "${port}" \
            "tappaas-${MODULE}#${name}" "${access_json:-[]}" "${zones_json:-$(jq -c '.proxyAllowedZones // null' <<< "${JSON}")}" \
            -- "${tls_args[@]+"${tls_args[@]}"}" "${http1_args[@]+"${http1_args[@]}"}" "${preserve_args[@]+"${preserve_args[@]}"}"
    done < <(echo "${JSON}" | jq -rc '.proxyRoutes // [] | .[]
        | [.name, (.port|tostring), (if .proxyAllowedZones == null then "" else (.proxyAllowedZones|tojson) end),
           ((.proxyAccess // [])|tojson)] | join("\u001f")')

    # Sweep any route this module previously published but no longer declares.
    # Empty keep list (no proxyRoutes) removes every "<description>#*" route.
    debug "  Pruning undeclared routes for ${MODULE} (prefix '${description}#')..."
    proxy_prune_domains --description-prefix "${description}#" \
        "${keep_fqdns[@]+"${keep_fqdns[@]}"}" \
        --no-ssl-verify || warn "Could not prune undeclared routes for ${MODULE} (non-fatal)"
    # …and the access lists of routes that no longer declare their own zones.
    # After the handlers above, so none still points at what is deleted.
    local l
    for l in "${PATH_RULE_LISTS[@]+"${PATH_RULE_LISTS[@]}"}"; do keep_lists+=(--keep "${l}"); done
    proxy_prune_route_lists "${MODULE}" "${keep_lists[@]+"${keep_lists[@]}"}"
}

# proxy_path_rules_check <rules-json> — validate a route's proxyAccess (ADR-023
# D2). Prints the problems, one per line; empty output means valid. Pure.
proxy_path_rules_check() {
    jq -r '
        if type != "array" then "proxyAccess must be a list of {paths, zones} rules"
        else
          (.[] | select(type != "object") | "a rule must be an object with paths and zones"),
          (.[] | select(type == "object") |
             (if ((.paths // []) | length) == 0 then "a rule has no paths" else empty end),
             (if ((.zones // []) | length) == 0 then "a rule has no zones — delete it instead" else empty end),
             (if ((.zones // []) | index("none")) != null then "none inside a rule admits no one — delete the rule instead" else empty end),
             (if .identityGate == false and (((.description // "") | tostring | gsub("^\\s+|\\s+$"; "")) | length) == 0
                then "a rule with identityGate false needs a description: who calls these paths and why they cannot sign in (ADR-032 D1)" else empty end),
             ((.paths // [])[] | tostring |
                if (startswith("/") | not) then "path \(.) must start with /"
                elif test("\\s") then "path \(.) contains whitespace"
                elif . == "/" or . == "/*" then "path \(.) is the whole route — set the route'"'"'s proxyAllowedZones instead"
                else empty end)),
          ([.[] | select(type == "object") | (.paths // [])[]] | group_by(.) | map(select(length > 1) | .[0])[]
             | "path \(.) is in two rules")
        end' <<< "$1"
}

# proxy_add_path_rules <module> <route-desc> <fqdn> <upstream> <port> <list-base>
#                      <rules-json> <route-zones-json> [-- <upstream flags>...]
# A route's path rules (proxyAccess, ADR-023 D1/D4): one handle per path, before
# the route's catch-all, with the rule's own access list (none for internet) —
# never a domain-level list (invariant I1). The handle's forward-auth follows the
# route's catch-all unless the rule says identityGate false. Path handles and
# rule lists no longer declared are pruned. Rule lists are named from their
# content, <list-base>:<zones sorted, joined by +>, so reordering rules churns
# nothing. Dies on an invalid rule.
proxy_add_path_rules() {
    local module="$1" route_desc="$2" fqdn="$3" upstream="$4" port="$5" base="$6" rules="$7" rzones_json="$8"
    shift 8; [[ "${1:-}" == "--" ]] && shift
    local -a up_args=("$@")
    [[ -n "${rules}" && "${rules}" != "null" ]] || rules="[]"

    local problems
    problems="$(proxy_path_rules_check "${rules}")"
    [[ -z "${problems}" ]] || die "proxyAccess on ${fqdn}: ${problems//$'\n'/; }"

    local n; n="$(jq 'length' <<< "${rules}")"
    if (( n > 0 )) && ! caddy-manager add-handler --help 2>/dev/null | grep -q -- '--path'; then
        die "proxyAccess on ${fqdn} needs a caddy-manager with add-handler --path — rebuild it (refresh-control-plane.sh)"
    fi

    local -a keep_desc=() keep_lists=() rzones=() rpaths=() acl_args=() gate_args=()
    local i path acl lname gate desc
    for (( i = 0; i < n; i++ )); do
        mapfile -t rzones < <(jq -r --argjson i "${i}" '.[$i].zones | map(tostring) | sort | .[]' <<< "${rules}")
        mapfile -t rpaths < <(jq -r --argjson i "${i}" '.[$i].paths[]' <<< "${rules}")
        gate="$(jq -r --argjson i "${i}" '.[$i].identityGate | if . == false then "off" else "route" end' <<< "${rules}")"
        if [[ -n "${rzones_json}" && "${rzones_json}" != "null" ]] \
           && [[ "$(jq -c 'map(tostring) | sort' <<< "${rzones_json}")" == "$(printf '%s\n' "${rzones[@]}" | jq -R . | jq -sc .)" ]]; then
            warn "  proxyAccess on ${fqdn}: a rule's zones equal the route's own — it changes nothing"
        fi
        lname="${base}:$(IFS=+; echo "${rzones[*]}")"
        acl="$(proxy_zone_access_list "${module}" "${lname}" "${ZONES_FILE}" "${route_desc} paths" "${rzones[@]}")" \
            || die "proxyAccess on ${fqdn}: a rule's zones cannot be resolved (see above)"
        acl_args=(); [[ -n "${acl}" ]] && { acl_args=(--access-list "${acl}"); keep_lists+=(--keep "${acl}"); PATH_RULE_LISTS+=("${acl}"); }
        gate_args=(--forward-auth-like "${route_desc}"); [[ "${gate}" == "off" ]] && gate_args=(--no-forward-auth)
        for path in "${rpaths[@]}"; do
            desc="${route_desc} ${path}"
            keep_desc+=(--keep "${desc}")
            debug "  Path rule: ${BL}${fqdn}${path}${CL} → ${acl:-anyone}${gate:+ (gate: ${gate})}"
            run_caddy add-handler "${fqdn}" --upstream "${upstream}" --port "${port}" \
                --description "${desc}" --path "${path}" \
                "${acl_args[@]+"${acl_args[@]}"}" "${gate_args[@]}" \
                "${up_args[@]+"${up_args[@]}"}" \
                --no-ssl-verify || die "Failed to create the path handle ${fqdn}${path}"
        done
    done

    # Prune what is no longer declared — the handles first, so no list is in use.
    if caddy-manager prune-handlers --help >/dev/null 2>&1; then
        caddy-manager prune-handlers --description-prefix "${route_desc} " \
            "${keep_desc[@]+"${keep_desc[@]}"}" --no-ssl-verify >/dev/null \
            || warn "Could not prune undeclared path handles of ${fqdn} (non-fatal)"
        caddy-manager prune-accesslists --name-prefix "${base}:" \
            "${keep_lists[@]+"${keep_lists[@]}"}" --no-ssl-verify >/dev/null \
            || warn "Could not prune undeclared path-rule lists of ${fqdn} (non-fatal)"
    fi
}

# proxy_prune_route_lists <module> [--keep <list>]... — delete the module's
# per-route access lists (tappaas-<module>#*) that are not kept. Non-fatal; a
# caddy-manager without the verb is reported, not failed.
proxy_prune_route_lists() {
    local module="$1"; shift
    if ! caddy-manager prune-accesslists --help >/dev/null 2>&1; then
        debug "  caddy-manager has no prune-accesslists — per-route lists not pruned" >&2
        return 0
    fi
    caddy-manager prune-accesslists --name-prefix "tappaas-${module}#" "$@" --no-ssl-verify >/dev/null \
        || warn "Could not prune undeclared route access lists for ${module} (non-fatal)"
}

# proxy_unpublish <module> <proxy-domain> <environment-domain> <module-json>
#
# Removes everything network:proxy publishes for a module: its handler, access
# list, domain, extra proxyRoutes, and their per-service split-horizon records
# (never the shared '*' wildcard). The one removal path — delete-service uses it
# to delete a module, install/update to withdraw one that is not published
# (#778): a per-service name with no public A record gets no certificate, so a
# Caddy route for it only makes Caddy fail ACME on every reload (and spend Let's
# Encrypt's failed-validation allowance) while serving no one. Every step is
# idempotent; a step that fails warns and the rest still run. The caller runs
# `caddy-manager reconfigure` afterwards.
# _caddy_detail <caddy-manager args…> — caddy-manager's own progress lines
# ("Handler … not found — nothing to delete", "Deleting handler …") are detail
# on every update of an unpublished module: debug. On failure they are printed.
_caddy_detail() {
    local out rc=0
    out="$(caddy-manager "$@" 2>&1)" || rc=$?
    if (( rc != 0 )); then
        [[ -n "${out}" ]] && printf '%s\n' "${out}" >&2
        return "${rc}"
    fi
    if [[ -n "${out}" ]]; then debug "  caddy-manager ${1}: ${out//$'\n'/; }"; fi
    return 0
}

proxy_unpublish() {
    local module="$1" domain="$2" env_domain="$3" json="$4"
    local desc="TAPPaaS: ${module}"
    _caddy_detail delete-handler --description "${desc}" --no-ssl-verify \
        || warn "Could not delete handler for ${module}"
    # Its path handles (ADR-023), then the lists its path rules used.
    if caddy-manager prune-handlers --help >/dev/null 2>&1; then
        caddy-manager prune-handlers --description-prefix "${desc} " --no-ssl-verify >/dev/null \
            || warn "Could not delete the path handles of ${module}"
        caddy-manager prune-accesslists --name-prefix "tappaas-${module}:" --no-ssl-verify >/dev/null \
            || warn "Could not delete the path-rule lists of ${module}"
    fi
    # The handler first, so nothing references the access list any more.
    caddy-manager delete-accesslist "tappaas-${module}" --no-ssl-verify >/dev/null 2>&1 || true
    if [[ -n "${domain}" ]]; then
        _caddy_detail delete-domain "${domain}" --no-ssl-verify \
            || warn "Could not delete domain ${domain}"
        unbound_prune_host_override "${domain%%.*}" "${domain#*.}"
        # A route from an earlier domain shares the description, not the name.
        proxy_prune_domains --description "${desc}" --keep "${domain}" --no-ssl-verify \
            || warn "Could not delete earlier-domain routes for ${module}"
    else
        warn "Cannot determine proxy domain for ${module} — manual cleanup may be needed"
    fi
    proxy_prune_domains --description-prefix "${desc}#" --no-ssl-verify \
        || warn "Could not delete additional routes for ${module}"
    proxy_prune_route_lists "${module}"
    if [[ -n "${json}" && -n "${env_domain}" ]]; then
        local _rname _rport
        while IFS=$'\t' read -r _rname _rport; do
            [[ -z "${_rname}" ]] && continue
            unbound_prune_host_override "${_rname}" "${env_domain}"
        done < <(echo "${json}" | jq -rc '.proxyRoutes // [] | .[] | [.name, (.port|tostring)] | @tsv')
    fi
    return 0
}
