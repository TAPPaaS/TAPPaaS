#!/usr/bin/env bash
#
# test-convert-to-config.sh — tabletop tests for convert-json-to-config.sh (#207).
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/test → scripts → tappaas-cicd → foundation
FOUNDATION_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
export TAPPAAS_SCHEMA_FILE="${FOUNDATION_DIR}/schemas/module-fields.json"

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../../lib/common-install-routines.sh"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../convert-json-to-config.sh"

PASS=0
FAIL=0

pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }

# Verify: input → convert → output shape matches expectation
run_case() {
    local name="$1" input="$2" expect_filter="$3"
    echo "  Case: ${name}"
    local out
    out=$(echo "${input}" | regroup_to_pattern_a 2>/dev/null)
    if echo "${out}" | jq -e "${expect_filter}" >/dev/null 2>&1; then
        pass "${name}"
    else
        fail "${name} — got: $(echo "${out}" | jq -c '.')"
    fi
}

echo "── test-convert-to-config.sh ──"

# Case 1: simple flat → Pattern A: cluster:vm fields go under config block
run_case "flat-to-A" \
    '{"vmname":"a","dependsOn":["cluster:vm"],"cores":2,"memory":"4096"}' \
    '.config["cluster:vm"].cores == 2 and .config["cluster:vm"].memory == "4096" and (.cores // null) == null'

# Case 2: header fields stay at top
run_case "header-pinned" \
    '{"vmname":"a","vmid":100,"node":"n1","zone0":"home","dependsOn":["cluster:vm"]}' \
    '.vmname == "a" and .vmid == 100 and .node == "n1" and .zone0 == "home"'

# Case 3: general fields stay at top
run_case "general-pinned" \
    '{"description":"d","version":"1.0","dependsOn":["cluster:vm"],"cores":2}' \
    '.description == "d" and .version == "1.0" and .config["cluster:vm"].cores == 2'

# Case 4: idempotent — already Pattern A
run_case "idempotent" \
    '{"vmname":"a","dependsOn":["cluster:vm"],"config":{"cluster:vm":{"cores":2}}}' \
    '.config["cluster:vm"].cores == 2 and (.cores // null) == null'

# Case 5: multi-match tiebreak — cores usedBy [cluster:vm, cluster:lxc]; module declares lxc first
run_case "multi-match-first-wins" \
    '{"vmname":"a","dependsOn":["cluster:lxc","backup:vm"],"cores":2}' \
    '.config["cluster:lxc"].cores == 2'

# Case 6: unknown field stays at top with warning
run_case "unknown-field" \
    '{"vmname":"a","dependsOn":["cluster:vm"],"customField":"x","cores":2}' \
    '.customField == "x" and .config["cluster:vm"].cores == 2'

# Case 7: orphan — usedBy refers to dep the module doesn't declare → stay at top
# proxyDomain is usedBy=["firewall:proxy"]. Module declares only cluster:vm. Orphan.
run_case "orphan-field" \
    '{"vmname":"a","dependsOn":["cluster:vm"],"proxyDomain":"x.test","cores":2}' \
    '.proxyDomain == "x.test"'

# Case 8: lossless round-trip via flatten — normalize(convert(X)) == flatten(X)
input='{"vmname":"a","dependsOn":["cluster:vm","firewall:proxy"],"cores":2,"memory":"4096","proxyDomain":"x.test","proxyPort":80}'
flat_in=$(echo "${input}" | normalize_module_config)
converted=$(echo "${input}" | regroup_to_pattern_a 2>/dev/null)
flat_out=$(echo "${converted}" | normalize_module_config)
if [[ "$(echo "${flat_in}" | jq -S .)" == "$(echo "${flat_out}" | jq -S .)" ]]; then
    pass "round-trip lossless"
    PASS=$((PASS + 1))
else
    fail "round-trip lossless"
    echo "  in: ${flat_in}"
    echo "  out: ${flat_out}"
    FAIL=$((FAIL + 1))
fi

echo
echo "── summary: ${PASS} pass, ${FAIL} fail ──"
exit "${FAIL}"
