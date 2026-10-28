#!/usr/bin/env bash
#
# Offline tests for ap-manager's site-wide SSIDs (#889): ssid add / modify /
# remove / list / set-passphrase, the zone's SSID written through
# network-manager set-ssid (a stub, unless AP_TEST_NETWORK_MANAGER names the real
# one), every AP's derived view, the old per-AP forms, and the passphrase never
# taken as an argument nor printed.
#
# Usage: ./test-ap-manager-ssids.sh   — exit 0 all passed, 1 otherwise.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
AM="${SCRIPT_DIR}/ap-manager"
# shellcheck source=test-lib.bash
. "${SCRIPT_DIR}/test-lib.bash"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
export CONFIG_DIR="${TMP}/config"
export SECRETS_FILE="${TMP}/wlan-secrets.txt"
mkdir -p "${CONFIG_DIR}"
export AP_NETWORK_MANAGER="${AP_TEST_NETWORK_MANAGER:-$(make_nm_stub "${TMP}")}"
Z="${CONFIG_DIR}/zones.json"
DES="${CONFIG_DIR}/switch-configuration-desired.json"
cat > "${Z}" <<'JSON'
{
  "mgmt":  { "type":"Management","state":"Manual","vlantag":0 },
  "home":  { "type":"Client","state":"Active","vlantag":310, "SSID":"<HOME_SSID>" },
  "guest": { "type":"Guest","state":"Active","vlantag":510, "SSID":"<GUEST_SSID>" },
  "iot":   { "type":"IoT","state":"Active","vlantag":410 }
}
JSON

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
rc_of() { "$@" >/dev/null 2>&1; echo $?; }
has() { grep -q -- "$2" <<< "$1" && echo yes || echo no; }
am() { "${AM}" "$@"; }
d() { jq -c "$1" "${DES}"; }
snap() { cat "${Z}" "${DES}" "${SECRETS_FILE}" 2>/dev/null | md5sum; }

echo "test-ap-manager-ssids:"

am add ap1 --vendor manual --ip 10.0.0.41 >/dev/null 2>&1
am add ap2 --vendor manual --ip 10.0.0.42 >/dev/null 2>&1

# ── add: one site-wide entry, the zone's SSID, every AP's view ──
out="$(am ssid add rossen-home --zone home --security wpa2-personal 2>&1)"; rc=$?
ck "add (rc)"                                   0 "${rc}"
ck "…one site-wide entry"                       '{"zone":"home","security":"wpa2-personal","broadcastOn":"all"}' "$(d '.ssids["rossen-home"]')"
ck "…the zone's SSID replaces the placeholder"  "rossen-home" "$(jq -r .home.SSID "${Z}")"
ck "…every AP broadcasts it on the zone's VLAN" '[310,310]' "$(d '[.accessPoints[].ssids["rossen-home"].vlan]')"
ck "…in the shape the controllers read"         '{"vlan":310,"zone":"home","security":"wpa2-personal","enabled":true}' "$(d '.accessPoints.ap1.ssids["rossen-home"]')"
ck "…says the passphrase is next"               yes "$(has "${out}" "ssid set-passphrase 'rossen-home'")"

before="$(snap)"
ck "add again is refused (rc)"                  1 "$(rc_of am ssid add rossen-home --zone home --security open)"
ck "a second SSID on the same zone (rc)"        1 "$(rc_of am ssid add other --zone home --security open)"
ck "…names the one it carries"                  yes "$(has "$(am ssid add other --zone home --security open 2>&1)" "already carries SSID 'rossen-home'")"
ck "a placeholder name (rc)"                    1 "$(rc_of am ssid add '<X>' --zone iot --security open)"
ck "a name with '=' (rc)"                       1 "$(rc_of am ssid add 'a=b' --zone iot --security open)"
ck "a 33-character name (rc)"                   1 "$(rc_of am ssid add "$(printf 'x%.0s' {1..33})" --zone iot --security open)"
ck "an unknown zone (rc)"                       1 "$(rc_of am ssid add n1 --zone nosuch --security open)"
ck "the Management zone (rc)"                   1 "$(rc_of am ssid add n1 --zone mgmt --security open)"
ck "an unknown security (rc)"                   1 "$(rc_of am ssid add n1 --zone iot --security wep)"
ck "--radius on a personal SSID (rc)"           1 "$(rc_of am ssid add n1 --zone iot --security wpa2-personal --radius r1)"
ck "--broadcast-on an unknown AP (rc)"          1 "$(rc_of am ssid add n1 --zone iot --security open --broadcast-on ap9)"
ck "…none of them changed anything"             "${before}" "$(snap)"

