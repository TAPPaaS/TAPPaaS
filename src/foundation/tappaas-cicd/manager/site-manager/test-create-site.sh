#!/usr/bin/env bash
#
# test-create-site.sh — tests for create-site.sh (ADR-007 P2 / S3b+).
#
# SAFE: operates entirely inside a TEMP --config-dir — NEVER the live config.
# create-site.sh's cluster discovery is READ-ONLY (pvesh / zpool list over ssh);
# if the cluster is unreachable in the test environment, node-dependent asserts
# are SKIPPED (counted, not failed) rather than failing the suite.
#
# Covers:
#   - create-site.sh --name testsite writes site.json (isolated config dir)
#   - site.json .name == "testsite"
#   - site.json validates against site-fields.json (validate-site.sh)
#   - NO configuration.json is created in the temp dir (site-native)
#   - hardware.nodes[] non-empty when the cluster is reachable (else skip)
#   - non-force re-run REFUSES (exit != 0) and leaves site.json unchanged
#   - --force re-run is idempotent (succeeds, still valid)
#   - --name is required (no --name -> error)
#
# Prints "Results: N passed, M failed, K skipped"; exits 1 on any failure.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATE="${HERE}/create-site.sh"
VALIDATE="${HERE}/validate-site.sh"
FOUNDATION_DIR="$(cd "${HERE}/../../.." && pwd)"
SCHEMA_DIR="${FOUNDATION_DIR}/schemas"

PASS=0
FAIL=0
SKIP=0
ok()   { echo "  ok: $*";   PASS=$((PASS + 1)); }
bad()  { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
skip() { echo "  skip: $*"; SKIP=$((SKIP + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/create-site-test.XXXXXX")"
cleanup() { [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf -- "$WORK"; return 0; }
trap cleanup EXIT INT TERM

jqv() { jq -r "$2" "$1" 2>/dev/null; }
run_validate() { "$VALIDATE" --schema-dir "$SCHEMA_DIR" --quiet "$1" >/dev/null 2>&1; }

# Sanity: prerequisites
[[ -x "$CREATE"   ]] || { echo "FATAL: create-site.sh missing/not executable"; exit 1; }
[[ -x "$VALIDATE" ]] || { echo "FATAL: validate-site.sh missing/not executable"; exit 1; }
[[ -f "$SCHEMA_DIR/site-fields.json" ]] || { echo "FATAL: site-fields.json schema missing"; exit 1; }

echo "== create-site.sh tests (isolated temp --config-dir; live config untouched) =="

# --- Case 0: --name is required ---
C0="${WORK}/case0"
mkdir -p "$C0"
if "$CREATE" --config-dir "$C0" >/dev/null 2>&1; then
    bad "create-site.sh without --name should fail"
else
    ok "create-site.sh without --name correctly refuses"
fi
[[ ! -f "$C0/site.json" ]] && ok "no site.json written when --name missing" || bad "site.json written despite missing --name"

# --- Case 1: create-site.sh --name testsite ---
C1="${WORK}/case1"
mkdir -p "$C1"
"$CREATE" --name testsite --config-dir "$C1" >"$C1/run.log" 2>&1
RC=$?
SITE="$C1/site.json"

if [[ $RC -eq 0 ]]; then ok "create-site.sh --name testsite exits 0"; else bad "create-site.sh exited $RC (see $C1/run.log)"; fi
if [[ -f "$SITE" ]]; then ok "site.json created"; else bad "site.json not created"; fi

# CRITICAL: no configuration.json ever created (site-native)
if [[ ! -f "$C1/configuration.json" ]]; then ok "no configuration.json created (site-native)"; else bad "configuration.json was created"; fi
if [[ ! -f "$C1/configuration.json.bak" ]]; then ok "no configuration.json.bak created"; else bad "configuration.json.bak was created"; fi

# .name == testsite
[[ "$(jqv "$SITE" '.name')" == "testsite" ]] && ok ".name == testsite" || bad ".name wrong (got '$(jqv "$SITE" '.name')')"
# displayName / owner derived from name
[[ "$(jqv "$SITE" '.displayName')" == "testsite" ]] && ok ".displayName derived from name" || bad ".displayName wrong"
[[ "$(jqv "$SITE" '.owner')" == "testsite" ]] && ok ".owner derived from name" || bad ".owner wrong"

# schema validation
if run_validate "$SITE"; then ok "site.json validates against site-fields.json"; else bad "site.json failed schema validation"; fi

# repositories present + correct default shape
[[ "$(jqv "$SITE" '.repositories[0].name')" == "TAPPaaS" ]] && ok "repositories[0].name = TAPPaaS" || bad "repositories not built"
[[ "$(jqv "$SITE" '.repositories[0].branch')" == "stable" ]] && ok "repositories[0].branch = stable (default)" || bad "branch default wrong"

# organizations empty (later steps populate); environments are NOT a site field
[[ "$(jqv "$SITE" 'has("environments")')" == "false" ]] && ok "no .environments field" || bad ".environments should not be written"
[[ "$(jqv "$SITE" '.organizations | length')" == "0" ]] && ok "organizations = []" || bad "organizations not empty"

# hardware.nodes[] non-empty IFF cluster reachable, else skip
NODE_COUNT="$(jqv "$SITE" '.hardware.nodes | length')"
if [[ "$NODE_COUNT" =~ ^[0-9]+$ && "$NODE_COUNT" -gt 0 ]]; then
    ok "hardware.nodes[] non-empty ($NODE_COUNT node(s) discovered)"
    # each node has a storagePools array
    [[ "$(jqv "$SITE" '.hardware.nodes[0].storagePools | type')" == "array" ]] && ok "node[0].storagePools is an array" || bad "storagePools not an array"
    # no ip leaked into node object (site-native node shape)
    [[ "$(jqv "$SITE" '.hardware.nodes[0] | has("ip")')" == "false" ]] && ok "node ip not present (site shape)" || bad "node ip leaked"
else
    skip "cluster unreachable — hardware.nodes[] empty (node asserts skipped)"
fi

# --- Case 2: non-force re-run REFUSES, leaves site.json unchanged ---
SUM_BEFORE="$(sha256sum "$SITE" | cut -d' ' -f1)"
if "$CREATE" --name testsite --config-dir "$C1" >/dev/null 2>&1; then
    bad "non-force re-run should refuse (site.json exists)"
else
    ok "non-force re-run correctly refuses (idempotency guard)"
fi
SUM_AFTER="$(sha256sum "$SITE" | cut -d' ' -f1)"
[[ "$SUM_BEFORE" == "$SUM_AFTER" ]] && ok "site.json unchanged after refused re-run" || bad "site.json changed despite refusal"

# --- Case 3: --force re-run is idempotent + still valid ---
if "$CREATE" --name testsite --config-dir "$C1" --force >/dev/null 2>&1; then
    ok "--force re-run exits 0"
else
    bad "--force re-run failed"
fi
run_validate "$SITE" && ok "site.json still valid after --force" || bad "site.json invalid after --force"
[[ "$(jqv "$SITE" '.name')" == "testsite" ]] && ok ".name still testsite after --force" || bad ".name changed after --force"
# still no configuration.json after force
[[ ! -f "$C1/configuration.json" ]] && ok "still no configuration.json after --force" || bad "configuration.json appeared after --force"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
[[ "$FAIL" -eq 0 ]]
