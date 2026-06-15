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
  "dmz":  { "state": "Mandatory", "vlantag": 610 },
  "old":  { "state": "Inactive",  "vlantag": 999 }
}
JSON
ACT="${TMP}/switch-configuration-actual.json"
DES="${TMP}/switch-configuration-desired.json"
PASS=0; FAIL=0
ck() { local d="$1" e="$2" g="$3"; if [[ "$e" == "$g" ]]; then echo "  ok: $d"; PASS=$((PASS+1)); else echo "  FAIL: $d (expected '$e', got '$g')"; FAIL=$((FAIL+1)); fi; }
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
ck "desired tags active set"         "200,310,610" "$(jq -rc '.switches.core.ports["4"].taggedVlans | join(",")' "${DES}")"

# ── delta wants the VLANs tagged; apply prints manual; confirm syncs ─
ck "delta detects drift (rc)"        "2"      "$(rc_of "${SM}" reconcile)"
# reconcile --apply prints the manual VLANs to tag AND records the intended config
# into actual in one step (manual switches included), then reports converged.
ck "reconcile --apply rc 0"          "0"      "$(rc_of "${SM}" reconcile --apply)"
ck "reconcile --apply updated actual" "200,310,610" "$(jq -rc '.switches.core.ports["4"].taggedVlans // [] | join(",")' "${ACT}")"
ck "after apply in sync (rc)"        "0"      "$(rc_of "${SM}" reconcile)"
# standalone confirm still works (re-records desired→actual; idempotent).
ck "standalone confirm rc 0"         "0"      "$(rc_of "${SM}" confirm)"

# ── added/removed ports flow through the regenerated desired ─────────
"${SM}" add-port core 6 --type node --target tappaas3 >/dev/null 2>&1
"${SM}" update-desired >/dev/null 2>&1
ck "added port shows in delta (rc)"  "2"      "$(rc_of "${SM}" reconcile)"
"${SM}" remove-port core 6 >/dev/null 2>&1
"${SM}" update-desired >/dev/null 2>&1
ck "removed port → back in sync (rc)" "0"     "$(rc_of "${SM}" reconcile)"

# ── access port: device + zone → nativeVlan derived from zones ───────
"${SM}" add-port core 10 --type device --target printer --zone home >/dev/null 2>&1
ck "device port mode access"         "access" "$(jq -r '.switches.core.ports["10"].mode' "${ACT}")"
"${SM}" update-desired >/dev/null 2>&1
ck "device desired nativeVlan=zone"  "310"    "$(jq -r '.switches.core.ports["10"].nativeVlan' "${DES}")"

# AP-uplink port → desired trunk carrying only the WiFi VLAN set (zones with SSID).
"${SM}" add-port core 11 --type ap --target nano-ap >/dev/null 2>&1
"${SM}" update-desired >/dev/null 2>&1
ck "ap port desired trunk"           "trunk"  "$(jq -r '.switches.core.ports["11"].mode' "${DES}")"
ck "ap port carries WiFi VLANs only" "310"    "$(jq -rc '.switches.core.ports["11"].taggedVlans|join(",")' "${DES}")"

# list-ports: one line per port, actual + drift (read-only, computed on the fly)
lp="$("${SM}" list-ports core 2>&1)"
ck "list-ports: node port 4 in sync"  "yes" "$(grep -qE 'port 4: node .*\| in sync' <<<"${lp}" && echo yes || echo no)"
ck "list-ports: ap port 11 drift"     "yes" "$(grep -qE 'port 11: ap .*DRIFT' <<<"${lp}" && echo yes || echo no)"
ck "list-ports: unknown switch (rc)"  "1"   "$(rc_of "${SM}" list-ports nope)"

# ── controller inventory + graceful interrogate skip (no plugin hook) ─
"${SM}" add-controller ctrl1 --vendor unifi --ip https://unifi >/dev/null 2>&1
ck "add-controller recorded"         "unifi"  "$(jq -r '.controllers.ctrl1.vendor' "${ACT}")"
ck "add-controller dup (rc)"         "1"      "$(rc_of "${SM}" add-controller ctrl1 --vendor x --ip y)"
ck "add-switch bad controller (rc)"  "1"      "$(rc_of "${SM}" add-switch s9 --vendor unifi --managed auto --controller nope)"

# ── managed:manual forces manual.sh even for a brand WITH a plugin ───
"${SM}" add-switch usw --vendor unifi --managed manual >/dev/null 2>&1
"${SM}" add-port usw 1 --type node --target tappaas1 >/dev/null 2>&1
"${SM}" update-desired >/dev/null 2>&1
apply_out="$("${SM}" apply 2>&1)"
ck "unifi+manual uses manual.sh"     "yes"    "$(grep -q 'MANUAL CONFIGURATION' <<<"${apply_out}" && echo yes || echo no)"

# ── controller interrogate MERGES (preserves operator annotations) ──
# Regression: a re-interrogate must not wipe a port's type/target set by update-port.
STUBDIR="${TMP}/plugins"; mkdir -p "${STUBDIR}"; cp "${SCRIPT_DIR}/plugins/manual.sh" "${STUBDIR}/"
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
ck "annotated port → active VLANs"   "200,310,610" "$(jq -rc '.switches.StubSw.ports["3"].taggedVlans|join(",")' "${DES}")"
ck "un-annotated port stays bare"    ""       "$(jq -rc '.switches.StubSw.ports["1"].type // ""' "${DES}")"
"${SM}" remove-switch StubSw >/dev/null 2>&1; "${SM}" remove-controller cstub >/dev/null 2>&1

# ── list / show / remove / guards ───────────────────────────────────
ck "show switch"                     "tplink" "$("${SM}" show core | jq -r '.vendor')"
ck "show controller"                 "unifi"  "$("${SM}" show ctrl1 | jq -r '.vendor')"
ck "show missing (rc)"               "1"      "$(rc_of "${SM}" show nope)"
"${SM}" remove-switch core >/dev/null 2>&1
ck "remove-switch deletes"           "false"  "$(jq -e '.switches | has("core")' "${ACT}")"
"${SM}" remove-controller ctrl1 >/dev/null 2>&1
ck "remove-controller deletes"       "false"  "$(jq -e '.controllers | has("ctrl1")' "${ACT}")"
ck "--help (rc)"                     "0"      "$(rc_of "${SM}" --help)"
ck "unknown command (rc)"            "1"      "$(rc_of "${SM}" bogus)"

echo ""
echo "test-switch-manager: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
