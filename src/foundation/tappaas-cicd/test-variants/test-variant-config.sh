#!/usr/bin/env bash
#
# test-variant-config.sh — environment-config readers (offline, no cluster).
#
# Covers:
#   - get_variant_config        (VM-12, VM-13, VM-13b) — reads config/environments/
#   - resolve_provider_module   (#292 same-environment preference / fallback)
#
# These exercise the library functions in common-install-routines.sh against a
# throwaway CONFIG_DIR fixture, so they are fast and require no cluster. The
# legacy ADR-005 variant registry (configuration.json .tappaas.variants) is
# retired (ADR-007 Phase D) — get_variant_config reads environment files only.
#

set -uo pipefail
# No `set -e`: the functions return non-zero on the negative cases we assert.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Throwaway config dir — set BEFORE sourcing so common-install-routines adopts it
# (it only defaults CONFIG_DIR when unset).
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export CONFIG_DIR="${WORK}"

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../lib/common-install-routines.sh"

PASS=0
FAIL=0
pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }
# assert_eq <actual> <expected> <label>
assert_eq() {
    if [[ "$1" == "$2" ]]; then
        pass "$3"
    else
        fail "$3 (got '$1', expected '$2')"
    fi
}

echo "test-variant-config: get_variant_config + resolve_provider_module (ADR-007)"

# ── Fixtures ─────────────────────────────────────────────────────────
# site.json names the default environment (.name = "foo"), plus two environment
# files: the default ("foo") and a named one ("demo"). The default env's cert
# refid lives in the runtime cert-refids.json keyed by env name.
mkdir -p "${CONFIG_DIR}/environments"
cat > "${CONFIG_DIR}/site.json" <<'JSON'
{ "name": "foo", "displayName": "Foo", "owner": "test2",
  "email": "admin@foo.org",
  "hardware": { "nodes": [ { "name": "tappaas1" } ] } }
JSON
cat > "${CONFIG_DIR}/environments/foo.json" <<'JSON'
{ "name": "foo", "displayName": "Default", "ownerOrg": "test2",
  "domains": { "primary": "foo.org", "dnsMode": "wildcard" },
  "network": { "zone": "foo" } }
JSON
cat > "${CONFIG_DIR}/environments/demo.json" <<'JSON'
{ "name": "demo", "displayName": "Demo env", "ownerOrg": "test2",
  "domains": { "primary": "demo.foo.org", "dnsMode": "per-service" },
  "network": { "zone": "demo" } }
JSON
cat > "${CONFIG_DIR}/cert-refids.json" <<'JSON'
{ "foo": "abc", "demo": "def" }
JSON

# ── VM-12: default environment ("" -> site.json .name = foo) ──────────
out="$(get_variant_config "")"
if [[ "$(jq -r '.domain' <<<"${out}")" == "foo.org" \
   && "$(jq -r '.tlsCertRefid' <<<"${out}")" == "abc" ]]; then
    pass "VM-12 get_variant_config \"\" returns default environment (domain=foo.org, refid=abc)"
else
    fail "VM-12 get_variant_config \"\" -> ${out}"
fi

# ── VM-13: named environment ─────────────────────────────────────────
out="$(get_variant_config "demo")"
if [[ "$(jq -r '.domain' <<<"${out}")" == "demo.foo.org" \
   && "$(jq -r '.dnsMode' <<<"${out}")" == "per-service" \
   && "$(jq -r '.zone' <<<"${out}")" == "demo" \
   && "$(jq -r '.tlsCertRefid' <<<"${out}")" == "def" ]]; then
    pass "VM-13 get_variant_config demo returns demo environment (domain/dnsMode/zone/refid)"
else
    fail "VM-13 get_variant_config demo -> ${out}"
fi

# ── VM-13b: unknown environment errors ───────────────────────────────
if get_variant_config "ghost" >/dev/null 2>&1; then
    fail "VM-13b get_variant_config ghost should fail (no environment file)"
else
    pass "VM-13b get_variant_config ghost fails cleanly (no config/environments/ghost.json)"
fi

# ── #292: resolve_provider_module preference/fallback ────────────────
: > "${CONFIG_DIR}/litellm.json"          # base provider config exists
: > "${CONFIG_DIR}/litellm-demo.json"     # same-environment provider config exists

assert_eq "$(resolve_provider_module litellm demo)"    "litellm-demo" "#292 resolve litellm+demo -> litellm-demo (same-environment)"
assert_eq "$(resolve_provider_module litellm "")"      "litellm"      "#292 resolve litellm+\"\" -> litellm (default)"
assert_eq "$(resolve_provider_module litellm staging)" "litellm"      "#292 resolve litellm+staging -> litellm (no env cfg, fallback)"
# Foundation-style dep with an environment: no cluster-demo.json -> falls back to cluster.
assert_eq "$(resolve_provider_module cluster demo)"    "cluster"      "#292 resolve cluster+demo -> cluster (foundation, env-agnostic)"

echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
