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
    for t in reconcile client evacuate fleet; do
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

# ── #501/#567: the orphan check honours integratesWith, not just dependsOn ──
# A module that INTEGRATES with a provider carries that provider's fields just
# as legitimately as one that depends on it — considering only dependsOn made
# every such field look orphaned (the KI-1 family of warning, reopened the
# moment #501 landed and the foundation VMs started using integratesWith).
echo ""
echo "== normalizer: integratesWith fields are not orphans (#501) =="
_cjc="${HERE}/convert-json-to-config.sh"
if [[ -f "${_cjc}" ]] && [[ -f "${CONFIG_DIR:-/home/tappaas/config}/module-fields.json" ]]; then
    _tmpdir="$(mktemp -d)"
    cat > "${_tmpdir}/m.json" <<'JSON'
{
  "vmname": "m",
  "vmid": 900,
  "kind": "module",
  "dependsOn": ["cluster:vm"],
  "integratesWith": ["backup:vm"],
  "backup": { "enabled": true }
}
JSON
    _out="$(bash "${_cjc}" --dry-run "${_tmpdir}/m.json" 2>&1)"
    if grep -q "is usedBy=.* but the module does not depend" <<<"${_out}"; then
        bad "a field owned by an integratesWith provider is reported as an orphan (#501)"
    else
        ok "a field owned by an integratesWith provider is NOT an orphan"
    fi
    # And the opposite still holds: a module wired to NEITHER still warns.
    cat > "${_tmpdir}/n.json" <<'JSON'
{ "vmname": "n", "vmid": 901, "kind": "module", "dependsOn": ["cluster:vm"], "backup": { "enabled": true } }
JSON
    _out="$(bash "${_cjc}" --dry-run "${_tmpdir}/n.json" 2>&1)"
    if grep -q "is usedBy=.* but the module does not depend" <<<"${_out}"; then
        ok "a genuinely orphaned field is still reported"
    else
        bad "the orphan check no longer reports a genuinely orphaned field"
    fi
    rm -rf "${_tmpdir}"
else
    echo "  SKIP: convert-json-to-config.sh or the composed schema not available"
fi

# ── ADR-012 §2.4 (#382): node-add reconciles the backup client ────────
# A node that joins after backup was installed has no proxmox-backup-client
# until the backup module's reconcile runs, so every VM placed on it would be
# silently unbacked. The ADR requires this to be an AUTOMATIC step in node-add,
# explicitly not a documented manual follow-up — assert it is wired that way,
# in the right place, and non-fatal.
echo ""
echo "== node-add wires the backup client reconcile (ADR-012 §2.4, #382) =="
_prov="${HERE}/src/provision.ts"
if [[ -f "${_prov}" ]]; then
    if grep -q '"module-manager", \["modify", "backup"' "${_prov}"; then
        ok "node add calls 'module-manager modify backup' (the client reconcile)"
    else
        bad "node add does NOT reconcile the backup client — a new node's VMs would go unbacked (#382)"
    fi
    # After the join + capture + storage registration: reconciling before the
    # node is actually in the cluster would reconcile the OLD membership.
    _n_storage="$(grep -n "registering the node in its pools" "${_prov}" | head -1 | cut -d: -f1)"
    _n_backup="$(grep -n 'modify", "backup"' "${_prov}" | head -1 | cut -d: -f1)"
    if [[ -n "${_n_storage}" && -n "${_n_backup}" && "${_n_backup}" -gt "${_n_storage}" ]]; then
        ok "the reconcile runs after the node is joined, captured and storage-registered"
    else
        bad "the backup reconcile is not sequenced after node capture/storage registration"
    fi
    if grep -A 4 'modify", "backup"' "${_prov}" | grep -q "warn("; then
        ok "a failed reconcile warns (the node is already joined — it must not fail the join)"
    else
        bad "a failed backup reconcile is fatal to node add — it should warn and name the remedy"
    fi
else
    echo "  SKIP: src/provision.ts not found"
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
