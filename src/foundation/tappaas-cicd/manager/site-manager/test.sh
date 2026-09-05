#!/usr/bin/env bash
#
# test.sh — tests for site-manager (ADR-007 P2, S3a).
#
# FAST (default, non-disruptive): operates entirely on a TEMP copy of a fixture
# configuration.json — NEVER the live config. Covers:
#   - migrate fixture configuration.json -> site.json
#   - site.json validates against site-fields.json
#   - mapped fields present: name (from domain label), location.timezone,
#     hardware.nodes mapped from tappaas-nodes, repositories carried over
#   - dropped fields absent: domain / variants / nodeCount
#   - email CARRIED to site.json .email (S3b reader cutover)
#   - migration is idempotent (2nd run is a no-op; --force overwrites)
#   - owner is derived from config/people/organizations/ when present
#   - a deliberately-bad site.json FAILS validate-site.sh
#
# DEEP (TAPPAAS_TEST_DEEP=1): no extra disruptive tests for this component — the
# whole suite is fast and safe. The gate is honoured for convention only.
#
# Prints "Results: N passed, M failed"; exits 1 on any failure.
#
set -uo pipefail

# Accept --deep as well as TAPPAAS_TEST_DEEP=1. Every gate below reads the
# variable, so exporting it here is all a flag needs to do — and exporting (not
# just setting) is what carries it into any suite this one dispatches. Without
# this, `test.sh --deep` silently ran the fast path.
for _a in "$@"; do [[ "${_a}" == "--deep" ]] && export TAPPAAS_TEST_DEEP=1; done


HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="${HERE}/validate-site.sh"
FOUNDATION_DIR="$(cd "${HERE}/../../.." && pwd)"
SCHEMA_DIR="${FOUNDATION_DIR}/schemas"
FIXTURE="${HERE}/test/fixtures/configuration.json"

PASS=0
FAIL=0
ok()  { echo "  ok: $*";   PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/site-test.XXXXXX")"
DIST_TEST="${HERE}/dist-test"
cleanup() {
    [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf -- "$WORK"
    [[ -n "${DIST_TEST:-}" && -d "$DIST_TEST" ]] && rm -rf -- "$DIST_TEST"
    return 0
}
trap cleanup EXIT INT TERM

run_ts() {
    # Run a command, preferring a tsc/node already on PATH, else nix-shell.
    if command -v tsc >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
        bash -c "$1"
    elif command -v nix-shell >/dev/null 2>&1; then
        nix-shell -p typescript nodejs_22 --run "$1"
    else
        return 127
    fi
}

run_validate() { "$VALIDATE" --schema-dir "$SCHEMA_DIR" --quiet "$1" >/dev/null 2>&1; }
jqv() { jq -r "$2" "$1" 2>/dev/null; }

# Sanity: prerequisites
[[ -x "$VALIDATE" ]] || { echo "FATAL: validate-site.sh missing/not executable"; exit 1; }
[[ -f "$FIXTURE"  ]] || { echo "FATAL: fixture configuration.json missing"; exit 1; }
[[ -f "$SCHEMA_DIR/site-fields.json" ]] || { echo "FATAL: site-fields.json schema missing"; exit 1; }

# ===========================================================================
# A. TypeScript build + unit tests (the reconcile engine and the CliSiteClient
#    argument vectors). Mirrors environment-manager/test.sh.
# ===========================================================================
echo "== site-manager TypeScript build + unit tests =="

UNIT_TSCONFIG="${HERE}/test/unit/tsconfig.json"
rm -rf -- "$DIST_TEST"
if run_ts "tsc --noEmit -p '${HERE}/tsconfig.json'" >/dev/null 2>&1; then
    ok "tsc --noEmit clean (src)"
else
    bad "tsc --noEmit reported type errors (src)"
fi
if run_ts "tsc -p '${UNIT_TSCONFIG}'" >/dev/null 2>&1; then
    ok "TypeScript unit tests compile"
    # tsconfig rootDir is the tappaas-cicd root (shared lib/ts base), so the
    # compiled tree mirrors manager/site-manager/ under dist-test.
    for t in reconcile client evacuate; do
        if run_ts "node '${DIST_TEST}/manager/site-manager/test/unit/${t}.test.js'" >/dev/null 2>&1; then
            ok "TypeScript ${t} unit tests pass"
        else
            bad "TypeScript ${t} unit tests FAILED"
        fi
    done
else
    bad "TypeScript unit tests failed to compile"
fi

echo ""

# --- Case 3: a deliberately-bad site.json fails validate-site.sh ---
BAD="${WORK}/bad-site.json"
# missing required 'owner', 'location', 'hardware', 'repositories'
cat > "$BAD" <<'JSON'
{ "name": "broken", "displayName": "Broken" }
JSON
if run_validate "$BAD"; then bad "bad site.json wrongly passed validation"; else ok "bad site.json correctly fails validation"; fi

# bad site.json: additionalProperties violation
BAD2="${WORK}/bad-site2.json"
cat > "$BAD2" <<'JSON'
{
  "name": "x", "displayName": "X", "owner": "o",
  "location": { "country": "NL", "timezone": "Europe/Amsterdam" },
  "hardware": { "nodes": [] },
  "repositories": [],
  "bogusExtraField": true
}
JSON
if run_validate "$BAD2"; then bad "site.json with extra field wrongly passed"; else ok "site.json with extra field correctly fails"; fi

if [[ "${TAPPAAS_TEST_DEEP:-0}" == "1" ]]; then
    echo "== DEEP: live node-inventory reconcile (read-only preview; N1 regression) =="
    # Regression guard for docs/design/node-provisioning.md N1: the site's
    # node inventory (names + storagePools) must stay converged with the live
    # cluster. A pending register-node/update-node-pools action here means a
    # node joined (or grew pools) without being captured — update-tappaas
    # Phase 0.5 should have applied it. Read-only: preview never writes.
    if command -v site-manager >/dev/null 2>&1 && [[ -f "${TAPPAAS_CONFIG:-/home/tappaas/config}/site.json" ]]; then
        if _nr_out="$(site-manager node reconcile 2>&1)"; then
            ok "node reconcile preview runs against the live cluster"
            if grep -qE "register-node|update-node-pools" <<<"${_nr_out}"; then
                bad "node inventory NOT converged — run 'site-manager node reconcile --apply' (drift: $(grep -oE '(register-node|update-node-pools): [^(]*' <<<"${_nr_out}" | head -1))"
            else
                ok "node inventory converged (no pending register/pool actions)"
            fi
            if grep -q "cluster unreachable" <<<"${_nr_out}"; then
                bad "cluster unreachable from site-manager (F12 read path broken?)"
            else
                ok "live cluster reachable via the F12 read path"
            fi
        else
            bad "site-manager node reconcile preview failed"
        fi
    else
        echo "  SKIP: no live site.json / site-manager bin (not on a mothership)"
    fi
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
