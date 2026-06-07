#!/usr/bin/env bash
#
# test-variant-migrate.sh — ADR-005 Sprint 5: migrate-to-variants.sh (offline).
#
# VE-04: a legacy single-domain install (tappaas.domain only) migrates to
# variants[""], idempotently, with optional legacy-field removal.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MIGRATE="${SCRIPT_DIR}/../scripts/migrate-to-variants.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export CONFIG_DIR="${WORK}"
CFG="${WORK}/configuration.json"

PASS=0
FAIL=0
pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got '$1' expected '$2')"; fi; }

legacy_config() {
    cat > "${CFG}" <<'JSON'
{ "tappaas": { "domain": "legacy.example.com", "tlsCertRefid": "deadbeef", "email": "a@b.c" } }
JSON
}

echo "test-variant-migrate: migrate-to-variants.sh (ADR-005 Sprint 5)"

# VE-04a: legacy -> variants[""] carries domain + refid + dnsMode
legacy_config
"${MIGRATE}" >/dev/null 2>&1
assert_eq "$(jq -r '.tappaas.variants[""].domain' "${CFG}")"       "legacy.example.com" "VE-04a migrates domain to variants[\"\"]"
assert_eq "$(jq -r '.tappaas.variants[""].tlsCertRefid' "${CFG}")" "deadbeef"           "VE-04a migrates tlsCertRefid"
assert_eq "$(jq -r '.tappaas.variants[""].dnsMode' "${CFG}")"      "wildcard"           "VE-04a sets dnsMode=wildcard"
assert_eq "$(jq -r '.tappaas.domain' "${CFG}")"                    "legacy.example.com" "VE-04a keeps legacy domain by default"

# VE-04b: idempotent (second run makes no change, exits 0)
if "${MIGRATE}" >/dev/null 2>&1; then pass "VE-04b re-run is idempotent (exit 0)"; else fail "VE-04b re-run failed"; fi

# VE-04c: --remove-legacy drops the legacy fields but keeps the variant
"${MIGRATE}" --remove-legacy >/dev/null 2>&1
if [[ "$(jq -r '.tappaas.domain // "<removed>"' "${CFG}")" == "<removed>" \
   && "$(jq -r '.tappaas.variants[""].domain' "${CFG}")" == "legacy.example.com" ]]; then
    pass "VE-04c --remove-legacy drops tappaas.domain, keeps variants[\"\"]"
else
    fail "VE-04c --remove-legacy result wrong"
fi

# VE-04d: no domain and no variant -> clean failure
echo '{ "tappaas": { "email": "a@b.c" } }' > "${CFG}"
if "${MIGRATE}" >/dev/null 2>&1; then fail "VE-04d should fail with nothing to migrate"; else pass "VE-04d fails cleanly when nothing to migrate"; fi

echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
