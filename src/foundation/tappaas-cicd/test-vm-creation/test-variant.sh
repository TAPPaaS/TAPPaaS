#!/usr/bin/env bash
#
# TAPPaaS Variant Test Suite
#
# Tests the --variant functionality of copy-update-json.sh by validating
# the JSON transformation logic. Runs offline (no cluster required).
#
# Usage: ./test-variant.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colors ────────────────────────────────────────────────────────
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
NC='\e[0m'

PASS=0
FAIL=0

assert_eq() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        echo -e "  [${GREEN}PASS${NC}] ${test_name}"
        PASS=$((PASS + 1))
    else
        echo -e "  [${RED}FAIL${NC}] ${test_name}"
        echo -e "         expected: ${expected}"
        echo -e "         actual:   ${actual}"
        FAIL=$((FAIL + 1))
    fi
}

assert_ne() {
    local test_name="$1"
    local not_expected="$2"
    local actual="$3"
    if [[ "${not_expected}" != "${actual}" ]]; then
        echo -e "  [${GREEN}PASS${NC}] ${test_name} (got: ${actual})"
        PASS=$((PASS + 1))
    else
        echo -e "  [${RED}FAIL${NC}] ${test_name}"
        echo -e "         should not be: ${not_expected}"
        FAIL=$((FAIL + 1))
    fi
}

# ── Setup temp environment ────────────────────────────────────────
WORK_DIR=$(mktemp -d)
CONFIG_DIR="${WORK_DIR}/config"
MODULE_DIR="${WORK_DIR}/module"
mkdir -p "${CONFIG_DIR}" "${MODULE_DIR}"

cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# Create a test module JSON in the module dir
cat > "${MODULE_DIR}/testmod.json" << 'EOF'
{
  "description": "Test module for variant testing",
  "version": "1.0",
  "vmname": "testmod",
  "vmid": 500,
  "vmtag": "TAPPaaS,Test",
  "node": "tappaas1",
  "cores": 2,
  "memory": "2048",
  "diskSize": "8G",
  "storage": "tanka1",
  "imageType": "clone",
  "image": "8080",
  "bridge0": "lan",
  "zone0": "srv",
  "proxyDomain": "testmod.test.tapaas.org",
  "proxyPort": 8080,
  "dependsOn": [],
  "provides": []
}
EOF

# Also place a second module config in CONFIG_DIR to test VMID collision avoidance
cat > "${CONFIG_DIR}/existing.json" << 'EOF'
{
  "vmname": "existing",
  "vmid": 501
}
EOF

echo "=============================================="
echo "TAPPaaS Variant Test Suite"
echo "=============================================="
echo ""

# ── Test 1: Basic variant — all defaults ──────────────────────────
echo "Test 1: Basic variant with all defaults"
(
    cd "${MODULE_DIR}"
    export CONFIG_DIR
    bash "${SCRIPT_DIR}/../scripts/copy-update-json.sh" testmod --variant staging
) > /dev/null 2>&1

RESULT="${CONFIG_DIR}/testmod-staging.json"

if [[ -f "${RESULT}" ]]; then
    echo -e "  [${GREEN}PASS${NC}] Output file testmod-staging.json created"
    PASS=$((PASS + 1))
else
    echo -e "  [${RED}FAIL${NC}] Output file testmod-staging.json not created"
    FAIL=$((FAIL + 1))
fi

if [[ -f "${RESULT}" ]]; then
    # vmname should be testmod-staging
    actual_vmname=$(jq -r '.vmname' "${RESULT}")
    assert_eq "vmname = testmod-staging" "testmod-staging" "${actual_vmname}"

    # vmid should not be 500 (source) or 501 (existing), so should be 502
    actual_vmid=$(jq -r '.vmid' "${RESULT}")
    assert_eq "vmid = 502 (skips 500 source, 501 existing)" "502" "${actual_vmid}"

    # proxyDomain should insert variant after first segment
    actual_domain=$(jq -r '.proxyDomain' "${RESULT}")
    assert_eq "proxyDomain = testmod.staging.test.tapaas.org" "testmod.staging.test.tapaas.org" "${actual_domain}"

    # zone0 should be unchanged (no "staging" zone in zones.json)
    actual_zone=$(jq -r '.zone0' "${RESULT}")
    assert_eq "zone0 = srv (unchanged, no staging zone)" "srv" "${actual_zone}"

    # Other fields should be preserved
    actual_cores=$(jq -r '.cores' "${RESULT}")
    assert_eq "cores preserved = 2" "2" "${actual_cores}"

    actual_port=$(jq -r '.proxyPort' "${RESULT}")
    assert_eq "proxyPort preserved = 8080" "8080" "${actual_port}"
fi

# Clean up for next test
rm -f "${CONFIG_DIR}/testmod-staging.json" "${CONFIG_DIR}/testmod-staging.json.orig"

echo ""

# ── Test 2: Variant with zone match ──────────────────────────────
echo "Test 2: Variant name matches a zone in zones.json (dmz)"
(
    cd "${MODULE_DIR}"
    export CONFIG_DIR
    bash "${SCRIPT_DIR}/../scripts/copy-update-json.sh" testmod --variant dmz
) > /dev/null 2>&1

RESULT="${CONFIG_DIR}/testmod-dmz.json"

