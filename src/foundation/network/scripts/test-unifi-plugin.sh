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
for fn in plugin_supports plugin_interrogate plugin_apply plugin_ap_interrogate plugin_ap_apply \
          plugin_arch plugin_controller_module plugin_controller_interrogate; do
    ck "function ${fn} defined" "function" "$(type -t "$fn")"
done
ck "plugin_arch is controller"      "controller" "$(plugin_arch)"
ck "plugin_controller_module"       "unifi-os"   "$(plugin_controller_module)"

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

# ── Controller interrogate: enumerate usw switches (skip uap) ───────
_unifi_get() {
    case "$1" in
        /rest/networkconf) cat <<'JSON'
{"data":[{"_id":"def","name":"Default","vlan":null},{"_id":"n200","name":"srv","vlan":200},{"_id":"n210","name":"home","vlan":210}]}
JSON
        ;;
        /stat/device) cat <<'JSON'
{"data":[
  {"_id":"d1","name":"USW Pro","type":"usw","model":"USWPRO","ip":"10.0.0.5","mac":"aa:bb:cc:00:00:01",
   "port_table":[{"port_idx":1,"forward":"all"},{"port_idx":2,"forward":"native"}],
   "port_overrides":[{"port_idx":2,"forward":"native","native_networkconf_id":"n200"}]},
  {"_id":"ap1","name":"Nano","type":"uap","model":"U7","ip":"10.0.0.9",
   "uplink":{"uplink_device_name":"USW Pro","uplink_remote_port":5,"uplink_mac":"aa:bb:cc:00:00:01"}}
]}
JSON
        ;;
    esac
}
COUT="$(plugin_controller_interrogate ctrl1 https://x)"
ck "controller lists the usw switch"   "USW Pro" "$(jq -r '.switches|keys[0]' <<<"$COUT")"
ck "controller has 1 switch"           "1"       "$(jq -r '.switches|length' <<<"$COUT")"
ck "controller switch vendor"          "unifi"   "$(jq -r '.switches["USW Pro"].vendor' <<<"$COUT")"
ck "controller port1 trunk(all)"       "200,210" "$(jq -rc '.switches["USW Pro"].ports["1"].taggedVlans|join(",")' <<<"$COUT")"
ck "controller port2 access nativeVlan" "200"    "$(jq -r '.switches["USW Pro"].ports["2"].nativeVlan' <<<"$COUT")"
# APs: enumerated with their uplink resolved to switch + port
ck "controller lists the uap"          "Nano"    "$(jq -r '.aps|keys[0]' <<<"$COUT")"
ck "ap uplinkSwitch detected"          "USW Pro" "$(jq -r '.aps["Nano"].uplinkSwitch' <<<"$COUT")"
ck "ap uplinkPort detected"            "5"       "$(jq -r '.aps["Nano"].uplinkPort' <<<"$COUT")"
ck "ap model"                          "U7"      "$(jq -r '.aps["Nano"].model' <<<"$COUT")"

# ── AP (WiFi) interrogate + security mapping (offline) ──────────────
# Re-stub the API for a uap device + two WLANs (one disabled WPA2 on VLAN 400,
# one enabled open on the default/untagged network).
_unifi_get() {
    case "$1" in
        /rest/networkconf) cat <<'JSON'
{"data":[{"_id":"def","name":"Default","vlan":null},{"_id":"n400","name":"tappaas-vlan-400","vlan":400}]}
JSON
        ;;
        /stat/device) cat <<'JSON'
{"data":[{"_id":"ap1","name":"Nano HD","ip":"10.0.0.184","model":"U7NHD","type":"uap"}]}
JSON
        ;;
        /rest/wlanconf) cat <<'JSON'
{"data":[
  {"_id":"w1","name":"iot-wifi","enabled":false,"security":"wpapsk","wpa_mode":"wpa2","networkconf_id":"n400"},
  {"_id":"w2","name":"guest","enabled":true,"security":"open","networkconf_id":"def"}
]}
JSON
        ;;
    esac
}

