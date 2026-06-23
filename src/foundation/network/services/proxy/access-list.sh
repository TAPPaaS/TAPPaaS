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
        info "  Access: ${BL}default internal zones${CL} (${zones[*]:-none})" >&2
    else
        info "  Access: ${BL}${zones[*]}${CL}" >&2
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
    local cidrs="" cidr
    for z in "${zones[@]}"; do
        cidr=$(jq -r --arg z "${z}" '.[$z].ip // empty' "${zones_file}" 2>/dev/null)
        if [[ -z "${cidr}" ]]; then
            warn "  zone '${z}' not found in zones.json — skipping" >&2
            continue
        fi
        cidrs="${cidrs:+${cidrs},}${cidr}"
    done

    if [[ -z "${cidrs}" ]]; then
        error "proxyAllowedZones for '${module}' resolved to no networks — refusing to create an empty allow-list (it would block everything)" >&2
        return 1
    fi

    info "  Access list ${BL}${al_name}${CL}: allow only ${BL}${cidrs}${CL}" >&2

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

    if ! caddy-manager add-accesslist "${al_name}" \
            --clients "${cidrs}" \
            --matcher remote_ip \
            --response-code 403 \
            --description "${description} (allowed zones)" \
            --no-ssl-verify >&2; then
        error "Failed to create/update Caddy access list ${al_name}" >&2
        return 1
    fi

    printf '%s' "${al_name}"
}
