#!/usr/bin/env bash
#
# test-variant-dns.sh — ADR-005 Sprint 4 DNS-mode tests (offline, no firewall).
#
# Covers the pure logic behind wildcard vs per-service DNS:
#   - dmz_gateway_ip()  : derives the split-horizon target from zones.json (#269)
#   - get_variant_config: surfaces dnsMode/tlsCertRefid that drive proxy install
#
# Live registration (VN-01..05 against Unbound/Caddy) is exercised by the firewall
# deep test and a manual smoke; this file keeps the deterministic pieces fast.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export CONFIG_DIR="${WORK}"

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../lib/common-install-routines.sh"

PASS=0
FAIL=0
pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got '$1' expected '$2')"; fi; }

echo "test-variant-dns: DNS-mode helpers (ADR-005 Sprint 4)"

# ── dmz_gateway_ip ───────────────────────────────────────────────────
cat > "${WORK}/zones.json" <<'JSON'
{ "dmz": { "type": "DMZ", "typeId": "6", "ip": "10.6.0.0/24", "bridge": "lan" },
  "srvHome": { "type": "Service", "typeId": "2", "ip": "10.2.10.0/24" } }
JSON
assert_eq "$(dmz_gateway_ip)" "10.6.0.1" "dmz_gateway_ip derives 10.6.0.1 from 10.6.0.0/24"

# A different DMZ subnet derives the matching .1
cat > "${WORK}/zones.json" <<'JSON'
{ "dmz": { "type": "DMZ", "ip": "10.9.4.0/24" } }
JSON
assert_eq "$(dmz_gateway_ip)" "10.9.4.1" "dmz_gateway_ip derives 10.9.4.1 from 10.9.4.0/24"

# No dmz zone -> error (non-zero)
echo '{ "srvHome": { "ip": "10.2.10.0/24" } }' > "${WORK}/zones.json"
if dmz_gateway_ip >/dev/null 2>&1; then
    fail "dmz_gateway_ip should fail when no dmz zone present"
else
    pass "dmz_gateway_ip fails cleanly when no dmz zone present"
fi

# ── dnsMode surfaced by the variant registry ─────────────────────────
cat > "${WORK}/configuration.json" <<'JSON'
{ "tappaas": { "domain": "base.org", "variants": {
  "": { "domain": "base.org", "dnsMode": "wildcard", "tlsCertRefid": "abc" },
  "tenant": { "domain": "tenant.example.com", "dnsMode": "per-service", "tlsCertRefid": "" } } } }
JSON
assert_eq "$(get_variant_config ""       | jq -r '.dnsMode')" "wildcard"    "default variant dnsMode=wildcard"
assert_eq "$(get_variant_config tenant   | jq -r '.dnsMode')" "per-service" "tenant variant dnsMode=per-service"
assert_eq "$(get_variant_config ""       | jq -r '.tlsCertRefid')" "abc"    "wildcard variant carries a tlsCertRefid"
assert_eq "$(get_variant_config tenant   | jq -r '.tlsCertRefid')" ""       "per-service variant has no tlsCertRefid"

echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
