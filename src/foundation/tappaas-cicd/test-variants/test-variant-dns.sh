#!/usr/bin/env bash
#
# test-variant-dns.sh — DNS-mode tests (offline, no firewall).
#
# Covers the pure logic behind wildcard vs per-service DNS:
#   - dmz_gateway_ip()  : derives the split-horizon target from zones.json (#269)
#   - get_variant_config: surfaces dnsMode/tlsCertRefid that drive proxy install
#
# get_variant_config reads config/environments/<env>.json (the dnsMode) and the
# runtime cert-refids.json (the tlsCertRefid). The legacy ADR-005 variant
# registry is retired (ADR-007 Phase D).
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

echo "test-variant-dns: DNS-mode helpers (ADR-007)"

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

# ── zone_gateway_ip (generic; #504) ──────────────────────────────────
cat > "${WORK}/zones.json" <<'JSON'
{ "home": { "type": "Client",  "ip": "10.3.10.0/24" },
  "work": { "type": "Client",  "ip": "10.3.20.0/24" },
  "mgmt": { "type": "Service", "ip": "10.0.0.0/24" },
  "dmz":  { "type": "DMZ",     "ip": "10.6.0.0/24" } }
JSON
assert_eq "$(zone_gateway_ip home)" "10.3.10.1" "zone_gateway_ip home -> 10.3.10.1"
assert_eq "$(zone_gateway_ip mgmt)" "10.0.0.1"  "zone_gateway_ip mgmt -> 10.0.0.1"
assert_eq "$(dmz_gateway_ip)"       "10.6.0.1"  "dmz_gateway_ip still derives via zone_gateway_ip"
if zone_gateway_ip nosuchzone >/dev/null 2>&1; then
    fail "zone_gateway_ip should fail for an unknown zone"
else
    pass "zone_gateway_ip fails cleanly for an unknown zone"
fi

# ── proxy_split_horizon_gateway (#504) ───────────────────────────────
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../../network/services/proxy/access-list.sh"
ZF="${WORK}/zones.json"
mk_mod() { printf '{ "config": { "network:proxy": { "proxyAllowedZones": %s } } }' "$1" > "${WORK}/mod.json"; }

# Single client zone -> that zone's gateway (NOT the DMZ gateway, the #504 bug).
mk_mod '["mgmt"]'
assert_eq "$(proxy_split_horizon_gateway "${WORK}/mod.json" "${ZF}" 2>/dev/null)" "10.0.0.1" \
    "per-service ['mgmt'] -> mgmt gateway, not DMZ"

# Multi-zone -> primary (first) zone's gateway; still succeeds (warns on stderr).
mk_mod '["work","home"]'
assert_eq "$(proxy_split_horizon_gateway "${WORK}/mod.json" "${ZF}" 2>/dev/null)" "10.3.20.1" \
    "per-service ['work','home'] -> primary 'work' gateway"

# Default (empty) -> home preferred.
mk_mod '[]'
assert_eq "$(proxy_split_horizon_gateway "${WORK}/mod.json" "${ZF}" 2>/dev/null)" "10.3.10.1" \
    "per-service default -> home gateway"

# internet-only -> no client zone -> non-zero (caller falls back / warns).
mk_mod '["internet"]'
if proxy_split_horizon_gateway "${WORK}/mod.json" "${ZF}" >/dev/null 2>&1; then
    fail "proxy_split_horizon_gateway should fail for internet-only"
else
    pass "proxy_split_horizon_gateway fails cleanly for internet-only"
fi

# ── dnsMode surfaced by the environment files + cert-refids.json ─────
mkdir -p "${WORK}/environments"
cat > "${WORK}/site.json" <<'JSON'
{ "name": "base", "displayName": "Base", "owner": "test2",
  "hardware": { "nodes": [ { "name": "tappaas1" } ] } }
JSON
cat > "${WORK}/environments/base.json" <<'JSON'
{ "name": "base", "displayName": "Default", "ownerOrg": "test2",
  "domains": { "primary": "base.org", "dnsMode": "wildcard" },
  "network": { "zone": "base" } }
JSON
cat > "${WORK}/environments/tenant.json" <<'JSON'
{ "name": "tenant", "displayName": "Tenant", "ownerOrg": "test2",
  "domains": { "primary": "tenant.example.com", "dnsMode": "per-service" },
  "network": { "zone": "tenant" } }
JSON
# Runtime cert-refids: the default (wildcard) env has a refid; the per-service
# tenant env has none.
cat > "${WORK}/cert-refids.json" <<'JSON'
{ "base": "abc" }
JSON
assert_eq "$(get_variant_config ""       | jq -r '.dnsMode')" "wildcard"    "default env dnsMode=wildcard"
assert_eq "$(get_variant_config tenant   | jq -r '.dnsMode')" "per-service" "tenant env dnsMode=per-service"
assert_eq "$(get_variant_config ""       | jq -r '.tlsCertRefid')" "abc"    "wildcard env carries a tlsCertRefid"
assert_eq "$(get_variant_config tenant   | jq -r '.tlsCertRefid')" ""       "per-service env has no tlsCertRefid"

# ── #504 interim: wildcard split-horizon = env service-zone gateway, not DMZ ──
# acme-setup.sh derives the wildcard target as zone_gateway_ip(env's .network.zone).
# Verify that composition against the home/work/mgmt/dmz zones.json from above.
cat > "${WORK}/environments/wild.json" <<'JSON'
{ "name": "wild", "displayName": "Wild", "ownerOrg": "t",
  "domains": { "primary": "wild.example", "dnsMode": "wildcard" },
  "network": { "zone": "work" } }
JSON
WILD_ZONE="$(get_variant_config wild | jq -r '.zone')"
assert_eq "${WILD_ZONE}" "work" "wildcard env exposes its service zone"
assert_eq "$(zone_gateway_ip "${WILD_ZONE}")" "10.3.20.1" \
    "wildcard split-horizon -> env service-zone gateway (#504 interim), not the DMZ 10.6.0.1"

echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
