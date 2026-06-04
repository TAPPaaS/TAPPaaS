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

# Source common helpers (#264) — we use normalize_module_config so assertions
# see the same view of a config regardless of whether it's stored flat or in
# canonical Pattern A form on disk. Stub the logging functions first since
# common-install-routines emits Info/Warn lines that would clutter test output.
info()  { :; }
warn()  { :; }
error() { echo "ERR: $*" >&2; }
die()   { error "$@"; exit 1; }
debug() { :; }
# shellcheck disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

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

# Normalize-aware field read — picks up the value whether it's at top level
# (flat) or under config[<dep>] (Pattern A). Use this in EVERY assertion that
# reads a value back from the installed config (#264).
get_field() {
    local field="$1"
    local file="$2"
    normalize_module_config < "${file}" | jq -r --arg f "${field}" '.[$f]'
}

# On-disk placement check — read the field DIRECTLY from a specific JSON
# path (no normalization). Use this when an assertion needs to prove a field
# physically lives in a particular config block on disk (#264 PA tests).
get_field_at() {
    local jq_path="$1"
    local file="$2"
    jq -r "${jq_path}" "${file}"
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
  "zone0": "srvHome",
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
    actual_vmname=$(get_field vmname "${RESULT}")
    assert_eq "vmname = testmod-staging" "testmod-staging" "${actual_vmname}"

    # vmid should not be 500 (source) or 501 (existing), so should be 502
    actual_vmid=$(get_field vmid "${RESULT}")
    assert_eq "vmid = 502 (skips 500 source, 501 existing)" "502" "${actual_vmid}"

    # proxyDomain should insert variant after first segment
    actual_domain=$(get_field proxyDomain "${RESULT}")
    assert_eq "proxyDomain = testmod.staging.test.tapaas.org" "testmod.staging.test.tapaas.org" "${actual_domain}"

    # zone0 should be unchanged (no "staging" zone in zones.json)
    actual_zone=$(get_field zone0 "${RESULT}")
    assert_eq "zone0 = srvHome (unchanged, no staging zone)" "srvHome" "${actual_zone}"

    # Other fields should be preserved
    actual_cores=$(get_field cores "${RESULT}")
    assert_eq "cores preserved = 2" "2" "${actual_cores}"

    actual_port=$(get_field proxyPort "${RESULT}")
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
    actual_zone=$(get_field zone0 "${RESULT}")
    assert_eq "zone0 = dmz (matched zone name)" "dmz" "${actual_zone}"

    actual_vmname=$(get_field vmname "${RESULT}")
    assert_eq "vmname = testmod-dmz" "testmod-dmz" "${actual_vmname}"

    actual_domain=$(get_field proxyDomain "${RESULT}")
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
    actual_vmname=$(get_field vmname "${RESULT}")
    assert_eq "vmname = my-custom-vm (explicit)" "my-custom-vm" "${actual_vmname}"

    actual_vmid=$(get_field vmid "${RESULT}")
    assert_eq "vmid = 555 (explicit)" "555" "${actual_vmid}"

    actual_zone=$(get_field zone0 "${RESULT}")
    assert_eq "zone0 = business (explicit)" "business" "${actual_zone}"

    actual_domain=$(get_field proxyDomain "${RESULT}")
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
    actual_vmname=$(get_field vmname "${RESULT}")
    assert_eq "vmname = testmod (unchanged)" "testmod" "${actual_vmname}"

    actual_vmid=$(get_field vmid "${RESULT}")
    assert_eq "vmid = 500 (unchanged)" "500" "${actual_vmid}"

    actual_cores=$(get_field cores "${RESULT}")
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
    actual_vmname=$(get_field vmname "${RESULT}")
    assert_eq "vmname = testmod-partial (auto-derived)" "testmod-partial" "${actual_vmname}"

    actual_vmid=$(get_field vmid "${RESULT}")
    assert_eq "vmid = 600 (explicit override)" "600" "${actual_vmid}"

    actual_domain=$(get_field proxyDomain "${RESULT}")
    assert_eq "proxyDomain = testmod.partial.test.tapaas.org (auto-derived)" "testmod.partial.test.tapaas.org" "${actual_domain}"
else
    echo -e "  [${RED}FAIL${NC}] Output file not created"
    FAIL=$((FAIL + 3))
fi

rm -f "${CONFIG_DIR}/testmod-partial.json" "${CONFIG_DIR}/testmod-partial.json.orig"

echo ""

# ──────────────────────────────────────────────────────────────────
# Pattern A coverage (#264): the suite above used a flat-form fixture
# with empty dependsOn, so regroup_to_pattern_a was a no-op. The tests
# below use a Pattern A fixture with declared dependsOn to lock in
# that overrides land in the correct config[<dep>] block on disk and
# that the normalized view matches operator expectations.
# ──────────────────────────────────────────────────────────────────

cat > "${MODULE_DIR}/patmod.json" << 'EOF'
{
  "description": "Pattern A test module (#264)",
  "version": "1.0",
  "vmname": "patmod",
  "vmid": 700,
  "vmtag": "TAPPaaS,Test",
  "node": "tappaas1",
  "dependsOn": ["cluster:vm", "firewall:proxy"],
  "provides": [],
  "config": {
    "cluster:vm": {
      "cores": 2, "memory": "2048", "diskSize": "8G", "storage": "tanka1",
      "imageType": "clone", "image": "8080", "bridge0": "lan", "zone0": "srvHome"
    },
    "firewall:proxy": {
      "proxyDomain": "patmod.default.example",
      "proxyPort": 80
    }
  }
}
EOF

# ── Test PA1: service-owned field override ──────────────────────
echo "Test PA1: Pattern A source — --proxyDomain lands under config['firewall:proxy']"
(
    cd "${MODULE_DIR}"
    export CONFIG_DIR
    bash "${SCRIPT_DIR}/../scripts/copy-update-json.sh" patmod --proxyDomain "pa1.override.example.com"
) > /dev/null 2>&1

RESULT="${CONFIG_DIR}/patmod.json"
if [[ -f "${RESULT}" ]]; then
    assert_eq "normalized proxyDomain = pa1.override.example.com" \
              "pa1.override.example.com" \
              "$(get_field proxyDomain "${RESULT}")"
    assert_eq "on-disk: under config['firewall:proxy']" \
              "pa1.override.example.com" \
              "$(get_field_at '.config["firewall:proxy"].proxyDomain' "${RESULT}")"
    assert_eq "on-disk: NOT at top level" \
              "null" \
              "$(get_field_at '.proxyDomain // "null"' "${RESULT}")"
fi
rm -f "${RESULT}" "${RESULT}.orig"
echo ""

# ── Test PA2: header field stays at top ─────────────────────────
echo "Test PA2: Pattern A source — --vmid stays at top level"
(
    cd "${MODULE_DIR}"
    export CONFIG_DIR
    bash "${SCRIPT_DIR}/../scripts/copy-update-json.sh" patmod --vmid 12345
) > /dev/null 2>&1
if [[ -f "${RESULT}" ]]; then
    assert_eq "vmid = 12345 (normalized)" "12345" "$(get_field vmid "${RESULT}")"
    assert_eq "on-disk: .vmid at top" "12345" "$(get_field_at '.vmid' "${RESULT}")"
fi
rm -f "${RESULT}" "${RESULT}.orig"
echo ""

# ── Test PA3: integer in config block, value type preserved ─────
echo "Test PA3: Pattern A source — --cores (integer) lands under config['cluster:vm']"
(
    cd "${MODULE_DIR}"
    export CONFIG_DIR
    bash "${SCRIPT_DIR}/../scripts/copy-update-json.sh" patmod --cores 16
) > /dev/null 2>&1
if [[ -f "${RESULT}" ]]; then
    assert_eq "cores = 16 (normalized)" "16" "$(get_field cores "${RESULT}")"
    assert_eq "on-disk: under config['cluster:vm']" \
              "16" "$(get_field_at '.config["cluster:vm"].cores' "${RESULT}")"
    assert_eq "on-disk: stored as JSON number" \
              "number" "$(jq -r '.config["cluster:vm"].cores | type' "${RESULT}")"
fi
rm -f "${RESULT}" "${RESULT}.orig"
echo ""

# ── Test PA4: field absent from source still placed correctly ───
echo "Test PA4: Pattern A source missing the field — override still placed under right block"
cat > "${MODULE_DIR}/patmod-noproxy.json" << 'EOF'
{
  "description": "Pattern A test module no proxyDomain",
  "vmname": "patmod-noproxy",
  "vmid": 701,
  "node": "tappaas1",
  "dependsOn": ["cluster:vm", "firewall:proxy"],
  "provides": [],
  "config": {
    "cluster:vm": {
      "cores": 2, "memory": "2048", "diskSize": "8G", "storage": "tanka1",
      "imageType": "clone", "image": "8080", "bridge0": "lan", "zone0": "srvHome"
    }
  }
}
EOF
(
    cd "${MODULE_DIR}"
    export CONFIG_DIR
    bash "${SCRIPT_DIR}/../scripts/copy-update-json.sh" patmod-noproxy --proxyDomain "pa4.added.example"
) > /dev/null 2>&1

RESULT="${CONFIG_DIR}/patmod-noproxy.json"
if [[ -f "${RESULT}" ]]; then
    assert_eq "added proxyDomain reads back" \
              "pa4.added.example" "$(get_field proxyDomain "${RESULT}")"
    assert_eq "added field lives under config['firewall:proxy']" \
              "pa4.added.example" \
              "$(get_field_at '.config["firewall:proxy"].proxyDomain' "${RESULT}")"
fi
rm -f "${RESULT}" "${RESULT}.orig"
echo ""

# ── Test PA5: multiple overrides at once ────────────────────────
echo "Test PA5: Pattern A source — multiple overrides land in correct blocks simultaneously"
(
    cd "${MODULE_DIR}"
    export CONFIG_DIR
    bash "${SCRIPT_DIR}/../scripts/copy-update-json.sh" patmod \
        --cores 8 --memory 8192 --proxyPort 4000 --proxyDomain "pa5.multi.example"
) > /dev/null 2>&1

RESULT="${CONFIG_DIR}/patmod.json"
if [[ -f "${RESULT}" ]]; then
    assert_eq "cores = 8"          "8"                   "$(get_field cores       "${RESULT}")"
    assert_eq "memory = 8192"      "8192"                "$(get_field memory      "${RESULT}")"
    assert_eq "proxyPort = 4000"   "4000"                "$(get_field proxyPort   "${RESULT}")"
    assert_eq "proxyDomain set"    "pa5.multi.example"   "$(get_field proxyDomain "${RESULT}")"
    assert_eq "cores under config['cluster:vm']" \
              "8" "$(get_field_at '.config["cluster:vm"].cores' "${RESULT}")"
    assert_eq "proxyPort under config['firewall:proxy']" \
              "4000" "$(get_field_at '.config["firewall:proxy"].proxyPort' "${RESULT}")"
fi
rm -f "${RESULT}" "${RESULT}.orig"
echo ""

# ── Test PA6: variant + override on Pattern A source ────────────
echo "Test PA6: Pattern A source + --variant staging + explicit override"
(
    cd "${MODULE_DIR}"
    export CONFIG_DIR
    bash "${SCRIPT_DIR}/../scripts/copy-update-json.sh" patmod \
        --variant staging --proxyDomain "pa6.from-override.example"
) > /dev/null 2>&1

RESULT="${CONFIG_DIR}/patmod-staging.json"
if [[ -f "${RESULT}" ]]; then
    assert_eq "variant persisted = staging" "staging" "$(get_field variant "${RESULT}")"
    assert_eq "vmname = patmod-staging (variant default)" \
              "patmod-staging" "$(get_field vmname "${RESULT}")"
    assert_eq "proxyDomain = pa6.from-override.example (override wins)" \
              "pa6.from-override.example" "$(get_field proxyDomain "${RESULT}")"
    assert_eq "override lands under config['firewall:proxy']" \
              "pa6.from-override.example" \
              "$(get_field_at '.config["firewall:proxy"].proxyDomain' "${RESULT}")"
fi
rm -f "${RESULT}" "${RESULT}.orig"
echo ""

# ── Test PA7: multi-dep field — first declared wins ─────────────
echo "Test PA7: multi-dep usedBy — cores lands per first dependsOn (cluster:lxc before cluster:vm)"
cat > "${MODULE_DIR}/patmod-lxc-first.json" << 'EOF'
{
  "description": "Pattern A LXC-first module",
  "vmname": "patmod-lxc-first",
  "vmid": 702,
  "node": "tappaas1",
  "dependsOn": ["cluster:lxc", "cluster:vm", "firewall:proxy"],
  "provides": [],
  "config": {
    "cluster:lxc": {
      "memory": "2048", "diskSize": "8G", "storage": "tanka1",
      "imageType": "clone", "image": "8080", "bridge0": "lan", "zone0": "srvHome"
    }
  }
}
EOF
(
    cd "${MODULE_DIR}"
    export CONFIG_DIR
    bash "${SCRIPT_DIR}/../scripts/copy-update-json.sh" patmod-lxc-first --cores 6
) > /dev/null 2>&1

RESULT="${CONFIG_DIR}/patmod-lxc-first.json"
if [[ -f "${RESULT}" ]]; then
    assert_eq "cores = 6 (normalized)" "6" "$(get_field cores "${RESULT}")"
    assert_eq "lands under cluster:lxc (first in dependsOn)" \
              "6" "$(get_field_at '.config["cluster:lxc"].cores' "${RESULT}")"
    assert_eq "NOT under cluster:vm" \
              "null" "$(get_field_at '.config["cluster:vm"].cores // "null"' "${RESULT}")"
fi
rm -f "${RESULT}" "${RESULT}.orig"
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
