#!/usr/bin/env bash
#
# test-alias-name-validation.sh — OPNsense module alias naming (#300, ADR-005 #316).
#
# module_alias_name() produces an OPNsense-safe alias (<=32 chars) for any vmname:
# the plain `tm_<sanitised>` when the vmname (incl. variant) is under the 28-char
# threshold, otherwise a readable prefix + 6-hex sha1 of the full vmname
# (deterministic, collision-free). MUST match rules_manager._module_alias_name
# (Python). validate_module_alias_name() never rejects — it only warns on hashing.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../../lib/common-install-routines.sh"

PASS=0
FAIL=0
pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got '$1' expected '$2')"; fi; }

echo "test-alias-name-validation: module alias naming (#300, #316)"

# Short names (< 28 chars): plain tm_ alias, length-preserving hyphen sanitisation.
assert_eq "$(module_alias_name nextcloud)"           "tm_nextcloud"            "short name -> tm_ alias"
assert_eq "$(module_alias_name home-assistant)"      "tm_home_assistant"       "hyphen sanitised to underscore"
assert_eq "$(module_alias_name nextcloud-acme-corp)" "tm_nextcloud_acme_corp"  "19-char name stays plain (< 28)"

# Every alias is <=32 chars and starts with the prefix.
for v in a nextcloud nextcloud-acme-corp a-very-long-module-name-with-variant-suffix; do
    a="$(module_alias_name "$v")"
    if [[ "${#a}" -le 32 && "$a" == tm_* ]]; then
        pass "alias for '${v}' is valid (${a}, ${#a} chars)"
    else
        fail "alias for '${v}' invalid (${a}, ${#a} chars)"
    fi
done

# Names >= 28 chars hash deterministically and stay <= 32.
long="nextcloud-customer-environment-one"   # 34 chars
a1="$(module_alias_name "$long")"
a2="$(module_alias_name "$long")"
assert_eq "$a1" "$a2" "long-name alias is deterministic"
if [[ "${#a1}" -le 32 && "${#a1}" -eq 32 ]]; then pass "long-name alias is 32 chars"; else fail "long-name alias length ${#a1}"; fi

# Two distinct >=28 names sharing the first 22 sanitised chars must NOT collide.
c1="$(module_alias_name nextcloud-customer-environment-one)"
c2="$(module_alias_name nextcloud-customer-environment-two)"
if [[ "$c1" != "$c2" ]]; then
    pass "distinct long names with shared prefix get distinct aliases: ${c1} != ${c2}"
else
    fail "collision: ${c1} == ${c2}"
fi

# validate_module_alias_name never rejects.
if validate_module_alias_name "$long" >/dev/null 2>&1; then
    pass "validate_module_alias_name accepts a long name (hashes, does not reject)"
else
    fail "validate_module_alias_name must not reject"
fi

echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
