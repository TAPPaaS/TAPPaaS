# locations.sh — the site's locations, for the bash managers (ADR-036 D1, D2).
#
# A device names the location it is at with `location`: the name of one of
# site.json's `locations{}` (site-manager location list); absent, it is at the
# primary location. The TypeScript managers read them through
# lib/ts/src/locations.ts; switch-manager and ap-manager through these.
#
# Needs CONFIG_DIR and jq. Side-effect free: no logging.

# site_location_names — the site's location names, one per line.
site_location_names() {
    jq -r '.locations // {} | keys[]' "${CONFIG_DIR}/site.json" 2>/dev/null
}

# site_location_refusal <name> — why <name> cannot be a device's location, on
# stdout, rc 1; nothing and rc 0 when it is one of the site's.
site_location_refusal() {
    local name="$1" known
    if [[ ! "${name}" =~ ^[a-z][a-z0-9-]{0,62}$ ]]; then
        echo "'${name}' is not a location name — a location is one of the site's (site-manager location list); free text goes in --description"
        return 1
    fi
    if ! jq -e --arg n "${name}" '(.locations // {}) | has($n)' "${CONFIG_DIR}/site.json" >/dev/null 2>&1; then
        known="$(site_location_names | paste -sd, - | sed 's/,/, /g')"
        echo "the site has no location '${name}'${known:+ (it has: ${known})} — add it with site-manager location add ${name} --country <CC>, or put free text in --description"
        return 1
    fi
    return 0
}
