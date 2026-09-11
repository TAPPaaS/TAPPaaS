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

# ── proxy_split_horizon_target (ADR-021 D5, supersedes #504) ─────────
# The per-module client-zone rule these tests used to assert is GONE. It was one
# of three transcriptions that disagreed on a live site (#577); ADR-021 D2
# replaced it with a single answer — the DMZ gateway, for every caller — and D5
# made `network-manager split-horizon-target` its only implementation. What is
# left to test here is that the shell wrapper is a faithful pass-through of that
# command's stdout and, crucially, of its exit codes: 0 publish / 3 unpublished
# / 1 error. A caller that cannot tell 3 from 1 turns R3's supported
# "not published" state back into an error, which is the behaviour ADR-021 R3
# exists to remove.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../../network/services/proxy/access-list.sh"
ZF="${WORK}/zones.json"

# Stub `network-manager` on PATH so the wrapper is tested, not the resolver
# (the rule itself is unit-tested in network-manager's own suite).
STUB="${WORK}/stub-bin"
mkdir -p "${STUB}"
mk_stub() {  # $1 = stdout, $2 = exit code
    cat > "${STUB}/network-manager" <<STUBEOF
#!/usr/bin/env bash
[[ -n "$1" ]] && printf '%s\n' "$1"
echo "split-horizon: diagnostic on stderr" >&2
exit $2
STUBEOF
    chmod +x "${STUB}/network-manager"
}
PATH="${STUB}:${PATH}"

mk_stub "10.6.0.1" 0
assert_eq "$(proxy_split_horizon_target openwebui.example.org "${ZF}" 2>/dev/null)" "10.6.0.1" \
    "published -> the DMZ gateway is passed through on stdout"

# A second name must get the SAME answer: one record, not one per service.
assert_eq "$(proxy_split_horizon_target cloud.example.org "${ZF}" 2>/dev/null)" "10.6.0.1" \
    "a different name gets the same address (no per-service derivation)"

mk_stub "" 3
out="$(proxy_split_horizon_target internal.example.org "${ZF}" 2>/dev/null)"; rc=$?
if [[ ${rc} -eq 3 && -z "${out}" ]]; then
    pass "unpublished -> rc 3 and no address (R3: a state, not a failure)"
else
    fail "unpublished should be rc 3 with empty stdout (got rc=${rc} out='${out}')"
fi

mk_stub "" 1
out="$(proxy_split_horizon_target broken.example.org "${ZF}" 2>/dev/null)"; rc=$?
if [[ ${rc} -eq 1 && -z "${out}" ]]; then
    pass "error -> rc 1, distinct from unpublished"
else
    fail "error should be rc 1 with empty stdout (got rc=${rc} out='${out}')"
fi

# The wrapper must never print a stale address on a failing exit — a caller that
# command-substitutes it would otherwise register a wrong record.
mk_stub "10.6.0.1" 3
assert_eq "$(proxy_split_horizon_target internal.example.org "${ZF}" 2>/dev/null)" "" \
    "no address is emitted on a non-zero exit, even if the command printed one"

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

# ── ADR-021 D2: the wildcard target does NOT depend on the environment ───────
# acme-setup.sh used to derive the wildcard target as
# zone_gateway_ip(env's .network.zone) — the #504 interim rule, and one of the
# three disagreeing transcriptions of #577. It now asks
# `network-manager split-horizon-target`, which answers the DMZ gateway for every
# domain. The environment still exposes its service zone (modules land there);
# what changed is that the DNS answer no longer reads it.
cat > "${WORK}/environments/wild.json" <<'JSON'
{ "name": "wild", "displayName": "Wild", "ownerOrg": "t",
  "domains": { "primary": "wild.example", "dnsMode": "wildcard" },
  "network": { "zone": "work" } }
JSON
WILD_ZONE="$(get_variant_config wild | jq -r '.zone')"
assert_eq "${WILD_ZONE}" "work" "wildcard env still exposes its service zone (modules land there)"
mk_stub "10.6.0.1" 0
assert_eq "$(proxy_split_horizon_target wild.example "${ZF}" 2>/dev/null)" "10.6.0.1" \
    "wildcard split-horizon -> the DMZ gateway, NOT the env service zone (ADR-021 D2)"
# The env's own zone gateway is still derivable — it is simply no longer the
# split-horizon answer. Asserting both keeps the distinction explicit.
assert_eq "$(zone_gateway_ip "${WILD_ZONE}")" "10.3.20.1" \
    "the env service-zone gateway is still derivable, it is just not the DNS answer"

echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
