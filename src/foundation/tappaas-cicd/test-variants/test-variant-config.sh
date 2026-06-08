#!/usr/bin/env bash
#
# test-variant-config.sh — ADR-005 Sprint 1 unit tests (offline, no cluster).
#
# Covers:
#   - get_variant_config        (VM-12, VM-13, VM-14)
#   - resolve_provider_module   (#292 same-variant preference / fallback)
#
# These exercise the library functions in common-install-routines.sh against a
# throwaway CONFIG_DIR fixture, so they are fast and require no cluster.
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
. "${SCRIPT_DIR}/../scripts/common-install-routines.sh"

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

echo "test-variant-config: get_variant_config + resolve_provider_module (ADR-005 Sprint 1)"

# ── Fixtures ─────────────────────────────────────────────────────────
# Config with a variant registry (default "" + "demo").
write_registry_config() {
    cat > "${CONFIG_DIR}/configuration.json" <<'JSON'
{
  "tappaas": {
    "domain": "foo.org",
    "email": "admin@foo.org",
    "variants": {
      "": { "domain": "foo.org", "tlsCertRefid": "abc", "dnsMode": "wildcard", "description": "Default" },
      "demo": { "domain": "demo.foo.org", "tlsCertRefid": "def", "dnsMode": "per-service", "zone": "demo", "description": "Demo env" }
    }
  }
}
JSON
}
# Legacy config: only tappaas.domain, no variants registry.
write_legacy_config() {
    cat > "${CONFIG_DIR}/configuration.json" <<'JSON'
{
  "tappaas": {
    "domain": "legacy.org",
    "tlsCertRefid": "legacycert",
    "email": "admin@legacy.org"
  }
}
JSON
}

# ── VM-12: default variant from registry ─────────────────────────────
write_registry_config
out="$(get_variant_config "")"
if [[ "$(jq -r '.domain' <<<"${out}")" == "foo.org" ]]; then
    pass "VM-12 get_variant_config \"\" returns default variant (domain=foo.org)"
else
    fail "VM-12 get_variant_config \"\" -> ${out}"
fi

# ── VM-13: named variant from registry ───────────────────────────────
out="$(get_variant_config "demo")"
if [[ "$(jq -r '.domain' <<<"${out}")" == "demo.foo.org" \
   && "$(jq -r '.dnsMode' <<<"${out}")" == "per-service" \
   && "$(jq -r '.zone' <<<"${out}")" == "demo" ]]; then
    pass "VM-13 get_variant_config demo returns demo variant (domain/dnsMode/zone)"
else
    fail "VM-13 get_variant_config demo -> ${out}"
fi

# ── VM-13b: unregistered variant errors ──────────────────────────────
if get_variant_config "ghost" >/dev/null 2>&1; then
    fail "VM-13b get_variant_config ghost should fail (not registered)"
else
    pass "VM-13b get_variant_config ghost fails cleanly (unregistered)"
fi

# ── VM-14: legacy fallback to tappaas.domain ─────────────────────────
write_legacy_config
out="$(get_variant_config "")"
if [[ "$(jq -r '.domain' <<<"${out}")" == "legacy.org" \
   && "$(jq -r '.tlsCertRefid' <<<"${out}")" == "legacycert" ]]; then
    pass "VM-14 get_variant_config \"\" falls back to legacy tappaas.domain"
else
    fail "VM-14 get_variant_config \"\" legacy -> ${out}"
fi
# Legacy fallback must NOT invent non-default variants.
if get_variant_config "demo" >/dev/null 2>&1; then
    fail "VM-14b legacy: get_variant_config demo should fail (no registry)"
else
    pass "VM-14b legacy: named variant has no fallback (fails cleanly)"
fi

# ── #292: resolve_provider_module preference/fallback ────────────────
write_registry_config
: > "${CONFIG_DIR}/litellm.json"          # base provider config exists
: > "${CONFIG_DIR}/litellm-demo.json"     # same-variant provider config exists

assert_eq "$(resolve_provider_module litellm demo)"    "litellm-demo" "#292 resolve litellm+demo -> litellm-demo (same-variant)"
assert_eq "$(resolve_provider_module litellm "")"      "litellm"      "#292 resolve litellm+\"\" -> litellm (default)"
assert_eq "$(resolve_provider_module litellm staging)" "litellm"      "#292 resolve litellm+staging -> litellm (no variant cfg, fallback)"
# Foundation-style dep with a variant: no cluster-demo.json -> falls back to cluster.
assert_eq "$(resolve_provider_module cluster demo)"    "cluster"      "#292 resolve cluster+demo -> cluster (foundation, variant-agnostic)"

echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