am ssid add things --zone iot --security wpa3-personal --broadcast-on ap2 --disabled >/dev/null 2>&1
ck "--broadcast-on a list: only those APs"      '[false,true]' "$(d '[.accessPoints.ap1.ssids, .accessPoints.ap2.ssids | has("things")]')"
ck "--disabled: kept, not broadcast"            false "$(d '.accessPoints.ap2.ssids.things.enabled')"

# ── set-passphrase: stdin or --file, never an argument, never printed ──
before="$(snap)"
ck "a passphrase as an argument (rc)"           1 "$(rc_of am ssid set-passphrase rossen-home hunter2hunter2)"
ck "…--passphrase too (rc)"                     1 "$(rc_of am ssid set-passphrase rossen-home --passphrase hunter2hunter2)"
ck "too short (rc)"                             1 "$(echo short | rc_of am ssid set-passphrase rossen-home)"
ck "too long (rc)"                              1 "$(printf 'x%.0s' {1..64} | rc_of am ssid set-passphrase rossen-home)"
ck "an undeclared SSID (rc)"                    1 "$(echo hunter2hunter2 | rc_of am ssid set-passphrase nosuch)"
am ssid add guest-open --zone guest --security open >/dev/null 2>&1
before="$(snap)"
ck "an open SSID takes none (rc)"               1 "$(echo hunter2hunter2 | rc_of am ssid set-passphrase guest-open)"
ck "…nothing changed"                           "${before}" "$(snap)"
out="$(echo 'pa=ss word 1' | am ssid set-passphrase rossen-home 2>&1)"; rc=$?
ck "from stdin (rc)"                            0 "${rc}"
ck "…stored by SSID, split on the first '='"    "rossen-home=pa=ss word 1" "$(cat "${SECRETS_FILE}")"
ck "…mode 600"                                  600 "$(stat -c '%a' "${SECRETS_FILE}")"
ck "…marked for the next reconcile"             true "$(d '.ssids["rossen-home"].passphraseChanged')"
ck "…and never printed"                         no "$(has "${out}" 'pa=ss word')"
jq '.ssids["rossen-home"].passphraseChanged = false' "${DES}" > "${DES}.t" && mv "${DES}.t" "${DES}"
echo 'pa=ss word 1' | am ssid set-passphrase rossen-home >/dev/null 2>&1
ck "the same passphrase again: no mark"         false "$(d '.ssids["rossen-home"].passphraseChanged')"
printf 'from-a-file-1\nsecond line\n' > "${TMP}/pp"
ck "--file (rc)"                                0 "$(rc_of am ssid set-passphrase rossen-home --file "${TMP}/pp")"
ck "…its first line"                            "rossen-home=from-a-file-1" "$(cat "${SECRETS_FILE}")"
ck "…marked again"                              true "$(d '.ssids["rossen-home"].passphraseChanged')"
echo 'things-pass-1' | am ssid set-passphrase things >/dev/null 2>&1
ck "a second SSID: its own line"                2 "$(wc -l < "${SECRETS_FILE}")"

# ── list ──
l="$(am ssid list --json)"
ck "list --json: every SSID"                    '["guest-open","rossen-home","things"]' "$(jq -c '[.[].name] | sort' <<<"${l}")"
ck "…zone, VLAN, APs"                           '{"zone":"home","vlan":310,"accessPoints":["ap1","ap2"]}' "$(jq -c '.[] | select(.name == "rossen-home") | {zone, vlan, accessPoints}' <<<"${l}")"
ck "…passphrase state"                          '["not needed","changed","changed"]' "$(jq -c '[sort_by(.name)[].passphrase]' <<<"${l}")"
ck "…never the passphrase"                      no "$(has "${l}" 'from-a-file')"
ck "list (text, rc)"                            0 "$(rc_of am ssid list)"