if [[ -f "${RESULT}" ]]; then
    actual_zone=$(jq -r '.zone0' "${RESULT}")
    assert_eq "zone0 = dmz (matched zone name)" "dmz" "${actual_zone}"

    actual_vmname=$(jq -r '.vmname' "${RESULT}")
    assert_eq "vmname = testmod-dmz" "testmod-dmz" "${actual_vmname}"

    actual_domain=$(jq -r '.proxyDomain' "${RESULT}")
    assert_eq "proxyDomain = testmod.dmz.test.tapaas.org" "testmod.dmz.test.tapaas.org" "${actual_domain}"
else
    echo -e "  [${RED}FAIL${NC}] Output file not created"
    FAIL=$((FAIL + 3))
fi

rm -f "${CONFIG_DIR}/testmod-dmz.json" "${CONFIG_DIR}/testmod-dmz.json.orig"

echo ""

# ── Test 3: Variant with explicit overrides ───────────────────────
echo "Test 3: Variant with explicit field overrides"
(
    cd "${MODULE_DIR}"
    export CONFIG_DIR
    bash "${SCRIPT_DIR}/../scripts/copy-update-json.sh" testmod --variant custom \
        --vmname "my-custom-vm" --vmid 555 --zone0 "business" --proxyDomain "custom.example.com"
) > /dev/null 2>&1

RESULT="${CONFIG_DIR}/testmod-custom.json"

if [[ -f "${RESULT}" ]]; then
    actual_vmname=$(jq -r '.vmname' "${RESULT}")
    assert_eq "vmname = my-custom-vm (explicit)" "my-custom-vm" "${actual_vmname}"

    actual_vmid=$(jq -r '.vmid' "${RESULT}")
    assert_eq "vmid = 555 (explicit)" "555" "${actual_vmid}"

    actual_zone=$(jq -r '.zone0' "${RESULT}")
    assert_eq "zone0 = business (explicit)" "business" "${actual_zone}"

    actual_domain=$(jq -r '.proxyDomain' "${RESULT}")
    assert_eq "proxyDomain = custom.example.com (explicit)" "custom.example.com" "${actual_domain}"
else
    echo -e "  [${RED}FAIL${NC}] Output file not created"
    FAIL=$((FAIL + 4))
fi

rm -f "${CONFIG_DIR}/testmod-custom.json" "${CONFIG_DIR}/testmod-custom.json.orig"

echo ""

# ── Test 4: Non-variant still works ──────────────────────────────
echo "Test 4: Non-variant mode unchanged"
(
    cd "${MODULE_DIR}"
    export CONFIG_DIR
    bash "${SCRIPT_DIR}/../scripts/copy-update-json.sh" testmod --cores 4
) > /dev/null 2>&1

RESULT="${CONFIG_DIR}/testmod.json"

if [[ -f "${RESULT}" ]]; then
    actual_vmname=$(jq -r '.vmname' "${RESULT}")
    assert_eq "vmname = testmod (unchanged)" "testmod" "${actual_vmname}"

    actual_vmid=$(jq -r '.vmid' "${RESULT}")
    assert_eq "vmid = 500 (unchanged)" "500" "${actual_vmid}"

    actual_cores=$(jq -r '.cores' "${RESULT}")
    assert_eq "cores = 4 (overridden)" "4" "${actual_cores}"
else
    echo -e "  [${RED}FAIL${NC}] Output file not created"
    FAIL=$((FAIL + 3))
fi

rm -f "${CONFIG_DIR}/testmod.json" "${CONFIG_DIR}/testmod.json.orig"

echo ""

# ── Test 5: Variant with partial overrides ────────────────────────
echo "Test 5: Variant with only vmid override (other fields auto-derived)"
(
    cd "${MODULE_DIR}"
    export CONFIG_DIR
    bash "${SCRIPT_DIR}/../scripts/copy-update-json.sh" testmod --variant partial --vmid 600
) > /dev/null 2>&1

RESULT="${CONFIG_DIR}/testmod-partial.json"

if [[ -f "${RESULT}" ]]; then
    actual_vmname=$(jq -r '.vmname' "${RESULT}")
    assert_eq "vmname = testmod-partial (auto-derived)" "testmod-partial" "${actual_vmname}"

    actual_vmid=$(jq -r '.vmid' "${RESULT}")
    assert_eq "vmid = 600 (explicit override)" "600" "${actual_vmid}"

    actual_domain=$(jq -r '.proxyDomain' "${RESULT}")
    assert_eq "proxyDomain = testmod.partial.test.tapaas.org (auto-derived)" "testmod.partial.test.tapaas.org" "${actual_domain}"
else
    echo -e "  [${RED}FAIL${NC}] Output file not created"
    FAIL=$((FAIL + 3))
fi

rm -f "${CONFIG_DIR}/testmod-partial.json" "${CONFIG_DIR}/testmod-partial.json.orig"

echo ""

# ── Summary ───────────────────────────────────────────────────────
echo "=============================================="
echo "Variant Test Summary"
echo "=============================================="
echo -e "  Passed: ${GREEN}${PASS}${NC}"
echo -e "  Failed: ${RED}${FAIL}${NC}"
echo ""

if [[ "${FAIL}" -eq 0 ]]; then
    echo -e "[${GREEN}SUCCESS${NC}] All variant tests passed!"
    exit 0
else
    echo -e "[${RED}FAILURE${NC}] Some variant tests failed."
    exit 1
fi
