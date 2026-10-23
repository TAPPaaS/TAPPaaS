#!/usr/bin/env bash
#
# Unit tests for switch-manager — the physical-switch provider (ADR-008, #339).
#
# Black-box / offline against a temp CONFIG_DIR + fixture zones.json. No live
# switches (manual plugin fallback). Covers the 3-tier inventory (controller /
# switch / port), the regenerated-desired model, and the reconcile lifecycle
# (interrogate → update-desired → delta → apply → confirm), incl. add/remove port.
#
# Usage: ./test-switch-manager.sh   — exit 0 all passed, 1 otherwise.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SM="${SCRIPT_DIR}/switch-manager"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
export CONFIG_DIR="${TMP}"
cat > "${TMP}/zones.json" <<'JSON'
{
  "mgmt": { "state": "Manual",    "vlantag": 0   },
  "srv":  { "state": "Active",    "vlantag": 200 },
  "home": { "state": "Active",    "vlantag": 310, "SSID": "Home" },
  "iotLocal": { "state": "Active", "vlantag": 410 },
  "dmz":  { "state": "Mandatory", "vlantag": 610 },
  "old":  { "state": "Inactive",  "vlantag": 999 }
}
JSON
ACT="${TMP}/switch-configuration-actual.json"
DES="${TMP}/switch-configuration-desired.json"
PASS=0; FAIL=0
ck() { local d="$1" e="$2" g="$3"; if [[ "$e" == "$g" ]]; then echo "  ok: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected '$e', got '$g')"; FAIL=$((FAIL+1)); fi; }
has() { grep -q -- "$2" <<< "$1" && echo yes || echo no; }
rc_of() { "$@" >/dev/null 2>&1; echo $?; }

echo "test-switch-manager:"

# ── Inventory: switch + ports written to ACTUAL ─────────────────────
"${SM}" add-switch core --vendor tplink --managed manual >/dev/null 2>&1
ck "add-switch writes actual"        "tplink" "$(jq -r '.switches.core.vendor' "${ACT}")"
ck "add-switch records managed"      "manual" "$(jq -r '.switches.core.managed' "${ACT}")"
ck "add-switch desired untouched"    "true"   "$(jq -e '(.switches // {}) == {}' "${DES}" >/dev/null && echo true || echo false)"
ck "add-switch dup rejected (rc)"    "1"      "$(rc_of "${SM}" add-switch core --vendor x --managed manual)"
ck "add-switch bad managed (rc)"     "1"      "$(rc_of "${SM}" add-switch s2 --vendor x --managed bogus)"
ck "add-switch needs managed (rc)"   "1"      "$(rc_of "${SM}" add-switch s2 --vendor x)"

# ── Ports: topology only (no VLANs yet) ─────────────────────────────
"${SM}" add-port core 4 --type node --target tappaas1 --target-port eth0 >/dev/null 2>&1
ck "add-port type recorded"          "node"     "$(jq -r '.switches.core.ports["4"].type' "${ACT}")"
ck "add-port target recorded"        "tappaas1" "$(jq -r '.switches.core.ports["4"].target' "${ACT}")"
ck "add-port targetPort recorded"    "eth0"     "$(jq -r '.switches.core.ports["4"].targetPort' "${ACT}")"
ck "add-port node defaults trunk"    "trunk"    "$(jq -r '.switches.core.ports["4"].mode' "${ACT}")"
ck "add-port no VLANs yet"           "null"     "$(jq -r '.switches.core.ports["4"].taggedVlans // "null"' "${ACT}")"
ck "add-port bad type (rc)"          "1"        "$(rc_of "${SM}" add-port core 9 --type bogus)"
ck "add-port needs type (rc)"        "1"        "$(rc_of "${SM}" add-port core 9 --target x)"
ck "update-port missing (rc)"        "1"        "$(rc_of "${SM}" update-port core 99 --type node)"

# ── update-desired regenerates desired (trunk + active VLANs) ────────
"${SM}" update-desired >/dev/null 2>&1
ck "desired port is trunk"           "trunk"     "$(jq -r '.switches.core.ports["4"].mode' "${DES}")"
ck "desired tags active set"         "200,310,410,610" "$(jq -rc '.switches.core.ports["4"].taggedVlans | join(",")' "${DES}")"

# ── delta wants the VLANs tagged; apply prints manual; the OPERATOR confirms ─
ck "delta detects drift (rc)"        "2"      "$(rc_of "${SM}" reconcile)"

# A MANUAL switch is not programmed by `--apply` — the VLANs are printed for a
# human to tag. Recording them in actual.json at that moment would be a FALSE
# CONFIRM: the drift would vanish from `delta` and the controller would report
# in-sync while the hardware still carries the old VLANs. So `--apply`:
#   - returns rc 2 (needs-manual, the five-verb provider contract — network-manager
#     planes.ts classify() maps it to "needs-manual"), and
#   - leaves actual.json untouched.
# These three assertions previously pinned the opposite (rc 0 + confirmed), which
# is how the defect survived: the test asserted the bug.
ck "reconcile --apply rc 2 (needs-manual)" "2" "$(rc_of "${SM}" reconcile --apply)"
ck "reconcile --apply left actual UNCHANGED (no false confirm)" "" \
   "$(jq -rc '.switches.core.ports["4"].taggedVlans // [] | join(",")' "${ACT}")"
ck "still drifting until a human confirms (rc)" "2" "$(rc_of "${SM}" reconcile)"