# ── modify ──
am ssid modify rossen-home --security wpa3-personal >/dev/null 2>&1
ck "modify --security: site-wide and every AP"  '["wpa3-personal","wpa3-personal"]' "$(d '[.accessPoints[].ssids["rossen-home"].security]')"
ck "…keeps the passphrase mark"                 true "$(d '.ssids["rossen-home"].passphraseChanged')"
ck "modify nothing (rc)"                        1 "$(rc_of am ssid modify rossen-home)"
ck "modify to a zone that carries one (rc)"     1 "$(rc_of am ssid modify rossen-home --zone guest)"
am ssid modify things --zone home 2>/dev/null; ck "modify to the zone of another (rc)" 1 "$?"
am ssid remove guest-open >/dev/null 2>&1
ck "remove: the entry goes"                     false "$(d '.ssids | has("guest-open")')"
ck "…and the zone's SSID"                       false "$(jq -c '.guest | has("SSID")' "${Z}")"
am ssid modify things --zone guest --enabled --broadcast-on all >/dev/null 2>&1
ck "modify --zone moves the zone's SSID"        '[null,"things"]' "$(jq -c '[.iot.SSID, .guest.SSID]' "${Z}")"
ck "…the VLAN follows on every AP"              '[510,510]' "$(d '[.accessPoints[].ssids.things.vlan]')"
ck "…--enabled, --broadcast-on all"             '[true,true]' "$(d '[.accessPoints[].ssids.things.enabled]')"

jq '.guest.SSID = "<GUEST_SSID>"' "${Z}" > "${Z}.t" && mv "${Z}.t" "${Z}"
am ssid modify things --zone guest >/dev/null 2>&1
ck "modify --zone to its own zone rewrites a zone that lost it" "things" "$(jq -r .guest.SSID "${Z}")"

# ── APs come and go ──
am add ap3 --vendor manual >/dev/null 2>&1
ck "a new AP broadcasts every SSID"             '["rossen-home","things"]' "$(d '.accessPoints.ap3.ssids | keys')"
am ssid modify things --broadcast-on ap3 >/dev/null 2>&1
am remove ap3 >/dev/null 2>&1
ck "an AP removed leaves the lists"             '[]' "$(d '.ssids.things.broadcastOn')"
out="$(am ssid modify things --broadcast-on all 2>&1)"
ck "…and the SSID is broadcast again"           '[true,true]' "$(d '[.accessPoints[].ssids | has("things")]')"

# ── the old per-AP forms, for one release ──
out="$(am ssid ap1 add cafe --zone iot --security open 2>&1)"; rc=$?
ck "old add (rc)"                               0 "${rc}"
ck "…says it is the old form"                   yes "$(has "${out}" "old per-AP form")"
ck "…site-wide: every AP"                       '[true,true]' "$(d '[.accessPoints[].ssids | has("cafe")]')"
ck "old add --vlan not the zone's (rc)"         1 "$(rc_of am ssid ap1 add cafe --zone iot --security open --vlan 999)"
ck "old add --vlan the zone's (rc)"             0 "$(rc_of am ssid ap1 add cafe --zone iot --security open --vlan 410)"
ck "old add on an existing SSID updates it"     '{"zone":"iot","security":"open","captive":true,"broadcastOn":"all"}' "$(am ssid ap2 add cafe --zone iot --security open --captive >/dev/null 2>&1; d '.ssids.cafe')"
ck "old list: the AP's SSIDs, as before"        '["cafe","rossen-home","things"]' "$(am ssid ap1 list 2>/dev/null | jq -c 'keys')"
am ssid ap1 remove cafe >/dev/null 2>&1
ck "old remove on one AP: the other keeps it"   '["ap2"]' "$(d '.ssids.cafe.broadcastOn')"
am ssid ap2 remove cafe >/dev/null 2>&1
ck "old remove on the last AP: it goes"         false "$(d '.ssids | has("cafe")')"
ck "…with the zone's SSID"                      null "$(jq -c '.iot.SSID' "${Z}")"
ck "old form on a missing AP (rc)"              1 "$(rc_of am ssid nope list)"

# ── remove: the passphrase goes too ──
am ssid remove things >/dev/null 2>&1
ck "remove drops its passphrase line"           "rossen-home=from-a-file-1" "$(cat "${SECRETS_FILE}")"
ck "…and every AP's view"                       '[false,false]' "$(d '[.accessPoints[].ssids | has("things")]')"
ck "remove of none (rc)"                        1 "$(rc_of am ssid remove things)"

