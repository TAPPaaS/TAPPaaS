#!/usr/bin/env bash
#
# test-service-pinholes.sh — the pinhole assertion a test-service.sh delegates (#689).
#
# Covers check_service_pinholes()'s own logic with rules-manager stubbed: the
# verdict comes from the compiler (tested in test_rules_manager.py), what is
# tested here is what this side does with the answer —
#   - "no rule is due" is a PASS with the reason, not a MISSING;
#   - an expected rule that is absent is a MISSING;
#   - the live rule is matched on the whole description field, so a rule for
#     port 8080 does not satisfy an assertion about port 80.
#
# That last one is why this matters beyond the stub: the hand-rolled tests used
# `grep -F ':80'`, and ':80' is a prefix of ':8080'.

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

echo "── test-service-pinholes.sh ──"

# ── Stub rules-manager ────────────────────────────────────────────────
# EXPECTED_JSON is what `expected-pinholes --output json` answers; LIVE_RULES is
# what `list-rules` prints, in its real "<description>  | <freetext>  (seq=…)"
# shape.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/rules-manager" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
    [[ "$a" == "expected-pinholes" ]] && { printf '%s\n' "${EXPECTED_JSON}"; exit 0; }
    [[ "$a" == "list-rules" ]]       && { printf '%s\n' "${LIVE_RULES}"; exit 0; }
done
exit 2
STUB
chmod +x "${WORK}/bin/rules-manager"
PATH="${WORK}/bin:${PATH}"
export EXPECTED_JSON LIVE_RULES

# ── A rule is due and present ─────────────────────────────────────────
EXPECTED_JSON='{"consumer":"ui","rules":["tappaas-svcdep:ui:web:api:80"],"skipped":[]}'
LIVE_RULES='  tappaas-svcdep:ui:web:api:80 | auto-pinhole  (seq=10100, iface=opt1)'
if out="$(check_service_pinholes ui api:web 2>&1)"; then
    grep -q "present" <<<"${out}" \
        && pass "an expected rule that exists passes" \
        || fail "an expected rule that exists did not report present: ${out}"
else
    fail "an expected rule that exists returned non-zero: ${out}"
fi

# ── A rule is due and absent ──────────────────────────────────────────
LIVE_RULES='  tappaas-module:other:egress:home:443 | unrelated  (seq=21400, iface=opt1)'
if out="$(check_service_pinholes ui api:web 2>&1)"; then
    fail "a missing rule passed: ${out}"
else
    grep -q "MISSING" <<<"${out}" \
        && pass "an expected rule that is absent fails as MISSING" \
        || fail "a missing rule failed without saying MISSING: ${out}"
fi

# ── No rule is due: a PASS, with the reason ───────────────────────────
# The regression this whole change exists for: rules-manager writes nothing,
# and the provider's test used to call that MISSING and fail the consumer.
EXPECTED_JSON='{"consumer":"ui","rules":[],"skipped":[{"coordinate":"api:web","reason":"consumer and api are both in zone '\''srv'\'' — intra-zone traffic needs no rule"}]}'
LIVE_RULES=''
if out="$(check_service_pinholes ui api:web 2>&1)"; then
    if grep -q "not required" <<<"${out}" && grep -q "intra-zone" <<<"${out}"; then
        pass "a pinhole that was never required passes, with the reason"
    else
        fail "no-rule-due passed but did not explain itself: ${out}"
    fi
else
    fail "a pinhole that was never required still failed the consumer: ${out}"
fi
if grep -q "MISSING" <<<"${out}"; then
    fail "no-rule-due was reported as MISSING"
else
    pass "no-rule-due is never reported as MISSING"
fi

# ── Port 80 is not satisfied by a rule for 8080 ───────────────────────
EXPECTED_JSON='{"consumer":"ui","rules":["tappaas-svcdep:ui:web:api:80"],"skipped":[]}'
LIVE_RULES='  tappaas-svcdep:ui:web:api:8080 | a DIFFERENT port  (seq=10100, iface=opt1)'
if check_service_pinholes ui api:web >/dev/null 2>&1; then
    fail "a rule for port 8080 satisfied an assertion about port 80"
else
    pass "the match is on the whole description: ':80' is not ':8080'"
fi

# ── A non-TCP rule carries its protocol suffix through ────────────────
EXPECTED_JSON='{"consumer":"ui","rules":["tappaas-svcdep:ui:ssdp:api:1900/UDP"],"skipped":[]}'
LIVE_RULES='  tappaas-svcdep:ui:ssdp:api:1900/UDP | SSDP  (seq=10101, iface=opt1)'
check_service_pinholes ui api:ssdp >/dev/null 2>&1 \
    && pass "a UDP rule matches on the canonical '/UDP' form" \
    || fail "a UDP rule did not match its canonical form"

# ── rules-manager cannot answer ───────────────────────────────────────
# Unknown state is not a pass: the caller must be able to tell this apart.
unset EXPECTED_JSON
EXPECTED_JSON=''
if check_service_pinholes ui '' >/dev/null 2>&1; then
    fail "a malformed request was treated as success"
else
    pass "a request that cannot be asked returns non-zero"
fi

echo "  ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
