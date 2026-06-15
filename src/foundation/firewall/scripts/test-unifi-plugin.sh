#!/usr/bin/env bash
#
# Offline unit tests for plugins/unifi.sh — the UniFi vendor plugin (ADR-008 #339).
#
# No live controller: sources the plugin, asserts the contract functions, and
# tests the interrogate VLAN-mapping logic by stubbing _unifi_login/_unifi_get
# with fixtures (access / customize-trunk / all-trunk ports). The apply path is
# validated live against real hardware (not unit-tested here).
#
# Usage: ./test-unifi-plugin.sh   — exit 0 all passed, 1 otherwise.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

PASS=0; FAIL=0
ck() { local d="$1" exp="$2" got="$3"; if [[ "$exp" == "$got" ]]; then echo "  ok: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected '$exp', got '$got')"; FAIL=$((FAIL+1)); fi; }

# shellcheck source=plugins/unifi.sh disable=SC1091
. "${SCRIPT_DIR}/plugins/unifi.sh"

echo "test-unifi-plugin:"

# Contract: plugin_supports
if plugin_supports unifi;   then ck "supports unifi"  yes yes; else ck "supports unifi"  yes no; fi
if plugin_supports generic; then ck "rejects generic" no  yes; else ck "rejects generic" no  no; fi
for fn in plugin_supports plugin_interrogate plugin_apply; do
    ck "function ${fn} defined" "function" "$(type -t "$fn")"
done

# Stub the API for an offline interrogate test.
_unifi_login() { _UNIFI_URL="https://stub"; _UNIFI_JAR="/dev/null"; _UNIFI_CSRF=""; return 0; }
_unifi_get() {
    case "$1" in
        /rest/networkconf) cat <<'JSON'
{"data":[{"_id":"def","name":"Default","vlan":null},{"_id":"n200","name":"srv","vlan":200},{"_id":"n210","name":"home","vlan":210}]}
JSON
        ;;
        /stat/device) cat <<'JSON'
{"data":[{"_id":"d1","name":"sw1","ip":"1.2.3.4","model":"USWX",
  "port_table":[{"port_idx":1,"forward":"all"},{"port_idx":2,"forward":"all"},{"port_idx":3,"forward":"all"}],
  "port_overrides":[
    {"port_idx":1,"forward":"native","native_networkconf_id":"n200"},
    {"port_idx":2,"forward":"customize","native_networkconf_id":"def","excluded_networkconf_ids":["n210"]}
  ]}]}
JSON
        ;;
    esac
}

OUT="$(plugin_interrogate sw1 1.2.3.4)"
ck "interrogate vendor"            "unifi" "$(jq -r .vendor <<<"$OUT")"
ck "port1 access"                  "access" "$(jq -r '.ports["1"].mode' <<<"$OUT")"
ck "port1 nativeVlan 200"          "200"    "$(jq -r '.ports["1"].nativeVlan' <<<"$OUT")"
ck "port2 trunk"                   "trunk"  "$(jq -r '.ports["2"].mode' <<<"$OUT")"
ck "port2 tagged = all minus excluded(210) = [200]" "200" "$(jq -rc '.ports["2"].taggedVlans|join(",")' <<<"$OUT")"
ck "port3 trunk(all) tagged = 200,210" "200,210" "$(jq -rc '.ports["3"].taggedVlans|join(",")' <<<"$OUT")"

echo ""
echo "test-unifi-plugin: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
