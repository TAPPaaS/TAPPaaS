#!/usr/bin/env bash
#
# test-zone-state.sh — tabletop tests for the zone state verbs (#209).
#
# The legacy zone-state.sh was retired into the TS network-manager
# (`network-manager enable|disable|manual <zone> [--force]` — ADR-007 Phase
# 7.5); these cases exercise the same guarded-transition contract through the
# real CLI. Each case writes a fixture zones.json into a temp config dir,
# invokes network-manager, and asserts both the resulting state and the exit
# code (0 = changed/no-op, 1 = any error incl. bad arguments — the shared TS
# manager convention; the bash script's separate rc 2 for usage errors is gone).
#
# Requires network-manager on PATH (like the other manager tests); skips
# cleanly when it is not installed.
#

set -euo pipefail

if ! command -v network-manager >/dev/null 2>&1; then
    echo "── test-zone-state.sh ──"
    echo "  SKIP: network-manager not on PATH (install tappaas-cicd/manager/network-manager first)"
    exit 0
fi

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }

# Run network-manager against an isolated config dir (TAPPAAS_CONFIG wins over
# CONFIG_DIR in the shared config-root resolution, so set both).
nm() {
    local cfg="$1"; shift
    TAPPAAS_CONFIG="${cfg}" CONFIG_DIR="${cfg}" network-manager "$@"
}

# Build a zones.json fixture with the requested state for each named zone.
write_fixture() {
    local file="$1"; shift
    local body="{}"
    while [[ $# -ge 2 ]]; do
        local zone="$1" state="$2"
        shift 2
        body=$(echo "${body}" | jq --arg z "${zone}" --arg s "${state}" \
                '.[$z] = {type:"Test", state:$s, vlantag:830}')
    done
    echo "${body}" > "${file}"
}

run_case() {
    local name="$1" zone="$2" state_before="$3" verb="$4" extra_args="$5" \
          expect_state="$6" expect_rc="$7"
    echo "  Case: ${name}"
    local case_dir="${WORK}/${name}"
    mkdir -p "${case_dir}/config"
    write_fixture "${case_dir}/config/zones.json" "${zone}" "${state_before}"
    # Also add a Mandatory dmz for tests that target it.
    jq '. + {dmz: {type:"DMZ", state:"Mandatory", vlantag:600}}' \
        "${case_dir}/config/zones.json" > "${case_dir}/config/zones.tmp" \
        && mv "${case_dir}/config/zones.tmp" "${case_dir}/config/zones.json"

    local rc=0
    # shellcheck disable=SC2086
    nm "${case_dir}/config" "${verb}" "${zone}" ${extra_args:-} >/dev/null 2>&1 || rc=$?

    if [[ "${rc}" != "${expect_rc}" ]]; then
        fail "${name}: exit code ${rc} != expected ${expect_rc}"
        return
    fi

    local actual_state
    actual_state=$(jq -r --arg z "${zone}" '.[$z].state' "${case_dir}/config/zones.json")
    if [[ "${actual_state}" != "${expect_state}" ]]; then
        fail "${name}: state ${actual_state} != expected ${expect_state}"
        return
    fi

    pass "${name}"
}

echo "── test-zone-state.sh ──"

# Case 1: enable an inactive zone.
run_case "enable-inactive" "test1" "Inactive" "enable" "" "Active" "0"

# Case 2: disable an active zone.
run_case "disable-active" "test1" "Active" "disable" "" "Inactive" "0"

# Case 3: set manual.
run_case "set-manual" "test1" "Active" "manual" "" "Manual" "0"

# Case 4: no-op when already in target state.
run_case "no-op" "test1" "Active" "enable" "" "Active" "0"

# Case 5: nonexistent zone → exit 1, state unchanged (still original).
echo "  Case: nonexistent-zone"
case_dir="${WORK}/nonexistent"
mkdir -p "${case_dir}/config"
write_fixture "${case_dir}/config/zones.json" "test1" "Inactive"
rc=0
nm "${case_dir}/config" enable nope >/dev/null 2>&1 || rc=$?
if [[ "${rc}" == "1" ]] && [[ "$(jq -r '.test1.state' "${case_dir}/config/zones.json")" == "Inactive" ]]; then
    pass "nonexistent-zone (exit 1, untouched)"
else
    fail "nonexistent-zone: rc=${rc} state=$(jq -r '.test1.state' "${case_dir}/config/zones.json")"
fi

# Case 6: Mandatory refused without --force, state preserved.
echo "  Case: mandatory-refused"
case_dir="${WORK}/mandatory"
mkdir -p "${case_dir}/config"
write_fixture "${case_dir}/config/zones.json" "dmz" "Mandatory"
rc=0
nm "${case_dir}/config" disable dmz >/dev/null 2>&1 || rc=$?
if [[ "${rc}" == "1" ]] && [[ "$(jq -r '.dmz.state' "${case_dir}/config/zones.json")" == "Mandatory" ]]; then
    pass "mandatory-refused (exit 1, untouched)"
else
    fail "mandatory-refused: rc=${rc} state=$(jq -r '.dmz.state' "${case_dir}/config/zones.json")"
fi

# Case 7: --force allows leaving Mandatory.
echo "  Case: mandatory-with-force"
case_dir="${WORK}/mandatory-force"
mkdir -p "${case_dir}/config"
write_fixture "${case_dir}/config/zones.json" "dmz" "Mandatory"
rc=0
nm "${case_dir}/config" disable dmz --force >/dev/null 2>&1 || rc=$?
if [[ "${rc}" == "0" ]] && [[ "$(jq -r '.dmz.state' "${case_dir}/config/zones.json")" == "Inactive" ]]; then
    pass "mandatory-with-force"
else
    fail "mandatory-with-force: rc=${rc} state=$(jq -r '.dmz.state' "${case_dir}/config/zones.json")"
fi

# Case 8: invalid verb rejected (exit 1, unknown command), state untouched.
echo "  Case: invalid-verb"
case_dir="${WORK}/invalid-verb"
mkdir -p "${case_dir}/config"
write_fixture "${case_dir}/config/zones.json" "test1" "Inactive"
rc=0
nm "${case_dir}/config" toggle test1 >/dev/null 2>&1 || rc=$?
if [[ "${rc}" == "1" ]] && [[ "$(jq -r '.test1.state' "${case_dir}/config/zones.json")" == "Inactive" ]]; then
    pass "invalid-verb"
else
    fail "invalid-verb: rc=${rc} state=$(jq -r '.test1.state' "${case_dir}/config/zones.json")"
fi

# Case 9: missing zone argument → exit 1.
echo "  Case: missing-zone-arg"
case_dir="${WORK}/missing-arg"
mkdir -p "${case_dir}/config"
write_fixture "${case_dir}/config/zones.json" "test1" "Inactive"
rc=0
nm "${case_dir}/config" enable >/dev/null 2>&1 || rc=$?
if [[ "${rc}" == "1" ]]; then
    pass "missing-zone-arg"
else
    fail "missing-zone-arg: rc=${rc}"
fi

echo
echo "── summary: ${PASS} pass, ${FAIL} fail ──"
exit "${FAIL}"
