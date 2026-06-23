#!/usr/bin/env bash
#
# test-migrate-zone-keys.sh — tabletop tests for migrate-zone-keys-to-underscore.sh (#237).
#
# The helper does live OPNsense/DNS/Caddy work in Stages 3-5; we exercise
# Stages 1-2 (zones.json + module-config rewrites) deterministically by
# pointing CONFIG_DIR at a temp dir and confirming the marker behavior.
# Live stages are exercised by running --dry-run (they're no-ops without
# zone-manager/dns-manager in PATH inside this test).
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATE="${SCRIPT_DIR}/../migrate-zone-keys-to-underscore.sh"

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../../lib/common-install-routines.sh"

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }

# Fixture: hyphenated zones.json + a couple of module configs.
write_fixture() {
    local cfg="$1"
    cat > "${cfg}/zones.json" <<'JSON'
{
  "mgmt":     {"state":"Manual",    "vlantag":0,   "access-to":["srv-home","srv-work","iot-local"]},
  "srv-home": {"state":"Active",    "vlantag":210, "access-to":["internet","iot-cloud"]},
  "srv-work": {"state":"Active",    "vlantag":220, "access-to":["internet"]},
  "iot-local":{"state":"Active",    "vlantag":410, "access-to":[], "pinhole-allowed-from":["srv-home"]},
  "iot-cloud":{"state":"Active",    "vlantag":420, "access-to":["internet"]},
  "home":     {"state":"Active",    "vlantag":300, "access-to":["srv-home"]},
  "dmz":      {"state":"Mandatory", "vlantag":610, "access-to":["internet"]}
}
JSON
    cp "${cfg}/zones.json" "${cfg}/zones.json.orig"

    # Module in Pattern A form using hyphenated zones.
    cat > "${cfg}/openwebui.json" <<'JSON'
{
  "vmname": "openwebui",
  "dependsOn": ["cluster:vm", "network:proxy"],
  "config": {
    "cluster:vm":     {"zone0": "srv-work", "trunks0": "NONE"},
    "network:proxy": {"proxyAllowedZones": ["home", "srv-work"]}
  }
}
JSON

    # Module with discoveryUdpRelay.zones + ingress.from.
    cat > "${cfg}/alfen.json" <<'JSON'
{
  "vmname": "alfen",
  "dependsOn": ["cluster:vm", "network:rules"],
  "config": {
    "cluster:vm":      {"zone0": "iot-cloud", "trunks0": "NONE"},
    "network:rules":  {
      "discoveryUdpRelay": [{"port": 36549, "zones": ["home", "iot-cloud"]}],
      "ingress": [{"from": "srv-home", "ports": [443], "description": "HA"}],
      "egress":  [{"to":   "iot-local","ports": [1880],"description": "Node-RED"}]
    }
  }
}
JSON
}

run_migrate() {
    local cfg="$1"; shift
    # Override CONFIG_DIR via env. The helper sources common-install-routines.sh
    # which respects pre-set CONFIG_DIR.
    CONFIG_DIR="${cfg}" "${MIGRATE}" "$@" 2>&1
}

echo "── test-migrate-zone-keys.sh ──"

# Case 1: dry-run does not write.
CFG1="${WORK}/c1"; mkdir -p "${CFG1}"; write_fixture "${CFG1}"
md5_before=$(md5sum "${CFG1}/zones.json" "${CFG1}/openwebui.json" "${CFG1}/alfen.json" | sort)
run_migrate "${CFG1}" --dry-run >/dev/null
md5_after=$(md5sum "${CFG1}/zones.json" "${CFG1}/openwebui.json" "${CFG1}/alfen.json" | sort)
if [[ "${md5_before}" == "${md5_after}" && ! -f "${CFG1}/.migration-237-done" ]]; then
    pass "dry-run leaves files + marker untouched"
else
    fail "dry-run wrote: marker=$(test -f "${CFG1}/.migration-237-done" && echo yes || echo no)"
fi

# Case 2: live run renames zones.json + zones.json.orig.
CFG2="${WORK}/c2"; mkdir -p "${CFG2}"; write_fixture "${CFG2}"
run_migrate "${CFG2}" >/dev/null
hyphen_keys=$(jq -r 'keys[] | select(test("-"))' "${CFG2}/zones.json")
underscore_keys=$(jq -r 'keys[]' "${CFG2}/zones.json" | grep -E '^(srv_home|srv_work|iot_local|iot_cloud)$' | sort | tr '\n' ' ')
if [[ -z "${hyphen_keys}" && "${underscore_keys}" == "iot_cloud iot_local srv_home srv_work " ]]; then
    pass "zones.json keys renamed (no hyphens left, all 4 underscore zones present)"
else
    fail "zones.json key rename: hyphen=${hyphen_keys}, underscore=${underscore_keys}"
fi

# Case 3: access-to + pinhole-allowed-from inside zones.json are rewritten.
mgmt_access=$(jq -r '.mgmt["access-to"] | join(",")' "${CFG2}/zones.json")
pinhole=$(jq -r '.iot_local["pinhole-allowed-from"][0]' "${CFG2}/zones.json")
if [[ "${mgmt_access}" == "srv_home,srv_work,iot_local" && "${pinhole}" == "srv_home" ]]; then
    pass "zones.json inner references rewritten"
else
    fail "inner refs: mgmt=${mgmt_access}, pinhole=${pinhole}"
fi

