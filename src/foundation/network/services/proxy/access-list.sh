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
            info "  '${module}' is exposed to the ${BL}internet${CL} — no access restriction" >&2
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
    if ! caddy-manager add-accesslist --help >/dev/null 2>&1; then
        warn "  caddy-manager does not support 'add-accesslist' — zone restriction skipped." >&2
        warn "  Update caddy-manager to enable per-domain IP allow-lists." >&2
        printf ''
        return 0
    fi

    if ! run_caddy add-accesslist "${al_name}" \
            --clients "${cidrs}" \
            --matcher remote_ip \
            --response-code 403 \
            --description "${description} (allowed zones)" \
            --no-ssl-verify; then
        error "Failed to create/update Caddy access list ${al_name}" >&2
        return 1
    fi

    printf '%s' "${al_name}"
}

# proxy_split_horizon_gateway <module_json> <zones_file>
#
# Echo the split-horizon DNS target for a per-service module: the OPNsense
# gateway IP of its PRIMARY authorized client zone (ADR-005 §6, #504) — NOT the
# DMZ gateway, which home/work cannot reach. Primary = the first client zone in
# proxyAllowedZones (author order); for the default (empty) set, home → work →
# mgmt. "internet" and "netbird" are not subnets and are skipped.
#
# unbound-manager holds ONE IP per host, so only the primary zone gets a working
# split-horizon entry. When more than one client zone is authorized we warn:
# the rest need Unbound access-control-view (not yet implemented) and their
# clients will 403 until then. Progress/warnings go to stderr so stdout carries
# only the gateway IP. Returns non-zero if no client-zone gateway can be derived.
proxy_split_horizon_gateway() {
    local module_json="$1" zones_file="$2"
    local -a zones=()
    mapfile -t zones < <(normalize_module_config < "${module_json}" 2>/dev/null | jq -r '.proxyAllowedZones // [] | .[]' 2>/dev/null)

    local -a client=()
    local z
    if [[ ${#zones[@]} -eq 0 ]]; then
        # Default set → prefer home, then work, then mgmt (ADR-005 §6 default).
        for z in home work mgmt; do
            [[ -n "$(jq -r --arg z "${z}" '.[$z].ip // empty' "${zones_file}" 2>/dev/null)" ]] && client+=("${z}")
        done
    else
        for z in "${zones[@]}"; do
            [[ "${z}" == "internet" || "${z}" == "netbird" ]] && continue
            [[ -n "$(jq -r --arg z "${z}" '.[$z].ip // empty' "${zones_file}" 2>/dev/null)" ]] && client+=("${z}")
        done
    fi

    [[ ${#client[@]} -eq 0 ]] && return 1

    local primary="${client[0]}"
    if [[ ${#client[@]} -gt 1 ]]; then
        warn "  split-horizon: ${#client[@]} client zone(s) authorized (${client[*]}) but unbound holds one IP per host — registering only the primary '${primary}'. Other zones need Unbound access-control-view (not yet implemented) and will 403 until then." >&2
    fi
    zone_gateway_ip "${primary}" "${zones_file}"
}
