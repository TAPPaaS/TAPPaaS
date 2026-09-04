#!/usr/bin/env bash
#
# test-converge-adopt.sh — the ADR-020 D9 "adopt" write (grow-only fields).
#
# adopt is the one place the converge writes DESIRED state: when the guest is
# already larger than config, config moves forward instead of the guest being
# shrunk. It shipped in a663fec calling jq_module_write with jq's own arguments
# BEFORE the filter, so "--arg" became the filter and adopt never once wrote —
# silently, because the failure only surfaced as an install-time error much
# later. This pins both halves of the call: the argument ORDER, and the TYPE of
# the adopted value.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../../lib/common-install-routines.sh"

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }

CONFIG_DIR="${WORK}"

echo "── test-converge-adopt.sh ──"

# The call adopt makes, verbatim in shape: filter second, jq args after it.
adopt() { # adopt <module> <field> <actual>
    local m="$1" f="$2" v="$3" flag=--arg
    [[ "${v}" =~ ^-?[0-9]+$ ]] && flag=--argjson
    jq_module_write "${m}" '.[$f] = $v' --arg f "${f}" "${flag}" v "${v}"
}

cat > "${WORK}/grow.json" <<'EOF'
{ "vmname": "grow", "dependsOn": ["cluster:vm"], "diskSize": 32 }
EOF

if adopt grow diskSize 64 2>/dev/null; then
    pass "adopt writes without error (filter is the 2nd argument, not --arg)"
else
    fail "adopt still fails — jq_module_write argument order regressed"
fi

got="$(read_module_config grow 2>/dev/null | jq -r '.diskSize')"
if [[ "${got}" == "64" ]]; then
    pass "the adopted value is readable through the funnel (${got})"
else
    fail "expected diskSize 64 through read_module_config, got '${got}'"
fi

# --arg would store "64". Grow-only fields are integers in the schema, and a
# string there is a type error a later consumer has to guess its way around.
typ="$(read_module_config grow 2>/dev/null | jq -r '.diskSize | type')"
if [[ "${typ}" == "number" ]]; then
    pass "a numeric field is adopted as a number, not a string"
else
    fail "diskSize adopted as ${typ} — use --argjson for numeric values"
fi

# A non-numeric grow-only value must still round-trip as a string.
cat > "${WORK}/str.json" <<'EOF'
{ "vmname": "str", "dependsOn": ["cluster:vm"], "vmtag": "TAPPaaS" }
EOF
if adopt str vmtag "TAPPaaS;extra" 2>/dev/null \
   && [[ "$(read_module_config str 2>/dev/null | jq -r '.vmtag')" == "TAPPaaS;extra" ]]; then
    pass "a non-numeric value is adopted verbatim as a string"
else
    fail "non-numeric adopt did not round-trip"
fi

echo
echo "── summary: ${PASS} pass, ${FAIL} fail ──"
exit "${FAIL}"