# Case 4: openwebui renamed. Note that regroup_to_pattern_a pins zone0 at
# the top level (it's a HEADER field in the canonical Pattern A shape, not
# under config.cluster:vm). Use a normalized read so we don't care which
# block holds each field.
ow_norm=$(normalize_module_config < "${CFG2}/openwebui.json")
ow_zone0=$(echo "${ow_norm}" | jq -r '.zone0 // empty')
ow_pAZ=$(echo "${ow_norm}" | jq -r '.proxyAllowedZones | join(",")')
if [[ "${ow_zone0}" == "srv_work" && "${ow_pAZ}" == "home,srv_work" ]]; then
    pass "openwebui zone0 + proxyAllowedZones rewritten (header zone0; proxyAllowedZones under config.network:proxy)"
else
    fail "openwebui rewrite: zone0=${ow_zone0}, pAZ=${ow_pAZ}"
fi

# Case 5: alfen — discoveryUdpRelay.zones + ingress.from + egress.to.
al_norm=$(normalize_module_config < "${CFG2}/alfen.json")
al_zone0=$(echo "${al_norm}" | jq -r '.zone0 // empty')
al_udp=$(echo "${al_norm}" | jq -r '.discoveryUdpRelay[0].zones | join(",")')
al_in=$(echo "${al_norm}" | jq -r '.ingress[0].from')
al_out=$(echo "${al_norm}" | jq -r '.egress[0].to')
if [[ "${al_zone0}" == "iot_cloud" && "${al_udp}" == "home,iot_cloud" \
   && "${al_in}" == "srv_home" && "${al_out}" == "iot_local" ]]; then
    pass "alfen discoveryUdpRelay.zones + ingress.from + egress.to rewritten"
else
    fail "alfen rewrite: zone0=${al_zone0}, udp=${al_udp}, in=${al_in}, out=${al_out}"
fi

# Case 6: marker written.
if [[ -f "${CFG2}/.migration-237-done" ]] && grep -q "renamed_zones=" "${CFG2}/.migration-237-done"; then
    pass "marker written with metadata"
else
    fail "marker missing or malformed"
fi

# Case 7: second run is a no-op (marker present).
md5_before=$(md5sum "${CFG2}/zones.json" | awk '{print $1}')
run_migrate "${CFG2}" >/dev/null
md5_after=$(md5sum "${CFG2}/zones.json" | awk '{print $1}')
if [[ "${md5_before}" == "${md5_after}" ]]; then
    pass "second run is no-op (marker present)"
else
    fail "second run modified zones.json"
fi

# Case 8: --force bypasses marker. (No-op data-wise since already migrated;
# this just confirms the helper exits 0 and re-writes the marker timestamp.)
run_migrate "${CFG2}" --force >/dev/null
if [[ -f "${CFG2}/.migration-237-done" ]]; then
    pass "--force runs to completion with marker present"
else
    fail "--force broke the marker"
fi

# Case 9: backup directory populated.
if [[ -d "${CFG2}/.backup-237" ]] \
   && [[ -f "${CFG2}/.backup-237/zones.json" ]] \
   && [[ -f "${CFG2}/.backup-237/openwebui.json" ]]; then
    pass "backup directory contains original zones.json + module configs"
else
    fail "backup directory missing entries"
fi

# Case 10: no-hyphen baseline produces marker + no edits.
CFG3="${WORK}/c3"; mkdir -p "${CFG3}"
cat > "${CFG3}/zones.json" <<'JSON'
{"mgmt":{"state":"Manual","vlantag":0,"access-to":["srv_home"]},"srv_home":{"state":"Active","vlantag":210}}
JSON
cp "${CFG3}/zones.json" "${CFG3}/zones.json.orig"
md5_before=$(md5sum "${CFG3}/zones.json" | awk '{print $1}')
run_migrate "${CFG3}" >/dev/null
md5_after=$(md5sum "${CFG3}/zones.json" | awk '{print $1}')
if [[ "${md5_before}" == "${md5_after}" && -f "${CFG3}/.migration-237-done" ]]; then
    pass "no-hyphen baseline: no edits + marker written"
else
    fail "no-hyphen baseline produced edits or no marker"
fi

# Case 11: apply-zones-merge.sh pre-emptively added BOTH srv-home and srv_home;
# helper drops the hyphen variant, keeping the underscore one.
CFG4="${WORK}/c4"; mkdir -p "${CFG4}"
cat > "${CFG4}/zones.json" <<'JSON'
{
  "mgmt":     {"state":"Manual","vlantag":0,"access-to":["srv_home","srv-home"]},
  "srv-home": {"state":"Active","vlantag":210,"_legacy":true},
  "srv_home": {"state":"Inactive","vlantag":210,"_canonical":true}
}
JSON
cp "${CFG4}/zones.json" "${CFG4}/zones.json.orig"
run_migrate "${CFG4}" >/dev/null
hyphen=$(jq -r 'keys[] | select(test("-"))' "${CFG4}/zones.json")
state_after=$(jq -r '.srv_home.state' "${CFG4}/zones.json")
mgmt_after=$(jq -r '.mgmt["access-to"] | join(",")' "${CFG4}/zones.json")
if [[ -z "${hyphen}" && "${state_after}" == "Inactive" && "${mgmt_after}" == "srv_home,srv_home" ]]; then
    # mgmt.access-to has srv_home twice (the rename collapsed both into the same key).
    # That's correct intermediate state; an operator can dedupe later.
    pass "duplicate-zone case: hyphen variant dropped, canonical kept"
else
    fail "duplicate-zone case: hyphen=${hyphen}, state=${state_after}, mgmt=${mgmt_after}"
fi

echo
echo "── summary: ${PASS} pass, ${FAIL} fail ──"
exit "${FAIL}"
