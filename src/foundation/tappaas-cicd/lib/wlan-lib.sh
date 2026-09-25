# shellcheck shell=bash
#
# wlan-lib.sh — the zones.json WiFi rules that ap-controller and
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
