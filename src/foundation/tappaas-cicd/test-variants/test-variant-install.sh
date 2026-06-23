#!/usr/bin/env bash
#
# test-variant-install.sh — environment-driven install tests (ADR-007).
#
# The legacy ADR-005 variant registry is retired (ADR-007 Phase D). Modules now
# deploy via --environment + config/environments/<env>.json; --variant is a pure
# deprecated alias for --environment.
#
# Offline (always): copy-update-json.sh suffixes the effective module name for a
# non-default environment and persists .environment/.variant; install-module.sh
# rejects an unregistered environment (no config/environments/<env>.json).
#
# Integration (only when TAPPAAS_TEST_DEEP=1): authors a 'vitest' environment,
# installs the tvbase fixture against it on the mgmt zone, verifies the derived
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

echo "test-variant-install: environment-driven install (ADR-007)"

# ── Offline: copy-update-json environment suffixing + persistence ─────
OWORK="$(mktemp -d)"; OSRC="$(mktemp -d)"
trap 'rm -rf "${OWORK}" "${OSRC}"' EXIT

# A minimal site + a registered 'demo' environment. No configuration.json.
cat > "${OWORK}/site.json" <<'JSON'
{ "name": "base", "displayName": "Base", "owner": "test2",
  "hardware": { "nodes": [ { "name": "tappaas1" } ] } }
JSON
echo '{}' > "${OWORK}/zones.json"
mkdir -p "${OWORK}/environments"
cat > "${OWORK}/environments/demo.json" <<'JSON'
{ "name": "demo", "displayName": "Demo", "ownerOrg": "test2",
  "domains": { "primary": "demo.example.com", "dnsMode": "wildcard" },
  "network": { "zone": "demoZone" } }
JSON
cp "${FIX}/tvbase.json" "${OSRC}/tvbase.json"

# VI-04: --environment demo suffixes the effective module name and persists the
# environment (and mirrors .variant for a non-default, non-mgmt environment).
(
    cd "${OSRC}" || exit 1
    CONFIG_DIR="${OWORK}" "${SCRIPTS}/copy-update-json.sh" tvbase --environment demo --vmid 8901 >/dev/null 2>&1
)
D="${OWORK}/tvbase-demo.json"
if [[ -f "${D}" ]]; then
    assert_eq "$(jq -r '.environment' "${D}")" "demo" "VI-04a .environment persisted = demo"
    assert_eq "$(jq -r '.variant' "${D}")"     "demo" "VI-04b .variant mirrored = demo (non-default env)"
    assert_eq "$(jq -r '.vmid' "${D}")"        "8901" "VI-04c explicit --vmid override applied"
else
    fail "VI-04 copy-update-json did not produce ${D}"
fi

# VI-05: --variant is a pure deprecated alias for --environment (same output).
(
    cd "${OSRC}" || exit 1
    CONFIG_DIR="${OWORK}" "${SCRIPTS}/copy-update-json.sh" tvbase --variant demo --vmid 8902 >/dev/null 2>&1
)
if [[ -f "${D}" ]]; then
    assert_eq "$(jq -r '.environment' "${D}")" "demo" "VI-05 --variant alias persists .environment = demo"
else
    fail "VI-05 --variant alias did not produce ${D}"
fi

# VI-06a: unregistered environment — copy-update-json still copies (it does not
# validate the env exists), but the effective name is suffixed. The hard reject
# lives in install-module (VI-06b).
(
    cd "${OSRC}" || exit 1
    CONFIG_DIR="${OWORK}" "${SCRIPTS}/copy-update-json.sh" tvbase --environment ghost --vmid 8903 >/dev/null 2>&1
)
if [[ -f "${OWORK}/tvbase-ghost.json" ]]; then
    assert_eq "$(jq -r '.environment' "${OWORK}/tvbase-ghost.json")" "ghost" "VI-06a copy-update-json suffixes for any env name"
else
    fail "VI-06a copy-update-json did not produce tvbase-ghost.json"
fi

# VI-06b: unregistered environment errors early in install-module (before any
# resource is touched) — no config/environments/ghost.json exists.
if (cd "${OSRC}" && CONFIG_DIR="${OWORK}" "${SCRIPTS}/install-module.sh" tvbase --environment ghost >/dev/null 2>&1); then
    fail "VI-06b install-module should reject unregistered environment"
else
    pass "VI-06b install-module rejects unregistered environment 'ghost' (fails fast)"
fi

# ── Integration (cluster) — only with TAPPAAS_TEST_DEEP=1 ────────────
if [[ "${DEEP}" -eq 1 ]]; then
    echo "  [deep] integration install on mgmt (creates/destroys a real VM)..."
    VAR="vitest"
    ENV_FILE="/home/tappaas/config/environments/${VAR}.json"
    cleanup_deep() {
        /home/tappaas/bin/delete-module.sh "tvbase-${VAR}" --force >/dev/null 2>&1 || true
        rm -f "${ENV_FILE}" 2>/dev/null || true
    }
    trap 'cleanup_deep; rm -rf "${OWORK}" "${OSRC}"' EXIT

    # Author the vitest environment (the source of truth; no variant registry).
    mkdir -p "$(dirname "${ENV_FILE}")"
    owner="$(jq -r '.owner // empty' /home/tappaas/config/site.json 2>/dev/null)"
    [[ -n "${owner}" ]] || owner="$(ls /home/tappaas/config/people/organizations/*.json 2>/dev/null | head -1 | xargs -r basename | sed 's/\.json$//')"
    if jq -n --arg n "${VAR}" --arg owner "${owner}" --arg d "${VAR}.test2.tapaas.org" '
            { name: $n, displayName: $n, ownerOrg: $owner,
              domains: { primary: $d, dnsMode: "wildcard" },
              network: { zone: "mgmt" } }' > "${ENV_FILE}"; then
        pass "deep: authored environment ${VAR}"
    else
        fail "deep: could not author environment ${VAR}"
    fi

    if ( cd "${FIX}" && /home/tappaas/bin/install-module.sh tvbase --environment "${VAR}" --vmid 8901 ); then
        pass "VI-01 install tvbase --environment ${VAR} succeeded"
    else
        fail "VI-01 environment install failed"
    fi

    cfg="/home/tappaas/config/tvbase-${VAR}.json"
    if [[ -f "${cfg}" ]]; then
        assert_eq "$(jq -r '.vmname' "${cfg}")"      "tvbase-${VAR}" "VI-03 installed config vmname"
        assert_eq "$(jq -r '.environment' "${cfg}")" "${VAR}"        "VI-03 installed config environment"
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
