#!/usr/bin/env bash
#
# test-alias-name-validation.sh — OPNsense module alias naming (#300, ADR-005 #316).
#
# module_alias_name() produces an OPNsense-safe alias (<=32 chars) for any vmname:
# the natural `tappaas_module_<sanitised>` when it fits, otherwise a readable
# prefix + 6-hex sha1 of the full vmname (deterministic, collision-free) so long
# base+variant names still fit. This MUST match rules_manager._module_alias_name
# (Python). validate_module_alias_name() never rejects — it only warns on hashing.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common-install-routines.sh"

PASS=0
FAIL=0
pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got '$1' expected '$2')"; fi; }

echo "test-alias-name-validation: module alias naming (#300, #316)"

# Short names: natural alias, length-preserving hyphen sanitisation.
assert_eq "$(module_alias_name nextcloud)"      "tappaas_module_nextcloud"      "short name -> natural alias"
assert_eq "$(module_alias_name home-assistant)" "tappaas_module_home_assistant" "hyphen sanitised to underscore"

# Every alias is <=32 chars and starts with the prefix.
for v in a nextcloud nextcloud-acme-corp tvbase-vitest test-debian-node3-noha a-very-long-module-name-with-variant-suffix; do
    a="$(module_alias_name "$v")"
    if [[ "${#a}" -le 32 && "$a" == tappaas_module_* ]]; then
        pass "alias for '${v}' is valid (${a}, ${#a} chars)"
    else
        fail "alias for '${v}' invalid (${a}, ${#a} chars)"
    fi
done

# Long names hash deterministically (stable across calls).
a1="$(module_alias_name nextcloud-acme-corp)"
a2="$(module_alias_name nextcloud-acme-corp)"
assert_eq "$a1" "$a2" "long-name alias is deterministic"
if [[ "${#a1}" -eq 32 ]]; then pass "long-name alias is exactly 32 chars"; else fail "long-name alias length ${#a1} != 32"; fi

# Two distinct long names that share a prefix do NOT collide (the old truncation
# behaviour would have collided them).
c1="$(module_alias_name nextcloud-customer-one)"
c2="$(module_alias_name nextcloud-customer-two)"
if [[ "$c1" != "$c2" ]]; then
    pass "distinct long names get distinct aliases (no collision): ${c1} != ${c2}"
else
    fail "collision: ${c1} == ${c2}"
fi

# validate_module_alias_name never rejects (it warns on hashing only).
if validate_module_alias_name nextcloud-acme-corp >/dev/null 2>&1; then
    pass "validate_module_alias_name accepts a long name (hashes, does not reject)"
else
    fail "validate_module_alias_name must not reject"
fi

echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
