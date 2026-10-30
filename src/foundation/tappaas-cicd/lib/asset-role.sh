# asset-role.sh — the asset behind a role, for the bash managers (ADR-040 D7, D8).
#
# A switch or an access point is a role an asset plays for a while; the asset
# is the box, in asset-manager's register. When a manager adds the role it
# calls asset_role_begin: with --asset the named asset is allocated (asset
# first); without, an asset already playing the role is kept, else a new one is
# recorded under the next free tag of its kind (sw-NN, ap-NN; ADR-040 O5) with
# the role's name as its display name and the vendor and model the verb was
# given, and allocated. When the role is removed, asset_role_end releases the
# asset: it keeps its placement, ports and cables under its own name (D7).
# site-manager does the same for nodes in TypeScript (manager/site-manager
# src/asset.ts), reading the machine's serial and MACs too; a controller's
# report does not give those for a switch or an AP yet, so nothing is matched
# here: an operator who recorded the box names it with --asset.
#
# A failure is a warning naming the asset-manager command to run, never a
# failed add or remove. Needs jq, and asset-manager on PATH (ASSET_MANAGER
# overrides, for tests); with neither the functions do nothing.

ASSET_MANAGER="${ASSET_MANAGER:-asset-manager}"

_asset_role_ok() { command -v "${ASSET_MANAGER}" >/dev/null 2>&1; }

# _asset_role_rows — `asset list --json`, or nothing.
_asset_role_rows() { "${ASSET_MANAGER}" asset list --json 2>/dev/null || echo "[]"; }

# asset_role_playing <role> — the asset playing <role>, or nothing.
asset_role_playing() {
    _asset_role_ok || return 0
    _asset_role_rows | jq -r --arg r "$1" '[.[] | select(.role == $r)][0].name // empty'
}

# _asset_role_next_tag <prefix> — the next free <prefix>-NN among the assets.
_asset_role_next_tag() {
    local prefix="$1" top
    top="$(_asset_role_rows | jq -r --arg p "${prefix}" '[.[].name | capture("^" + $p + "-(?<n>[0-9]+)$") | .n | tonumber] | max // 0')"
    printf '%s-%02d\n' "${prefix}" "$(( top + 1 ))"
}

# asset_role_begin <role> <kind> <asset-or-empty> [vendor] [model]
#   kind: switch | access-point. Prints what it did on stderr through info/warn
#   (the manager's). Returns 0 always.
asset_role_begin() {
    local role="$1" kind="$2" asset="${3:-}" vendor="${4:-}" model="${5:-}"
    _asset_role_ok || return 0
    local playing prefix key out
    playing="$(asset_role_playing "${role}")"
    if [[ -n "${playing}" ]]; then
        if [[ -n "${asset}" && "${asset}" != "${playing}" ]]; then
            warn "  asset ${playing} plays ${role} already; ${asset} is not allocated — asset-manager asset release ${playing} first"
        else
            info "  asset ${playing} plays ${role} already"
        fi
        return 0
    fi
    if [[ -n "${asset}" ]]; then
        key="${asset}"
    else
        case "${kind}" in switch) prefix=sw ;; access-point) prefix=ap ;; server) prefix=srv ;; *) prefix=dev ;; esac
        key="$(_asset_role_next_tag "${prefix}")"
        local -a add=(asset add "${key}" --kind "${kind}" --display-name "${role}")
        [[ -n "${vendor}" ]] && add+=(--vendor "${vendor}")
        [[ -n "${model}" ]] && add+=(--model "${model}")
        if ! out="$("${ASSET_MANAGER}" "${add[@]}" 2>&1)"; then
            warn "  no asset recorded for ${role}: ${out##*$'\n'} — asset-manager ${add[*]}"
            return 0
        fi
        info "  asset ${key} (new) recorded for ${role}"
    fi
    if out="$("${ASSET_MANAGER}" asset allocate "${key}" --role "${role}" 2>&1)"; then
        info "  ${GN}✓${CL} asset ${key} plays ${role}"
        [[ -z "${asset}" ]] && info "  place it where it stands: asset-manager place '${role}' --rack <rack> --u <n> (or the console's Physical view)"
    else
        warn "  asset ${key} is not allocated to ${role}: ${out##*$'\n'} — asset-manager asset allocate ${key} --role '${role}'"
    fi
    return 0
}

# asset_role_end <role> — the role ends; its asset is released. Returns 0 always.
asset_role_end() {
    local role="$1" key out
    _asset_role_ok || return 0
    key="$(asset_role_playing "${role}")"
    [[ -n "${key}" ]] || return 0
    if out="$("${ASSET_MANAGER}" asset release "${key}" 2>&1)"; then
        info "  ${GN}✓${CL} asset ${key} released from ${role}: ${out##*$'\n'}"
    else
        warn "  asset ${key} still plays ${role}: ${out##*$'\n'} — asset-manager asset release ${key}"
    fi
    return 0
}
