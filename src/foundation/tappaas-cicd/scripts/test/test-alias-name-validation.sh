#!/usr/bin/env bash
#
# test-alias-name-validation.sh — vmname must fit its OPNsense alias (#300).
#
# validate_module_alias_name() rejects a vmname whose
# `tappaas_module_<sanitised>` alias would exceed OPNsense's 32-char limit.
# The prefix `tappaas_module_` is 15 chars, so the maximum vmname length is 17;
# non-alphanumeric characters are sanitised to underscores (length-preserving),
# mirroring rules_manager._module_alias_name.
#

set -uo pipefail
# No `set -e`: validate_module_alias_name returns 1 on a rejected name (normal here).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common-install-routines.sh"

PASS=0
FAIL=0
pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }

# expect_ok <vmname>: must be accepted (alias <= 32 chars)
expect_ok() {
    if validate_module_alias_name "$1" >/dev/null 2>&1; then
        pass "accepts '${1}' (${#1} chars)"
    else
        fail "rejected '${1}' (${#1} chars) but should accept"
    fi
}
# expect_reject <vmname>: must be rejected (alias > 32 chars)
expect_reject() {
    if validate_module_alias_name "$1" >/dev/null 2>&1; then
        fail "accepted '${1}' (${#1} chars) but should reject"
    else
        pass "rejects '${1}' (${#1} chars)"
    fi
}

echo "test-alias-name-validation: OPNsense alias length guard (#300)"

# Boundary: 17-char vmname -> alias exactly 32 -> OK.
expect_ok     "aaaaaaaaaaaaaaaaa"     # 17
# Boundary+1: 18-char vmname -> alias 33 -> reject.
expect_reject "aaaaaaaaaaaaaaaaaa"    # 18

# The issue's own reproduction (homeassistant --variant test).
expect_reject "homeassistant-test"    # 18

# Typical short names pass.
expect_ok     "nextcloud"
expect_ok     "home-assistant"        # 14, hyphen sanitised to underscore

# Hyphens are length-preserving, so the boundary holds with them too.
expect_ok     "home-assistant-xy"     # 17
expect_reject "home-assistant-xyz"    # 18

echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
