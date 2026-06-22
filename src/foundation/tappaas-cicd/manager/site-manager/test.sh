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
#   - dropped fields absent: domain / email / variants / nodeCount
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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATE="${HERE}/migrate-configuration.sh"
MIGRATE_ALIAS="${HERE}/migrate-configuration-to-site.sh"
VALIDATE="${HERE}/validate-site.sh"
FOUNDATION_DIR="$(cd "${HERE}/../../.." && pwd)"
SCHEMA_DIR="${FOUNDATION_DIR}/schemas"
FIXTURE="${HERE}/test/fixtures/configuration.json"

PASS=0
FAIL=0
ok()  { echo "  ok: $*";   PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/site-test.XXXXXX")"
cleanup() { [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf -- "$WORK"; return 0; }
trap cleanup EXIT INT TERM

run_migrate()  { "$MIGRATE"  --config-dir "$1" "${@:2}" >/dev/null 2>&1; }
run_validate() { "$VALIDATE" --schema-dir "$SCHEMA_DIR" --quiet "$1" >/dev/null 2>&1; }
jqv() { jq -r "$2" "$1" 2>/dev/null; }

# Sanity: prerequisites
[[ -x "$MIGRATE"  ]] || { echo "FATAL: migrate-configuration.sh missing/not executable"; exit 1; }
[[ -x "$VALIDATE" ]] || { echo "FATAL: validate-site.sh missing/not executable"; exit 1; }
[[ -f "$FIXTURE"  ]] || { echo "FATAL: fixture configuration.json missing"; exit 1; }
[[ -f "$SCHEMA_DIR/site-fields.json" ]] || { echo "FATAL: site-fields.json schema missing"; exit 1; }

echo "== FAST tests (temp copy of fixture; live config untouched) =="

# --- Case 1: plain migration (no people/organizations present) ---
C1="${WORK}/case1"
mkdir -p "$C1"
cp "$FIXTURE" "$C1/configuration.json"

if run_migrate "$C1"; then ok "migration runs"; else bad "migration failed"; fi
SITE="$C1/site.json"

if [[ -f "$SITE" ]]; then ok "site.json created"; else bad "site.json not created"; fi

# configuration.json must NOT be deleted, and a .bak must exist
if [[ -f "$C1/configuration.json" ]]; then ok "configuration.json preserved"; else bad "configuration.json was deleted"; fi
if [[ -f "$C1/configuration.json.bak" ]]; then ok "configuration.json.bak backup written"; else bad "no .bak backup"; fi

# schema validation
if run_validate "$SITE"; then ok "site.json validates against schema"; else bad "site.json failed schema validation"; fi

# mapped fields
[[ "$(jqv "$SITE" '.name')" == "foo" ]] && ok "name derived from domain label (foo)" || bad "name not derived (got '$(jqv "$SITE" '.name')')"
[[ "$(jqv "$SITE" '.displayName')" == "foo" ]] && ok "displayName defaults to name" || bad "displayName wrong"
[[ "$(jqv "$SITE" '.version')" == "nixos-template-v1.3" ]] && ok "version carried over" || bad "version wrong"
[[ -n "$(jqv "$SITE" '.location.timezone')" && "$(jqv "$SITE" '.location.timezone')" != "null" ]] && ok "location.timezone present ($(jqv "$SITE" '.location.timezone'))" || bad "location.timezone missing"
[[ "$(jqv "$SITE" '.location.country' | grep -cE '^[A-Za-z]{2}$')" == "1" ]] && ok "location.country is 2-letter ($(jqv "$SITE" '.location.country'))" || bad "location.country wrong"
[[ -n "$(jqv "$SITE" '.location.locale')" ]] && ok "location.locale present ($(jqv "$SITE" '.location.locale'))" || bad "location.locale missing"
[[ "$(jqv "$SITE" '.network.publicIp')" == "auto" ]] && ok "network.publicIp = auto" || bad "network.publicIp wrong"
[[ "$(jqv "$SITE" '.network.isp')" == "null" ]] && ok "network.isp = null" || bad "network.isp not null"

# hardware.nodes mapped from tappaas-nodes
[[ "$(jqv "$SITE" '.hardware.nodes | length')" == "3" ]] && ok "hardware.nodes has 3 nodes" || bad "node count wrong"
[[ "$(jqv "$SITE" '.hardware.nodes[0].name')" == "tappaas1" ]] && ok "node[0].name = tappaas1 (from .hostname)" || bad "node name not mapped"
[[ "$(jqv "$SITE" '.hardware.nodes[0].storagePools | type')" == "array" && "$(jqv "$SITE" '.hardware.nodes[0].storagePools | length')" == "0" ]] && ok "node storagePools is empty array" || bad "storagePools wrong"
# the source has no storagePools and ip must not leak into the node object
[[ "$(jqv "$SITE" '.hardware.nodes[0] | has("ip")')" == "false" ]] && ok "node ip dropped (not a site field)" || bad "node ip leaked"

# updateSchedule / automaticReboot / snapshotRetention
[[ "$(jqv "$SITE" '.updateSchedule | join(",")')" == "weekly,Tuesday,2" ]] && ok "updateSchedule carried over" || bad "updateSchedule wrong"
[[ "$(jqv "$SITE" '.automaticReboot')" == "false" ]] && ok "automaticReboot carried over (false)" || bad "automaticReboot wrong"
[[ "$(jqv "$SITE" '.snapshotRetention')" == "5" ]] && ok "snapshotRetention defaulted to 5" || bad "snapshotRetention wrong"

# repositories carried
[[ "$(jqv "$SITE" '.repositories[0].name')" == "TAPPaaS" ]] && ok "repositories carried over" || bad "repositories not carried"

# backup null, environments empty (S4 populates)
[[ "$(jqv "$SITE" '.backup')" == "null" ]] && ok "backup = null" || bad "backup not null"
[[ "$(jqv "$SITE" '.environments | length')" == "0" ]] && ok "environments = [] (S4 populates)" || bad "environments not empty"

# DROPPED fields must be absent from site.json
[[ "$(jqv "$SITE" 'has("domain")')" == "false" ]] && ok "domain DROPPED" || bad "domain leaked"
[[ "$(jqv "$SITE" 'has("email")')" == "false" ]] && ok "email DROPPED" || bad "email leaked"
[[ "$(jqv "$SITE" 'has("variants")')" == "false" ]] && ok "variants DROPPED" || bad "variants leaked"
[[ "$(jqv "$SITE" 'has("nodeCount")')" == "false" ]] && ok "nodeCount DROPPED" || bad "nodeCount leaked"
# owner empty when no orgs present
[[ "$(jqv "$SITE" '.owner')" == "" ]] && ok "owner empty when no organizations present" || bad "owner unexpectedly set"

# --- Case 1b: idempotency (2nd run is a no-op, does not change site.json) ---
SUM_BEFORE="$(sha256sum "$SITE" | cut -d' ' -f1)"
if run_migrate "$C1"; then ok "2nd migration run exits 0 (no-op)"; else bad "2nd run failed"; fi
SUM_AFTER="$(sha256sum "$SITE" | cut -d' ' -f1)"
[[ "$SUM_BEFORE" == "$SUM_AFTER" ]] && ok "site.json unchanged on re-run (idempotent)" || bad "site.json changed on re-run"

# --force overwrites and still validates
if run_migrate "$C1" --force; then ok "--force re-run exits 0"; else bad "--force run failed"; fi
run_validate "$SITE" && ok "site.json still valid after --force" || bad "site.json invalid after --force"

# --- Case 1c: the alias resolves to the same behaviour ---
[[ -e "$MIGRATE_ALIAS" ]] && ok "migrate-configuration-to-site.sh alias exists" || bad "alias missing"

# --- Case 2: owner derived from config/people/organizations/ ---
C2="${WORK}/case2"
mkdir -p "$C2/people/organizations"
cp "$FIXTURE" "$C2/configuration.json"
cat > "$C2/people/organizations/foo.json" <<'JSON'
{ "name": "foo", "type": "company", "displayName": "Foo BV", "owner": "admin" }
JSON
if run_migrate "$C2"; then ok "migration with organizations runs"; else bad "migration (case2) failed"; fi
SITE2="$C2/site.json"
[[ "$(jqv "$SITE2" '.owner')" == "foo" ]] && ok "owner derived from organizations (foo)" || bad "owner not derived (got '$(jqv "$SITE2" '.owner')')"
[[ "$(jqv "$SITE2" '.organizations[0]')" == "config/people/organizations/foo.json" ]] && ok "organizations[] references org file" || bad "organizations[] not populated"
run_validate "$SITE2" && ok "site.json (case2) validates" || bad "site.json (case2) invalid"

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
    echo "== DEEP tests: none for site-manager (S3a is all fast) =="
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
