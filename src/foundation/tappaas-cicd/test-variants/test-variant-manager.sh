#!/usr/bin/env bash
#
# test-variant-manager.sh — ADR-005 Sprint 2 unit tests for variant-manager
# (offline, no cluster). Exercises the CLI against a throwaway CONFIG_DIR holding
# fixture configuration.json + zones.json. --add-zone runs with --no-activate so
# no live zone-manager call is made.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly VM="${SCRIPT_DIR}/../scripts/variant-manager.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export CONFIG_DIR="${WORK}"
CFG="${WORK}/configuration.json"
ZONES="${WORK}/zones.json"

PASS=0
FAIL=0
pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got '$1' expected '$2')"; fi; }

reset_fixtures() {
    cat > "${CFG}" <<'JSON'
{ "tappaas": { "domain": "base.org", "email": "a@base.org", "variants": {} } }
JSON
    cat > "${ZONES}" <<'JSON'
{
  "mgmt":    { "type": "Management", "typeId": "3", "subId": "0",  "vlantag": 300, "ip": "10.3.0.0/24",  "bridge": "lan", "state": "Manual", "access-to": ["internet"], "pinhole-allowed-from": [] },
  "srvHome": { "type": "Service",    "typeId": "2", "subId": "10", "vlantag": 210, "ip": "10.2.10.0/24", "bridge": "lan", "state": "Active", "access-to": ["internet"], "pinhole-allowed-from": ["dmz"] }
}
JSON
    rm -f "${WORK}"/*-*.json 2>/dev/null || true
}

echo "test-variant-manager: variant-manager CLI (ADR-005 Sprint 2)"
reset_fixtures

# VM-01: default variant
if "${VM}" add "" --domain foo.org >/dev/null 2>&1; then
    assert_eq "$(jq -r '.tappaas.variants[""].domain' "${CFG}")" "foo.org" "VM-01 add \"\" --domain foo.org creates default variant"
else
    fail "VM-01 add \"\" failed"
fi

# VM-01b: list shows the default variant even when it is the ONLY one (the
# empty-string key must not be mistaken for "no variants").
list_default="$("${VM}" list 2>/dev/null)"
if grep -q "<default>" <<<"${list_default}"; then
    pass "VM-01b list shows default-only variant (empty key not treated as empty)"
else
    fail "VM-01b list reported no variants despite default being registered"
fi

# VM-02: named variant
if "${VM}" add demo --domain demo.foo.org >/dev/null 2>&1; then
    assert_eq "$(jq -r '.tappaas.variants.demo.domain' "${CFG}")" "demo.foo.org" "VM-02 add demo creates named variant"
else
    fail "VM-02 add demo failed"
fi

# VM-03: --add-zone allocates VLAN 299 (backwards from x99, Service typeId 2)
if "${VM}" add x --domain x.org --add-zone --no-activate >/dev/null 2>&1; then
    assert_eq "$(jq -r '.x.vlantag' "${ZONES}")" "299" "VM-03 add x --add-zone allocates VLAN 299"
    assert_eq "$(jq -r '.x.ip' "${ZONES}")" "10.2.99.0/24" "VM-03 zone x ip 10.2.99.0/24"
    assert_eq "$(jq -r '.tappaas.variants.x.zone' "${CFG}")" "x" "VM-03 variant x records zone x"
else
    fail "VM-03 add x --add-zone failed"
fi

# VM-04: next --add-zone allocates 298 (next free backwards)
if "${VM}" add y --domain y.org --add-zone --no-activate >/dev/null 2>&1; then
    assert_eq "$(jq -r '.y.vlantag' "${ZONES}")" "298" "VM-04 add y --add-zone allocates VLAN 298"
else
    fail "VM-04 add y --add-zone failed"
fi

# VM-05: explicit --vlan override
if "${VM}" add z --domain z.org --add-zone --vlan 275 --no-activate >/dev/null 2>&1; then
    assert_eq "$(jq -r '.z.vlantag' "${ZONES}")" "275" "VM-05 add z --vlan 275 uses explicit VLAN"
else
    fail "VM-05 add z --vlan 275 failed"
fi

# VM-06: duplicate fails
if "${VM}" add demo --domain dup.org >/dev/null 2>&1; then
    fail "VM-06 duplicate add demo should fail"
else
    pass "VM-06 duplicate add demo fails"
fi

# VM-07: invalid characters fail
if "${VM}" add 'bad!name' --domain bad.org >/dev/null 2>&1; then
    fail "VM-07 add 'bad!name' should fail"
else
    pass "VM-07 add 'bad!name' fails on invalid characters"
fi

# VM-07b: --add-zone with a hyphenated name fails (zone names are camelCase, #278)
if "${VM}" add multi-tenant --domain mt.org --add-zone --no-activate >/dev/null 2>&1; then
    fail "VM-07b --add-zone multi-tenant (hyphen) should fail (zone name camelCase)"
else
    pass "VM-07b --add-zone rejects hyphenated name (camelCase zone rule)"
fi

# VM-08: list shows variants. Capture first, then grep — piping a long listing
# into `grep -q` triggers SIGPIPE on the producer under pipefail.
list_out="$("${VM}" list 2>/dev/null)"
if grep -q "demo" <<<"${list_out}"; then
    pass "VM-08 list shows registered variants"
else
    fail "VM-08 list did not show demo"
fi

# VM-09: show single variant
show_out="$("${VM}" show demo 2>/dev/null)"
if grep -q "demo.foo.org" <<<"${show_out}"; then
    pass "VM-09 show demo shows variant details"
else
    fail "VM-09 show demo failed"
fi

# VM-10: remove fails if modules deployed
cat > "${WORK}/nextcloud-demo.json" <<'JSON'
{ "vmname": "nextcloud-demo", "variant": "demo" }
JSON
if "${VM}" remove demo >/dev/null 2>&1; then
    fail "VM-10 remove demo should fail (module deployed)"
else
    pass "VM-10 remove demo fails while module deployed"
fi

# VM-11: remove --force succeeds even with modules
if "${VM}" remove demo --force >/dev/null 2>&1; then
    if jq -e '.tappaas.variants | has("demo") | not' "${CFG}" >/dev/null 2>&1; then
        pass "VM-11 remove demo --force removes variant despite deployed module"
    else
        fail "VM-11 demo still present after --force remove"
    fi
else
    fail "VM-11 remove demo --force failed"
fi

echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
