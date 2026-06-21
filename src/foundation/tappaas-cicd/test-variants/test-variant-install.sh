#!/usr/bin/env bash
#
# test-variant-install.sh — ADR-005 Sprint 3 tests.
#
# Offline (always): registry-driven field derivation in copy-update-json.sh and
# the unregistered-variant guard in copy-update-json.sh + install-module.sh.
#
# Integration (only when TAPPAAS_TEST_DEEP=1): registers a variant, installs the
# tvbase fixture against it on the mgmt zone, verifies the derived
# VM/name, then tears everything down. Uses VMID range 8900-8999.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly FIX="${SCRIPT_DIR}/fixtures"
readonly SCRIPTS="${SCRIPT_DIR}/../manager/module-manager"
readonly DEEP="${TAPPAAS_TEST_DEEP:-0}"

# For vm_exists_on_cluster in the deep section (harmless offline).
# shellcheck disable=SC1091
. /home/tappaas/bin/common-install-routines.sh 2>/dev/null || true

PASS=0
FAIL=0
pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got '$1' expected '$2')"; fi; }

echo "test-variant-install: registry-driven install (ADR-005 Sprint 3)"

# ── Offline: copy-update-json registry derivation ────────────────────
OWORK="$(mktemp -d)"; OSRC="$(mktemp -d)"
trap 'rm -rf "${OWORK}" "${OSRC}"' EXIT

cat > "${OWORK}/configuration.json" <<'JSON'
{ "tappaas": { "domain": "base.org", "email": "a@b.org", "variants": {
  "demo": { "domain": "demo.example.com", "tlsCertRefid": "", "dnsMode": "wildcard", "zone": "demoZone", "description": "d" },
  "nozone": { "domain": "nz.example.com", "tlsCertRefid": "", "dnsMode": "wildcard", "description": "no zone" } } } }
JSON
echo '{}' > "${OWORK}/zones.json"
cp "${FIX}/tvbase.json" "${OSRC}/tvbase.json"

(
    cd "${OSRC}" || exit 1
    CONFIG_DIR="${OWORK}" "${SCRIPTS}/copy-update-json.sh" tvbase --variant demo --vmid 8901 >/dev/null 2>&1
)
D="${OWORK}/tvbase-demo.json"
if [[ -f "${D}" ]]; then
    assert_eq "$(jq -r '.vmname' "${D}")"      "tvbase-demo"          "VI-04a vmname = tvbase-demo"
    assert_eq "$(jq -r '.proxyDomain' "${D}")" "tvbase.demo.example.com" "VI-04 proxyDomain derived from variant domain"
    assert_eq "$(jq -r '.zone0' "${D}")"       "demoZone"                        "VI-05 zone0 overridden from variant registry"
    assert_eq "$(jq -r '.variant' "${D}")"     "demo"                            "VI-04b variant field persisted"
else
    fail "VI-04/05 copy-update-json did not produce ${D}"
fi

# Variant without a zone: module keeps its own zone0 (mgmt), proxyDomain uses domain
(
    cd "${OSRC}" || exit 1
    CONFIG_DIR="${OWORK}" "${SCRIPTS}/copy-update-json.sh" tvbase --variant nozone --vmid 8902 >/dev/null 2>&1
)
DN="${OWORK}/tvbase-nozone.json"
if [[ -f "${DN}" ]]; then
    assert_eq "$(jq -r '.zone0' "${DN}")"       "mgmt"                              "VI-05b no-zone variant keeps module zone0 (mgmt)"
    assert_eq "$(jq -r '.proxyDomain' "${DN}")" "tvbase.nz.example.com" "VI-05c proxyDomain uses variant domain (no zone)"
else
    fail "VI-05b copy-update-json did not produce ${DN}"
fi

# VI-06: unregistered variant errors (copy-update-json)
if (cd "${OSRC}" && CONFIG_DIR="${OWORK}" "${SCRIPTS}/copy-update-json.sh" tvbase --variant ghost --vmid 8903 >/dev/null 2>&1); then
    fail "VI-06a copy-update-json should reject unregistered variant"
else
    pass "VI-06a copy-update-json rejects unregistered variant 'ghost'"
fi

# VI-06b: unregistered variant errors early in install-module (before any resource)
if (cd "${OSRC}" && CONFIG_DIR="${OWORK}" "${SCRIPTS}/install-module.sh" tvbase --variant ghost >/dev/null 2>&1); then
    fail "VI-06b install-module should reject unregistered variant"
else
    pass "VI-06b install-module rejects unregistered variant 'ghost' (fails fast)"
fi

# ── Integration (cluster) — only with TAPPAAS_TEST_DEEP=1 ────────────
if [[ "${DEEP}" -eq 1 ]]; then
    echo "  [deep] integration install on mgmt (creates/destroys a real VM)..."
    VAR="vitest"
    cleanup_deep() {
        /home/tappaas/bin/delete-module.sh "tvbase-${VAR}" --force >/dev/null 2>&1 || true
        /home/tappaas/bin/variant-manager remove "${VAR}" --force >/dev/null 2>&1 || true
    }
    trap 'cleanup_deep; rm -rf "${OWORK}" "${OSRC}"' EXIT

    if /home/tappaas/bin/variant-manager add "${VAR}" --domain "${VAR}.test2.tapaas.org" >/dev/null 2>&1; then
        pass "deep: registered variant ${VAR}"
    else
        fail "deep: could not register variant ${VAR}"
    fi

    if ( cd "${FIX}" && /home/tappaas/bin/install-module.sh tvbase --variant "${VAR}" --vmid 8901 ); then
        pass "VI-01 install tvbase --variant ${VAR} succeeded"
    else
        fail "VI-01 variant install failed"
    fi

    cfg="/home/tappaas/config/tvbase-${VAR}.json"
    if [[ -f "${cfg}" ]]; then
        assert_eq "$(jq -r '.vmname' "${cfg}")"  "tvbase-${VAR}" "VI-03 installed config vmname"
        assert_eq "$(jq -r '.variant' "${cfg}")" "${VAR}"                   "VI-03 installed config variant"
        vmid="$(jq -r '.vmid' "${cfg}")"
        if [[ -n "${vmid}" ]] && vm_exists_on_cluster "${vmid}" "$(jq -r '.node // "tappaas1"' "${cfg}").mgmt.internal" >/dev/null 2>&1; then
            pass "VI-03 VM ${vmid} exists on cluster"
        else
            fail "VI-03 VM not found on cluster"
        fi
    else
        fail "VI-03 installed config not found: ${cfg}"
    fi
    # VI-08 delete handled by cleanup_deep trap.
else
    echo "  (integration install skipped — set TAPPAAS_TEST_DEEP=1 to run)"
fi

echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
