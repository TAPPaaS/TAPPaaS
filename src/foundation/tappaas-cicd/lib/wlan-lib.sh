# shellcheck shell=bash
#
# wlan-lib.sh — the zones.json WiFi rules that ap-manager and
# setup-wlan-secrets.sh share, so their readings of the same field cannot drift
# apart (#734). Sourced; needs jq.

# The template ships every SSID as a placeholder to replace, e.g. <HOME_SSID>.
is_placeholder() { [[ "$1" == \<*\> ]]; }

# "<zone>\t<ssid>\t<vlantag>" for each zone that should broadcast WiFi: it
# declares an SSID and is Active (no state = Active). An Inactive or Disabled
# zone keeps its SSID for later and broadcasts nothing. A zone with no WiFi
# omits SSID or sets it to null.
wlan_zones() {
    jq -r 'to_entries[]
           | select((.value.SSID? != null) and ((.value.state // "Active") == "Active"))
           | "\(.key)\t\(.value.SSID)\t\(.value.vlantag // 0)"' "$1"
}

# How many SSIDs one AP may broadcast before each one costs the rest airtime:
# every SSID beacons separately on every radio, and vendor guidance (Ubiquiti)
# puts the practical limit at about 4 per radio. An AP entry may set its own
# `maxSsids`; TAPPAAS_AP_MAX_SSIDS changes the default.
WLAN_MAX_SSIDS_DEFAULT="${TAPPAAS_AP_MAX_SSIDS:-4}"

# wlan_max_ssids <ap> <desired.json> — the ceiling that applies to <ap>.
wlan_max_ssids() {
    jq -r --arg a "$1" --argjson d "${WLAN_MAX_SSIDS_DEFAULT}" \
        '.accessPoints[$a].maxSsids // $d' "$2"
}

# wlan_ssid_count <ap> <desired.json> — the SSIDs <ap> broadcasts (enabled ones).
wlan_ssid_count() {
    jq -r --arg a "$1" '[.accessPoints[$a].ssids // {} | .[] | select(.enabled != false)] | length' "$2"
}

# ── The WiFi networks' names and passphrases (#889) ─────────────────────
#
# An SSID is a site-wide network (switch-configuration-desired.json `.ssids`),
# owned by ap-manager. Its WPA passphrase lives only in a 0600 secrets file,
# one "<SSID>=<passphrase>" line each, split on the FIRST '=' so a passphrase may
# contain '='. The vendor plugins and the console read the same file.

WLAN_SECRETS_FILE="${SECRETS_FILE:-${WLAN_SECRETS:-/home/tappaas/.wlan-secrets.txt}}"

# Why <name> cannot be an SSID, or nothing: 1–32 characters, no '=' (the file
# is SSID=passphrase), no line break, not the template's placeholder.
wlan_ssid_problem() {
    local s="$1"
    if [[ ${#s} -lt 1 || ${#s} -gt 32 ]]; then echo "an SSID is 1 to 32 characters"; return 0; fi
    if [[ "${s}" == *=* || "${s}" == *$'\n'* || "${s}" == *$'\r'* ]]; then echo "an SSID has no '=' and no line break (the passphrase file is SSID=passphrase)"; return 0; fi
    if is_placeholder "${s}"; then echo "a real name, not the template's placeholder"; return 0; fi
    return 0
}

# Why <passphrase> cannot be a WPA passphrase, or nothing: 8–63 printable ASCII.
wlan_passphrase_problem() {
    local p="$1"
    if [[ ${#p} -lt 8 || ${#p} -gt 63 ]]; then echo "a WPA passphrase is 8 to 63 characters"; return 0; fi
    if ! LC_ALL=C grep -qx '[ -~]*' <<<"${p}"; then echo "a WPA passphrase is printable ASCII (no line break or control character)"; return 0; fi
    return 0
}

# The stored passphrase for <ssid> (empty if none).
wlan_secret_get() {
    [[ -f "${WLAN_SECRETS_FILE}" ]] || return 0
    awk -v s="$1" '{eq=index($0,"="); if(eq>0 && substr($0,1,eq-1)==s){print substr($0,eq+1); exit}}' "${WLAN_SECRETS_FILE}"
}

# True if a line for <ssid> exists.
wlan_secret_has() {
    [[ -f "${WLAN_SECRETS_FILE}" ]] || return 1
    awk -v s="$1" 'BEGIN{f=1} {eq=index($0,"="); if(eq>0 && substr($0,1,eq-1)==s){f=0; exit}} END{exit f}' "${WLAN_SECRETS_FILE}"
}

# The file without <ssid>'s line, plus "<ssid>=<pass>" when a passphrase is
# given: written to a 0600 temp file beside it, then renamed over it.
_wlan_secret_rewrite() {
    local ssid="$1" pass="${2-}" tmp
    ( umask 077; touch "${WLAN_SECRETS_FILE}" )
    chmod 600 "${WLAN_SECRETS_FILE}"
    tmp="$(umask 077; mktemp "${WLAN_SECRETS_FILE}.XXXXXX")"
    awk -v s="${ssid}" '{eq=index($0,"="); k=(eq>0?substr($0,1,eq-1):$0); if(k!=s) print}' "${WLAN_SECRETS_FILE}" > "${tmp}"
    if [[ $# -ge 2 ]]; then printf '%s=%s\n' "${ssid}" "${pass}" >> "${tmp}"; fi
    chmod 600 "${tmp}"
    mv "${tmp}" "${WLAN_SECRETS_FILE}"
}

# Set <ssid>'s passphrase (replacing any line for it).
wlan_secret_set() { _wlan_secret_rewrite "$1" "$2"; }

# Remove <ssid>'s line, if any.
wlan_secret_del() {
    wlan_secret_has "$1" || return 0
    _wlan_secret_rewrite "$1"
}
