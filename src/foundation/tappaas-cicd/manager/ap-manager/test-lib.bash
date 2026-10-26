# shellcheck shell=bash
# test-lib.bash — sourced by the ap-manager tests (not a test, not installed).
#
# make_nm_stub <dir> — writes <dir>/bin/network-manager, a stand-in for
# `network-manager set-ssid <zone> <ssid> | <zone> --clear --zones-file <f>`
# (#889), and prints its path. It writes the field as the real verb does and
# refuses what it refuses (no such zone; a Management, WAN or Overlay zone).
make_nm_stub() {
    mkdir -p "$1/bin"
    cat > "$1/bin/network-manager" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == set-ssid ]] || { echo "stub network-manager: only set-ssid" >&2; exit 1; }
shift
zone="$1"; shift
arg=""; file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --zones-file) file="$2"; shift 2 ;;
        *) arg="$1"; shift ;;
    esac
done
jq -e --arg z "${zone}" 'has($z)' "${file}" >/dev/null || { echo "set-ssid: zone '${zone}' not found" >&2; exit 1; }
if [[ "${arg}" == --clear ]]; then
    jq --arg z "${zone}" 'del(.[$z].SSID)' "${file}" > "${file}.t" && mv "${file}.t" "${file}"
    exit 0
fi
case "$(jq -r --arg z "${zone}" '.[$z].type // ""' "${file}")" in
    Management|WAN|Overlay) echo "set-ssid: zone '${zone}' carries no WiFi" >&2; exit 1 ;;
esac
jq --arg z "${zone}" --arg s "${arg}" '.[$z].SSID = $s' "${file}" > "${file}.t" && mv "${file}.t" "${file}"
STUB
    chmod +x "$1/bin/network-manager"
    echo "$1/bin/network-manager"
}