# The operator tags the VLANs by hand, then records it.
"${SM}" confirm core >/dev/null 2>&1
ck "operator confirm records the applied config" "200,310,410,610" \
   "$(jq -rc '.switches.core.ports["4"].taggedVlans // [] | join(",")' "${ACT}")"
ck "after operator confirm, in sync (rc)" "0" "$(rc_of "${SM}" reconcile)"
# standalone confirm still works (re-records desired→actual; idempotent).
ck "standalone confirm rc 0"         "0"      "$(rc_of "${SM}" confirm)"

# ── added/removed ports flow through the regenerated desired ─────────
"${SM}" add-port core 6 --type node --target tappaas3 >/dev/null 2>&1
"${SM}" update-desired >/dev/null 2>&1
ck "added port shows in delta (rc)"  "2"      "$(rc_of "${SM}" reconcile)"
out="$("${SM}" remove-port core 6 2>&1)"
ck "remove-port on a manual switch prints the park step" "yes" "$(has "${out}" 'park in iotLocal')"
ck "…and records the port parked (#853)" "true iotLocal null" "$(jq -r '.switches.core.ports["6"] | "\(.parked) \(.zone) \(.type // null)"' "${ACT}")"
ck "…drifting until a human confirms (rc)" "2" "$(rc_of "${SM}" reconcile)"
"${SM}" confirm core >/dev/null 2>&1
ck "removed port, confirmed parked → back in sync (rc)" "0" "$(rc_of "${SM}" reconcile)"

# ── access port: device + zone → nativeVlan derived from zones ───────
"${SM}" add-port core 10 --type device --target printer --zone home >/dev/null 2>&1
ck "device port mode access"         "access" "$(jq -r '.switches.core.ports["10"].mode' "${ACT}")"
"${SM}" update-desired >/dev/null 2>&1
ck "device desired nativeVlan=zone"  "310"    "$(jq -r '.switches.core.ports["10"].nativeVlan' "${DES}")"

# AP-uplink port → desired trunk carrying the full active set (UniFi auto-manages
# AP ports as "all VLANs", so AP ports match node/trunk rather than a subset).
"${SM}" add-port core 11 --type ap --target nano-ap >/dev/null 2>&1
"${SM}" update-desired >/dev/null 2>&1
ck "ap port desired trunk"           "trunk"  "$(jq -r '.switches.core.ports["11"].mode' "${DES}")"
ck "ap port carries active VLANs"    "200,310,410,610" "$(jq -rc '.switches.core.ports["11"].taggedVlans|join(",")' "${DES}")"

# list-ports: one line per port, actual + drift (read-only, computed on the fly)
lp="$("${SM}" list-ports core 2>&1)"
ck "list-ports: node port 4 in sync"  "yes" "$(grep -qE 'port 4: node .*\| in sync' <<<"${lp}" && echo yes || echo no)"
ck "list-ports: ap port 11 drift"     "yes" "$(grep -qE 'port 11: ap .*DRIFT' <<<"${lp}" && echo yes || echo no)"
ck "list-ports: unknown switch (rc)"  "1"   "$(rc_of "${SM}" list-ports nope)"
lj="$("${SM}" list-ports core --json 2>/dev/null)"
ck "list-ports --json: node port 4 in sync" "in-sync" "$(jq -r '.[0].ports[] | select(.port=="4") | .drift' <<<"${lj}")"
ck "list-ports --json: ap port 11 drift adds" "200,310,410,610" "$(jq -r '.[0].ports[] | select(.port=="11") | .add | join(",")' <<<"${lj}")"
ck "list-ports --json: device port wants its zone" "310" "$(jq -r '.[0].ports[] | select(.port=="10") | .desired.nativeVlan' <<<"${lj}")"
ck "list-ports --json: one line per port as the text" "$(grep -c '^  port ' <<<"${lp}")" "$(jq '.[0].ports | length' <<<"${lj}")"
ck "list-ports --json: neighbors, empty when none reported" "0" "$(jq -r '.[0].ports[] | select(.port=="4") | .neighbors | length' <<<"${lj}")"
ck "list-ports --json before the switch (rc)" "0" "$(rc_of "${SM}" list-ports --json core)"

# ── controller inventory + graceful interrogate skip (no plugin hook) ─
"${SM}" add-controller ctrl1 --vendor unifi --ip https://unifi >/dev/null 2>&1
ck "add-controller recorded"         "unifi"  "$(jq -r '.controllers.ctrl1.vendor' "${ACT}")"
ck "add-controller dup (rc)"         "1"      "$(rc_of "${SM}" add-controller ctrl1 --vendor x --ip y)"
ck "add-switch bad controller (rc)"  "1"      "$(rc_of "${SM}" add-switch s9 --vendor unifi --managed auto --controller nope)"

# ── managed:manual forces the manual controller even for a brand WITH one ──
"${SM}" add-switch usw --vendor unifi --managed manual >/dev/null 2>&1
"${SM}" add-port usw 1 --type node --target tappaas1 >/dev/null 2>&1
"${SM}" update-desired >/dev/null 2>&1
apply_out="$("${SM}" apply 2>&1)"
ck "unifi+manual uses manual"         "yes"    "$(grep -q 'MANUAL CONFIGURATION' <<<"${apply_out}" && echo yes || echo no)"

# ── controller interrogate MERGES (preserves operator annotations) ──
# Regression: a re-interrogate must not wipe a port's type/target set by update-port.
STUBDIR="${TMP}/plugins"; mkdir -p "${STUBDIR}"
cat > "${STUBDIR}/stub.sh" <<'EOF'
plugin_supports() { [[ "$1" == "stub" ]]; }
plugin_arch() { echo controller; }
plugin_controller_interrogate() { echo '{"switches":{"StubSw":{"vendor":"stub","model":"S1","managementIp":"1.2.3.4","ports":{"1":{"mode":"trunk","taggedVlans":[],"source":"discovered"},"3":{"mode":"trunk","taggedVlans":[],"source":"discovered"}}}},"aps":{}}'; }
EOF
PLUGIN_DIR="${STUBDIR}" "${SM}" add-controller cstub --vendor stub --ip 1.2.3.4 >/dev/null 2>&1
PLUGIN_DIR="${STUBDIR}" "${SM}" interrogate >/dev/null 2>&1
"${SM}" update-port StubSw 3 --type node --target tappaas3 >/dev/null 2>&1
PLUGIN_DIR="${STUBDIR}" "${SM}" interrogate >/dev/null 2>&1   # re-interrogate
ck "re-interrogate keeps port type"  "node"   "$(jq -r '.switches.StubSw.ports["3"].type' "${ACT}")"
ck "re-interrogate keeps target"     "tappaas3" "$(jq -r '.switches.StubSw.ports["3"].target' "${ACT}")"
"${SM}" update-desired >/dev/null 2>&1
ck "annotated port → active VLANs"   "200,310,410,610" "$(jq -rc '.switches.StubSw.ports["3"].taggedVlans|join(",")' "${DES}")"
ck "un-annotated port stays bare"    ""       "$(jq -rc '.switches.StubSw.ports["1"].type // ""' "${DES}")"
# A non-JSON controller response (e.g. HTTP 429): leave actual as-is, and SAY so
# with rc 1 — a read that failed used to exit 0 (#733).
cat > "${STUBDIR}/stub.sh" <<'EOF'
plugin_supports() { [[ "$1" == "stub" ]]; }
plugin_arch() { echo controller; }
plugin_controller_interrogate() { echo '<html>429 Too Many Requests</html>'; }
EOF
ck "a bad response fails interrogate (rc)" "1" "$(PLUGIN_DIR="${STUBDIR}" rc_of "${SM}" interrogate)"
ck "bad response leaves switch intact" "node" "$(jq -r '.switches.StubSw.ports["3"].type' "${ACT}")"
# The plugin's own reason (its stderr) reaches the operator instead of a
# generic 'unreachable or rate-limited?' (#733).
cat > "${STUBDIR}/stub.sh" <<'EOF'
plugin_supports() { [[ "$1" == "stub" ]]; }
plugin_arch() { echo controller; }
plugin_controller_interrogate() { echo "UniFi login failed: HTTP 401 — check the LOCAL admin" >&2; echo '{}'; return 1; }
EOF
out="$(PLUGIN_DIR="${STUBDIR}" "${SM}" interrogate 2>&1)"
ck "the plugin's reason is shown"      "yes" "$(has "${out}" 'HTTP 401 — check the LOCAL admin')"
ck "…and no generic guess"             "no"  "$(has "${out}" 'unreachable or rate-limited')"
ck "a failed plugin (rc 1) fails interrogate" "1" "$(PLUGIN_DIR="${STUBDIR}" rc_of "${SM}" interrogate)"
before="$(md5sum < "${ACT}")"
ck "reconcile --apply on stale actual (rc)" "1" "$(PLUGIN_DIR="${STUBDIR}" rc_of "${SM}" reconcile --apply)"
ck "…applies nothing"                  "${before}" "$(md5sum < "${ACT}")"
ck "…and says why" "yes" "$(has "$(PLUGIN_DIR="${STUBDIR}" "${SM}" reconcile --apply 2>&1)" 'nothing applied')"
# One vendor login per run: every device's plugin subshell sees the same session dir.
cat > "${STUBDIR}/stub.sh" <<'EOF'
plugin_supports() { [[ "$1" == "stub" ]]; }
plugin_arch() { echo controller; }
plugin_controller_interrogate() { [[ -d "${UNIFI_SESSION:-}" ]] || return 1; echo '{}'; }
EOF
ck "the run's session reaches the plugin" "0" "$(PLUGIN_DIR="${STUBDIR}" rc_of "${SM}" interrogate)"
"${SM}" remove-switch StubSw >/dev/null 2>&1; "${SM}" remove-controller cstub >/dev/null 2>&1

# ── lag: a link aggregate across two node ports (#40) ───────────────
"${SM}" add-port core 11 --type node --target tappaas1 --target-port nic3 >/dev/null 2>&1
"${SM}" add-port core 12 --type node --target tappaas1 --target-port nic2 >/dev/null 2>&1
ck "lag set needs two ports (rc)"    "1"      "$(rc_of "${SM}" lag set core t1-lan --ports 11)"
ck "lag set refuses an unregistered port (rc)" "1" "$(rc_of "${SM}" lag set core t1-lan --ports 11,13)"
"${SM}" lag set core t1-lan --ports 12,11 >/dev/null 2>&1
ck "lag set marks both ports"        "t1-lan,t1-lan" "$(jq -r '[.switches.core.ports["11","12"].lag] | join(",")' "${ACT}")"
"${SM}" update-desired >/dev/null 2>&1
ck "the lowest port leads the LAG"   "11,12"  "$(jq -r '.switches.core.ports["11"].lagMembers | join(",")' "${DES}")"
ck "the other member lists none"     "0"      "$(jq -r '.switches.core.ports["12"].lagMembers | length' "${DES}")"
ck "an unmanaged port gets no lagMembers" "null" "$(jq -r '.switches.core.ports["99"].lagMembers // "null"' "${DES}")"
ck "delta: the aggregate to form" "yes" "$(has "$("${SM}" delta 2>&1)" 'ports 11+12 as one LACP aggregate')"
ck "lag list shows it, not formed"   "yes"    "$(has "$("${SM}" lag list core 2>&1)" 'LAG t1-lan: ports 11+12  (live: not formed)')"
ck "lag list --json: not formed"     "t1-lan 11+12 false" "$("${SM}" lag list core --json | jq -r '.[0] | "\(.name) \(.ports | join("+")) \(.formed)"')"
"${SM}" confirm core >/dev/null 2>&1
ck "confirm records the live members" "11,12" "$(jq -r '.switches.core.ports["11"].lagMembers | join(",")' "${ACT}")"
ck "…and the aggregate is in sync"   "no"     "$(has "$("${SM}" delta 2>&1)" 'aggregate')"
ck "lag list --json: formed, live members" "true 11,12" "$("${SM}" lag list --json | jq -r '.[0] | "\(.formed) \(.live | join(","))"')"
ck "a port in another LAG is refused (rc)" "1" "$(rc_of "${SM}" lag set core other --ports 11,12)"
# #854: the member follows its lead — UniFi takes an aggregate's VLANs from the
# lead, so the member's own (stale) VLANs are neither drift nor pushed.
ck "lag set records the member's lead"   "11"     "$(jq -r '.switches.core.ports["12"].lagLead' "${ACT}")"
ck "…and the lead follows nothing"       "null"   "$(jq -r '.switches.core.ports["11"].lagLead // "null"' "${ACT}")"
jq '.switches.core.ports["12"].taggedVlans = [100,200,298,310,610]' "${ACT}" > "${ACT}.t" && mv "${ACT}.t" "${ACT}"
"${SM}" update-desired >/dev/null 2>&1
ck "desired: the member has no VLAN set of its own" "null null" "$(jq -r '.switches.core.ports["12"] | "\(.taggedVlans // "null") \(.mode // "null")"' "${DES}")"
ck "delta: nothing for the member"       "no"     "$(has "$("${SM}" delta 2>&1)" 'port 12')"
lj="$("${SM}" list-ports core --json 2>/dev/null)"
ck "list-ports --json: the member is in sync" "in-sync" "$(jq -r '.[0].ports[] | select(.port=="12") | .drift' <<<"${lj}")"
ck "…shows the lead's VLANs"             "200,310,410,610" "$(jq -r '.[0].ports[] | select(.port=="12") | .taggedVlans | join(",")' <<<"${lj}")"
ck "…and names its lead"                 "11"     "$(jq -r '.[0].ports[] | select(.port=="12") | .lagLead' <<<"${lj}")"
ck "list-ports: the member follows port 11" "yes" "$(grep -qE 'port 12: node .*\| follows port 11' <<<"$("${SM}" list-ports core 2>&1)" && echo yes || echo no)"
"${SM}" confirm core >/dev/null 2>&1
ck "confirm keeps the member's live VLANs as read" "100,200,298,310,610" "$(jq -r '.switches.core.ports["12"].taggedVlans | join(",")' "${ACT}")"
ck "…and core is in sync"               "yes"    "$(has "$("${SM}" delta 2>&1)" 'core: in sync')"
"${SM}" lag remove core t1-lan >/dev/null 2>&1
ck "lag remove clears the ports"     "0"      "$(jq -r '[.switches.core.ports[] | select(.lag)] | length' "${ACT}")"
ck "…and the member's lead"         "0"      "$(jq -r '[.switches.core.ports[] | select(.lagLead)] | length' "${ACT}")"
"${SM}" update-desired >/dev/null 2>&1
ck "delta: the aggregate to take apart" "yes" "$(has "$("${SM}" delta 2>&1)" 'take apart the aggregate of ports 11+12')"
ck "manual switch: lag --apply prints the step, rc 2" "2" "$(rc_of "${SM}" lag remove core t1-lan --apply)"
"${SM}" confirm core >/dev/null 2>&1
"${SM}" remove-port core 11 >/dev/null 2>&1; "${SM}" remove-port core 12 >/dev/null 2>&1

# ── parking (#853): a port TAPPaaS does not use is an iotLocal access port ──
# The stub controller reports PSw: 1 and 4 free (no link), 2 and 7 with a link,
# 3 disabled, 5+6 an aggregate nobody declared. Its apply records what it was
# given (the desired file it read and the changes) and answers STUB_APPLY_RC.
cat > "${STUBDIR}/stub.sh" <<'EOF'
plugin_supports() { [[ "$1" == "stub" ]]; }
plugin_arch() { echo controller; }
plugin_controller_interrogate() { cat <<'J'
{"switches":{"PSw":{"vendor":"stub","model":"S2","managementIp":"1.2.3.5","ports":{
 "1":{"mode":"trunk","nativeVlan":0,"taggedVlans":[200,310],"link":"down","lagMembers":[]},
 "2":{"mode":"trunk","nativeVlan":0,"taggedVlans":[200,310],"link":"up","lagMembers":[]},
 "3":{"mode":"access","nativeVlan":0,"disabled":true,"link":"down","lagMembers":[]},
 "4":{"mode":"trunk","nativeVlan":430,"taggedVlans":[200],"link":"down","lagMembers":[]},
 "5":{"mode":"trunk","nativeVlan":0,"taggedVlans":[200],"link":"down","lagMembers":[5,6]},
 "6":{"mode":"trunk","nativeVlan":0,"taggedVlans":[200],"link":"down","lagMembers":[]},
 "7":{"mode":"trunk","nativeVlan":0,"taggedVlans":[200],"link":"up","lagMembers":[]}}}},"aps":{}}
J
}
plugin_apply() { cp "${SWITCH_DESIRED:-${CONFIG_DIR}/switch-configuration-desired.json}" "${CONFIG_DIR}/applied.json"; printf '%s' "$2" > "${CONFIG_DIR}/changes.json"; return "${STUB_APPLY_RC:-0}"; }
EOF
PLUGIN_DIR="${STUBDIR}" "${SM}" add-controller cpark --vendor stub --ip 1.2.3.5 >/dev/null 2>&1
# interrogate --no-park (#860): the post-sweep read records the switch and parks nothing.
out="$(PLUGIN_DIR="${STUBDIR}" "${SM}" interrogate --no-park 2>&1)"; rc=$?
ck "interrogate --no-park (rc)"           "0"      "${rc}"
ck "…reads the switch"                    "7"      "$(jq -r '.switches.PSw.ports | length' "${ACT}")"
ck "…parks nothing"                       ""       "$(jq -r '[.switches.PSw.ports | to_entries[] | select(.value.parked) | .key] | join(",")' "${ACT}")"
ck "…and says nothing of parking"         "no"     "$(has "${out}" 'parked port(s)')"
ck "…records when it read the switch"     "yes"    "$(jq -r '.switches.PSw.lastRead // "" | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' "${ACT}" | sed 's/true/yes/; s/false/no/')"
ck "list-ports --json carries lastRead"   "yes"    "$("${SM}" list-ports PSw --json | jq -r 'if .[0].lastRead then "yes" else "no" end')"
ck "--no-park elsewhere refused (rc)"     "1"      "$(rc_of "${SM}" delta --no-park)"
out="$(PLUGIN_DIR="${STUBDIR}" "${SM}" interrogate 2>&1)"
ck "interrogate parks the free ports"     "1,4"    "$(jq -r '[.switches.PSw.ports | to_entries[] | select(.value.parked) | .key] | join(",")' "${ACT}")"
ck "…in iotLocal"                         "iotLocal" "$(jq -r '.switches.PSw.ports["1"].zone' "${ACT}")"
ck "…and says so"                         "yes"    "$(has "${out}" 'parked port(s) 1, 4 in iotLocal')"
ck "a port with a link is left, and named" "yes"   "$(has "${out}" 'port(s) 2, 7 have no record and a link')"
ck "a disabled port is left"              "null"   "$(jq -r '.switches.PSw.ports["3"].parked // null' "${ACT}")"
ck "an aggregate nobody declared is left"  "null null" "$(jq -r '.switches.PSw.ports | "\(.["5"].parked // null) \(.["6"].parked // null)"' "${ACT}")"
ck "a parked record is not a device record" "null" "$(jq -r '.switches.PSw.ports["1"].type // null' "${ACT}")"
"${SM}" update-desired >/dev/null 2>&1
ck "desired: a parked port is an iotLocal access port" "access 410" "$(jq -r '.switches.PSw.ports["1"] | "\(.mode) \(.nativeVlan)"' "${DES}")"
ck "delta: the park to push"              "yes"    "$(has "$("${SM}" delta 2>&1)" 'park: port 1 parked in iotLocal: trunk native 0 -> access VLAN 410')"
ck "delta: a trunk already native 430 is parked too" "yes" "$(has "$("${SM}" delta 2>&1)" 'port 4 parked in iotLocal: trunk native 430')"
ck "delta: nothing for a port left alone"  "no"    "$(has "$("${SM}" delta 2>&1)" 'port 2 ')"
lp="$("${SM}" list-ports PSw 2>&1)"
ck "list-ports: parked"                   "yes"    "$(grep -qE 'port 1: parked \(iotLocal\) .*DRIFT trunk native 0 -> access vlan 410' <<<"${lp}" && echo yes || echo no)"
ck "list-ports: an unrecorded port with a link" "yes" "$(grep -qE 'port 2: — .*untouched \(unmanaged, link up\)' <<<"${lp}" && echo yes || echo no)"
lj="$("${SM}" list-ports PSw --json 2>/dev/null)"
ck "list-ports --json: parked, drifting"  "true drift 410" "$(jq -r '.[0].ports[] | select(.port=="1") | "\(.parked) \(.drift) \(.desired.nativeVlan)"' <<<"${lj}")"
ck "list-ports --json: link and disabled"  "up false true" "$(jq -r '.[0].ports | "\(map(select(.port=="2"))[0].link) \(map(select(.port=="2"))[0].disabled) \(map(select(.port=="3"))[0].disabled)"' <<<"${lj}")"
PLUGIN_DIR="${STUBDIR}" "${SM}" apply >/dev/null 2>&1
ck "apply pushes the parked ports"        "access 410" "$(jq -r '.switches.PSw.ports["4"] | "\(.mode) \(.nativeVlan)"' "${TMP}/applied.json")"
"${SM}" confirm PSw >/dev/null 2>&1
ck "confirm records them parked and in sync" "in-sync in-sync" "$("${SM}" list-ports PSw --json | jq -r '.[0].ports | "\(map(select(.port=="1"))[0].drift) \(map(select(.port=="4"))[0].drift)"')"
ck "a re-interrogate keeps the parked record" "true" "$(PLUGIN_DIR="${STUBDIR}" "${SM}" interrogate >/dev/null 2>&1; jq -r '.switches.PSw.ports["1"].parked' "${ACT}")"
# update-port --park: the switch first, only this port, then the record.
rm -f "${TMP}/applied.json"
out="$(PLUGIN_DIR="${STUBDIR}" "${SM}" update-port PSw 2 --park 2>&1)"; rc=$?
ck "update-port --park (rc)"              "0"      "${rc}"
ck "…pushes only that port"               "2"      "$(jq -r '.switches.PSw.ports | keys | join(",")' "${TMP}/applied.json")"
ck "…as an iotLocal access port"          "true access 410" "$(jq -r '.switches.PSw.ports["2"] | "\(.parked) \(.mode) \(.nativeVlan)"' "${TMP}/applied.json")"
ck "…then records it parked, as set"      "true iotLocal access 410 up" "$(jq -r '.switches.PSw.ports["2"] | "\(.parked) \(.zone) \(.mode) \(.nativeVlan) \(.link)"' "${ACT}")"
ck "…named in the change"                 "park"   "$(jq -r '.changes[0].action' "${TMP}/changes.json")"
ck "update-port --park with other flags refused (rc)" "1" "$(rc_of "${SM}" update-port PSw 7 --park --type node)"
ck "add-port --park refused (rc)"         "1"      "$(rc_of "${SM}" add-port PSw 7 --park)"
before="$(md5sum < "${ACT}")"
ck "a switch that refuses the park (rc)"  "1"      "$(STUB_APPLY_RC=1 PLUGIN_DIR="${STUBDIR}" rc_of "${SM}" update-port PSw 7 --park)"
ck "…leaves the record unchanged"         "${before}" "$(md5sum < "${ACT}")"
ck "no such park zone (rc)"               "1"      "$(PLUGIN_DIR="${STUBDIR}" rc_of "${SM}" update-port PSw 7 --park --park-zone nope)"
ck "…says what to do"                     "yes"    "$(has "$(PLUGIN_DIR="${STUBDIR}" "${SM}" update-port PSw 7 --park --park-zone nope 2>&1)" "no zone 'nope' to park ports in")"
PLUGIN_DIR="${STUBDIR}" "${SM}" update-port PSw 7 --park --park-zone home >/dev/null 2>&1
ck "--park-zone parks elsewhere"          "home 310" "$(jq -r '.switches.PSw.ports["7"] | "\(.zone) \(.nativeVlan)"' "${ACT}")"
ck "a member of a live aggregate is not parked (rc)" "1" "$(PLUGIN_DIR="${STUBDIR}" rc_of "${SM}" update-port PSw 6 --park)"
# A parked port taken into use, and given back.
"${SM}" add-port PSw 4 --type device --target printer --zone home >/dev/null 2>&1
ck "add-port takes a parked port into use" "device home null" "$(jq -r '.switches.PSw.ports["4"] | "\(.type) \(.zone) \(.parked // null)"' "${ACT}")"
"${SM}" update-port PSw 1 --type node --target tappaas9 >/dev/null 2>&1
ck "update-port --type unparks, drops the park zone" "node null null" "$(jq -r '.switches.PSw.ports["1"] | "\(.type) \(.zone // null) \(.parked // null)"' "${ACT}")"
PLUGIN_DIR="${STUBDIR}" "${SM}" remove-port PSw 4 >/dev/null 2>&1
ck "remove-port parks it on the switch"   "4 access 410" "$(jq -r '.switches.PSw.ports | "\(keys | join(",")) \(.["4"].mode) \(.["4"].nativeVlan)"' "${TMP}/applied.json")"
ck "…and its record is parked, not removed" "true null null" "$(jq -r '.switches.PSw.ports["4"] | "\(.parked) \(.type // null) \(.target // null)"' "${ACT}")"
# No park zone: interrogate refuses the parking (rc 1), reconcile still runs.
jq 'del(.switches.PSw.ports["1"])' "${ACT}" > "${ACT}.t" && mv "${ACT}.t" "${ACT}"
out="$(PLUGIN_DIR="${STUBDIR}" "${SM}" interrogate --park-zone nope 2>&1)"; rc=$?
ck "interrogate without a park zone (rc)" "1"      "${rc}"
ck "…says so, and parks nothing"          "yes null" "$(has "${out}" "no zone 'nope'") $(jq -r '.switches.PSw.ports["1"].parked // null' "${ACT}")"
ck "…reconcile is not refused for it"     "2"      "$(PLUGIN_DIR="${STUBDIR}" rc_of "${SM}" reconcile --park-zone nope)"
"${SM}" remove-switch PSw >/dev/null 2>&1; "${SM}" remove-controller cpark >/dev/null 2>&1

# ── list / show / remove / guards ───────────────────────────────────
ck "show switch"                     "tplink" "$("${SM}" show core | jq -r '.vendor')"
ck "show controller"                 "unifi"  "$("${SM}" show ctrl1 | jq -r '.vendor')"
ck "show missing (rc)"               "1"      "$(rc_of "${SM}" show nope)"
ck "list --json: the switch"         "core manual" "$("${SM}" list --json | jq -r '.switches[0] | "\(.name) \(.managed)"')"
ck "list --json: the controller"     "ctrl1"  "$("${SM}" list --json | jq -r '.controllers[0].name')"
ck "--json refused where it means nothing (rc)" "1" "$(rc_of "${SM}" delta --json)"

# #644: --help in any position runs nothing; an option the verb lacks is refused
before="$(md5sum < "${ACT}")$(md5sum < "${DES}")"
ck "remove-switch <s> --help (rc)"   "0"      "$(rc_of "${SM}" remove-switch core --help)"
ck "confirm <s> -h (rc)"             "0"      "$(rc_of "${SM}" confirm core -h)"
ck "reconcile --apply --help (rc)"   "0"      "$(rc_of "${SM}" reconcile --apply --help)"
ck "add-switch --help --vendor x (rc)" "0"    "$(rc_of "${SM}" add-switch --help --vendor x --managed manual)"
ck "…and nothing changed"            "${before}" "$(md5sum < "${ACT}")$(md5sum < "${DES}")"
ck "add-port --help prints add-port's usage" "yes" "$(grep -q -- '--target-port' <<<"$("${SM}" add-port --help)" && echo yes || echo no)"
ck "reconcile --aply refused (rc)"   "1"      "$(rc_of "${SM}" reconcile --aply)"
ck "remove-switch <s> --force refused (rc)" "1" "$(rc_of "${SM}" remove-switch core --force)"
ck "…and nothing changed"            "${before}" "$(md5sum < "${ACT}")$(md5sum < "${DES}")"
ck "--help works without zones.json" "0"      "$(CONFIG_DIR=/nonexistent rc_of "${SM}" interrogate --help)"

"${SM}" remove-switch core >/dev/null 2>&1
ck "remove-switch deletes"           "false"  "$(jq -e '.switches | has("core")' "${ACT}")"
"${SM}" remove-controller ctrl1 >/dev/null 2>&1
ck "remove-controller deletes"       "false"  "$(jq -e '.controllers | has("ctrl1")' "${ACT}")"
ck "--help (rc)"                     "0"      "$(rc_of "${SM}" --help)"
ck "unknown command (rc)"            "1"      "$(rc_of "${SM}" bogus)"

ck "add-port with a zone zones.json lacks is refused (rc)" "1" "$(rc_of "${SM}" add-port usw 22 --type device --zone nosuchzone)"
ck "…naming the zones there are" "yes" "$(has "$("${SM}" add-port usw 22 --type device --zone nosuchzone 2>&1)" "no zone 'nosuchzone' in zones.json")"

# ── A trunk's native VLAN is declared (or 0), not what the switch has (#847) ──
# A port taken out of parking into a trunk kept the park's VLAN as its native,
# and interrogate's live value was copied into desired: it never converged.
"${SM}" add-switch nsw --vendor tplink --managed manual >/dev/null 2>&1
"${SM}" add-port nsw 1 --type device --zone home >/dev/null 2>&1
jq '.switches.nsw.ports["1"] = {parked: true, zone: "iotLocal", mode: "access", nativeVlan: 410, source: "discovered"}' "${ACT}" > "${ACT}.t" && mv "${ACT}.t" "${ACT}"
"${SM}" update-port nsw 1 --type switch --target other >/dev/null 2>&1
ck "unparked into a trunk: the park's VLAN is dropped" "null" "$(jq -r '.switches.nsw.ports["1"].nativeVlan' "${ACT}")"
jq '.switches.nsw.ports["1"].nativeVlan = 410' "${ACT}" > "${ACT}.t" && mv "${ACT}.t" "${ACT}"   # what the switch reports
"${SM}" update-desired >/dev/null 2>&1
ck "a trunk wants native 0, whatever the switch has" "0" "$(jq -r '.switches.nsw.ports["1"].nativeVlan' "${DES}")"
ck "…and the delta says so" "yes" "$(has "$("${SM}" delta 2>&1)" 'native 410 -> 0')"
ck "…and list-ports calls it drift" "drift" "$("${SM}" list-ports nsw --json 2>/dev/null | jq -r '.[0].ports[] | select(.port == "1") | .drift')"
"${SM}" update-port nsw 1 --native 300 >/dev/null 2>&1
jq '.switches.nsw.ports["1"].nativeVlan = 410' "${ACT}" > "${ACT}.t" && mv "${ACT}.t" "${ACT}"
"${SM}" update-desired >/dev/null 2>&1
ck "a declared native survives the switch's value" "300" "$(jq -r '.switches.nsw.ports["1"].nativeVlan' "${DES}")"
"${SM}" remove-switch nsw >/dev/null 2>&1

# ── MikroTik-style port ids and MLAG pairs (#847) ───────────────────
# Port ids are opaque ("ether2"): ordered naturally, never read as numbers.
# A stub device controller with the mlag capability stands in for MikroTik.
MT="${TMP}/mt"; mkdir -p "${MT}"
cat > "${MT}/mtk.sh" <<'EOF'
plugin_supports() { [[ "$1" == "mtk" ]]; }
plugin_vendors() { echo mtk; }
plugin_arch() { echo device; }
plugin_capabilities() { printf 'vlans\nlag\npark\nmlag\n'; }
plugin_mlag_status() { echo "{\"switch\":\"$1\",\"configured\":true,\"peerPort\":\"sfp16\",\"peerLink\":\"up\",\"state\":\"connected\"}"; }
plugin_apply() { echo "$1 $2" >> "${CONFIG_DIR}/mt-applied.log"; return 0; }
EOF
"${SM}" add-switch mtA --vendor mtk --managed auto --ip 10.9.0.1 >/dev/null 2>&1
"${SM}" add-switch mtB --vendor mtk --managed auto --ip 10.9.0.2 >/dev/null 2>&1
for pt in ether10 ether2; do "${SM}" add-port mtA "${pt}" --type node --target n9 --target-port "eth-${pt}" >/dev/null 2>&1; done
"${SM}" add-port mtB ether2 --type node --target n9 --target-port eth-b >/dev/null 2>&1
ck "ports named ether2, ether10 list in natural order" "ether2 ether10" \
   "$(PLUGIN_DIR="${MT}" "${SM}" list-ports mtA --json 2>/dev/null | jq -r '.[0].ports | map(.port) | join(" ")')"
ck "mlag-pair: a switch whose controller cannot do MLAG is refused (rc)" "1" "$(PLUGIN_DIR="${MT}" rc_of "${SM}" mlag-pair set mtA usw)"
PLUGIN_DIR="${MT}" "${SM}" mlag-pair set mtA mtB --peer-port sfp16 >/dev/null 2>&1; rc=$?
ck "mlag-pair set (rc)" "0" "${rc}"
ck "…recorded with its peer link" '["mtA","mtB"] sfp16' "$(jq -c '.mlagPairs["mtA+mtB"].switches' "${ACT}") $(jq -r '.mlagPairs["mtA+mtB"].peerPort.mtB' "${ACT}")"
ck "lag set across a pair needs a member on each switch (rc)" "1" "$(PLUGIN_DIR="${MT}" rc_of "${SM}" lag set mtA n9-lan --ports mtA:ether2,mtA:ether10)"
ck "lag set across a pair: only its switches (rc)" "1" "$(PLUGIN_DIR="${MT}" rc_of "${SM}" lag set mtA n9-lan --ports mtA:ether2,usw:1)"
PLUGIN_DIR="${MT}" "${SM}" lag set mtA n9-lan --ports mtA:ether2,mtB:ether2 >/dev/null 2>&1; rc=$?
ck "lag set across the pair (rc)" "0" "${rc}"
ck "…the same LAG and mlag-id on both switches" "n9-lan 10 n9-lan 10" \
   "$(jq -r '"\(.switches.mtA.ports.ether2.lag) \(.switches.mtA.ports.ether2.mlagId) \(.switches.mtB.ports.ether2.lag) \(.switches.mtB.ports.ether2.mlagId)"' "${ACT}")"
ck "…a port of the switch not named stays out of it" "null" "$(jq -r '.switches.mtA.ports.ether10.lag' "${ACT}")"
PLUGIN_DIR="${MT}" "${SM}" update-desired >/dev/null 2>&1
ck "desired: each side's lead lists its one member, with the mlag-id" '["ether2"] 10' \
   "$(jq -c '.switches.mtB.ports.ether2.lagMembers' "${DES}") $(jq -r '.switches.mtB.ports.ether2.mlagId' "${DES}")"
ck "delta: the aggregate is to form on both switches" "2" \
   "$(PLUGIN_DIR="${MT}" "${SM}" delta 2>&1 | grep -c 'one LACP aggregate (LAG n9-lan)')"
jq '.switches.mtB.ports.ether2.liveMlagId = 11 | .switches.mtB.ports.ether2.lagMembers = ["ether2"]' "${ACT}" > "${ACT}.t" && mv "${ACT}.t" "${ACT}"
out="$(PLUGIN_DIR="${MT}" "${SM}" mlag-pair list --json 2>/dev/null)"
ck "mlag-pair list: the live state of each peer" "connected" "$(jq -r '.[0].status.mtA.state' <<<"${out}")"
ck "…and an mlag-id the switch has otherwise" "yes" "$(jq -r '.[0].lags[0].problems | join(";")' <<<"${out}" | grep -c 'mtB:ether2 has mlag-id 11' >/dev/null && echo yes || echo no)"
jq '.switches.mtA.mlag = {heartbeat: "none", stpPriority: "0x4000"} | .switches.mtB.mlag = {heartbeat: "5s", stpPriority: "0x5000"}' "${ACT}" > "${ACT}.t" && mv "${ACT}.t" "${ACT}"
out="$(PLUGIN_DIR="${MT}" "${SM}" mlag-pair list --json 2>/dev/null)"
ck "mlag-pair list: a peer without the heartbeat" "yes" "$(jq -r '.[0].problems | join(";")' <<<"${out}" | grep -c 'mtA: the MLAG heartbeat is off' >/dev/null && echo yes || echo no)"
ck "…and peers whose STP priorities differ" "yes" "$(jq -r '.[0].problems | join(";")' <<<"${out}" | grep -c 'different STP priorities (0x4000, 0x5000)' >/dev/null && echo yes || echo no)"
ck "mlag-pair remove while it carries a LAG (rc)" "1" "$(PLUGIN_DIR="${MT}" rc_of "${SM}" mlag-pair remove mtA)"
PLUGIN_DIR="${MT}" "${SM}" lag remove mtB n9-lan >/dev/null 2>&1
ck "lag remove from one side clears both" "null null" "$(jq -r '"\(.switches.mtA.ports.ether2.mlagId) \(.switches.mtB.ports.ether2.lag)"' "${ACT}")"
PLUGIN_DIR="${MT}" "${SM}" mlag-pair remove mtA >/dev/null 2>&1
ck "mlag-pair remove" "0" "$(jq '.mlagPairs | length' "${ACT}")"

echo ""
echo "test-switch-manager: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