# ── reconcile: every AP, a changed passphrase pushed, the marks cleared ──
STUB="${TMP}/plugins"; mkdir -p "${STUB}"
cat > "${STUB}/stubv.sh" <<'PLUGIN'
plugin_supports() { [[ "$1" == "stubv" ]]; }
plugin_ap_interrogate() { echo '{}'; }
plugin_ap_apply() { echo "$1|$2" >> "${AP_TEST_APPLY_LOG}"; return 0; }
PLUGIN
export PLUGIN_DIR="${STUB}" AP_TEST_APPLY_LOG="${TMP}/applied.log"
jq '.accessPoints[].vendor = "stubv"' "${DES}" > "${DES}.t" && mv "${DES}.t" "${DES}"
jq '.guest.SSID = "<GUEST_SSID>"' "${Z}" > "${Z}.t" && mv "${Z}.t" "${Z}"
am update-desired >/dev/null 2>&1
out="$(am delta 2>&1)"
ck "delta: a new SSID on each AP"               yes "$(has "${out}" 'ap2: 1 change')"
ck "…a zone still on its placeholder says nothing" no "$(has "${out}" "template SSID")"
ck "reconcile --apply (rc): converged, no warning" 0 "$(rc_of am reconcile --apply)"
ck "…the controller ran for every AP"           '["ap1","ap2"]' "$(cut -d'|' -f1 "${AP_TEST_APPLY_LOG}" | sort -u | jq -R . | jq -sc .)"
ck "…the passphrase marks cleared"              false "$(d '[.ssids[] | has("passphraseChanged")] | any')"
ck "…nothing left per AP"                       no "$(has "$(am delta 2>&1)" 'change(s)')"
: > "${AP_TEST_APPLY_LOG}"
echo 'a-new-passphrase' | am ssid set-passphrase rossen-home >/dev/null 2>&1
out="$(am delta 2>&1)"
ck "a changed passphrase is a change on each AP" yes "$(has "${out}" 'ssid-passphrase: SSID rossen-home')"
ck "…on both"                                   2 "$(grep -c 'ssid-passphrase' <<<"${out}")"
ck "…the passphrase itself is not shown"        no "$(has "${out}" 'a-new-passphrase')"
am reconcile --apply >/dev/null 2>&1
ck "reconcile --apply pushes it to every AP"    '["ap1","ap2"]' "$(cut -d'|' -f1 "${AP_TEST_APPLY_LOG}" | sort -u | jq -R . | jq -sc .)"
ck "…as a passphrase change"                    yes "$(has "$(cat "${AP_TEST_APPLY_LOG}")" '"action":"ssid-passphrase"')"
ck "…and confirm clears the mark"               false "$(d '.ssids["rossen-home"] | has("passphraseChanged")')"
am ssid modify rossen-home --security wpa2-personal >/dev/null 2>&1
ck "a security change: ssid-settings per AP"    yes "$(has "$(am delta 2>&1)" 'ssid-settings: SSID rossen-home security wpa3-personal -> wpa2-personal')"
am ssid modify rossen-home --disabled >/dev/null 2>&1
ck "disabled: per AP"                           yes "$(has "$(am delta 2>&1)" 'disable')"
am reconcile --apply >/dev/null 2>&1
am ssid add guestnet --zone guest --security open >/dev/null 2>&1
out="$(am delta 2>&1)"
ck "a real SSID recorded: no placeholder talk either" no "$(has "${out}" 'template SSID')"
jq '.iot.SSID = "Stray"' "${Z}" > "${Z}.t" && mv "${Z}.t" "${Z}"
ck "a zone naming an SSID no one holds"         yes "$(has "$(am delta 2>&1)" "zone 'iot' names SSID 'Stray', which ap-manager does not hold")"
jq '.guest.state = "Inactive" | del(.iot.SSID)' "${Z}" > "${Z}.t" && mv "${Z}.t" "${Z}"
ck "an SSID on a zone that is off"              yes "$(has "$(am delta 2>&1)" "SSID 'guestnet' bridges to zone 'guest', which is Inactive")"
jq '.guest.state = "Active"' "${Z}" > "${Z}.t" && mv "${Z}.t" "${Z}"
unset PLUGIN_DIR

# ── a site that has not run migration 0025 ──
jq 'del(.ssids) | .accessPoints.ap1.ssids = {"old":{"vlan":310,"zone":"home","security":"open","enabled":true}}' "${DES}" > "${DES}.t" && mv "${DES}.t" "${DES}"
before="$(snap)"
out="$(am ssid add n2 --zone iot --security open 2>&1)"; rc=$?
ck "per-AP SSIDs and no site-wide list (rc)"    1 "${rc}"
ck "…names migration 0025"                      yes "$(has "${out}" "migration 0025")"
ck "…nothing changed"                           "${before}" "$(snap)"

# #644: the gate knows the new verbs
ck "ssid add --help (rc)"                       0 "$(rc_of am ssid add x --help)"
ck "ssid add --vlan is the old form's (rc)"     1 "$(rc_of am ssid add x --zone iot --security open --vlan 410)"
ck "ssid set-passphrase --help (rc)"            0 "$(rc_of am ssid set-passphrase x --help)"

echo ""
echo "test-ap-manager-ssids: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