APOUT="$(plugin_ap_interrogate nano-hd 10.0.0.184)"
ck "ap interrogate vendor"          "unifi"  "$(jq -r .vendor <<<"$APOUT")"
ck "ap interrogate model"           "U7NHD"  "$(jq -r .model <<<"$APOUT")"
ck "ssid iot-wifi vlan 400"         "400"    "$(jq -r '.ssids["iot-wifi"].vlan' <<<"$APOUT")"
ck "ssid iot-wifi disabled (false//true fix)" "false" "$(jq -r '.ssids["iot-wifi"].enabled' <<<"$APOUT")"
ck "ssid iot-wifi security wpa2-personal"      "wpa2-personal" "$(jq -r '.ssids["iot-wifi"].security' <<<"$APOUT")"
ck "ssid guest vlan 0 (untagged)"   "0"      "$(jq -r '.ssids["guest"].vlan' <<<"$APOUT")"
ck "ssid guest security open"       "open"   "$(jq -r '.ssids["guest"].security' <<<"$APOUT")"
ck "ssid guest enabled true"        "true"   "$(jq -r '.ssids["guest"].enabled' <<<"$APOUT")"

# AP interrogate returns {} when the device is not found (no pollution of actual).
ck "ap interrogate unknown -> {}"   "{}"     "$(plugin_ap_interrogate nope 9.9.9.9 | jq -c .)"

# _unifi_security_fields mapping
ck "secfields open"                 "open"   "$(_unifi_security_fields open "" | jq -r .security)"
ck "secfields wpa2 passphrase"      "secret123" "$(_unifi_security_fields wpa2-personal secret123 | jq -r .x_passphrase)"
ck "secfields wpa2 wpa_mode"        "wpa2"   "$(_unifi_security_fields wpa2-personal secret123 | jq -r .wpa_mode)"
ck "secfields wpa3 wpa_mode"        "wpa3"   "$(_unifi_security_fields wpa3-personal secret123 | jq -r .wpa_mode)"
ck "secfields open has no passphrase" "null" "$(_unifi_security_fields open "" | jq -r '.x_passphrase // "null"')"

# ── apply manages ONLY annotated ports (type set), not discovered ones ──
APTMP="$(mktemp -d)"; export CONFIG_DIR="${APTMP}"
cat > "${APTMP}/switch-configuration-desired.json" <<'JSON'
{"switches":{"SW":{"managementIp":"","ports":{
  "1":{"mode":"trunk","taggedVlans":[200],"source":"discovered"},
  "3":{"mode":"trunk","taggedVlans":[200,310],"type":"node","target":"tappaas1"},
  "9":{"mode":"trunk","taggedVlans":[310],"type":"ap","target":"AP"}
}}},"accessPoints":{}}
JSON
_unifi_login() { _UNIFI_URL="x"; _UNIFI_JAR="/dev/null"; _UNIFI_CSRF=""; return 0; }
_unifi_get() {
    case "$1" in
        /rest/networkconf) echo '{"data":[{"_id":"def","vlan":null},{"_id":"n200","vlan":200},{"_id":"n310","vlan":310}]}' ;;
        /stat/device) echo '{"data":[{"_id":"d1","name":"SW","ip":"","port_overrides":[]}]}' ;;
    esac
}
_unifi_send() { if [[ "$1" == "PUT" ]]; then echo "$3" > "${APTMP}/put.json"; fi; echo '{"meta":{"rc":"ok"}}'; }
plugin_apply SW "{}" >/dev/null 2>&1
ck "apply touches only annotated ports" "3,9" "$(jq -rc '[.port_overrides[].port_idx]|sort|join(",")' "${APTMP}/put.json" 2>/dev/null)"
rm -rf "${APTMP}"

echo ""
echo "test-unifi-plugin: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
