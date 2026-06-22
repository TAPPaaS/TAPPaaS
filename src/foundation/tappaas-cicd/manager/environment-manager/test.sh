#!/usr/bin/env bash
#
# test.sh — tests for environment-manager (ADR-007 P3).
#
# FAST (default): non-disruptive, runs entirely on TEMP fixtures. Covers
#   variant->environment migration, the bootstrap minimal environments, schema
#   validation, the tlsCertRefid drop/reject rule, and idempotency.
# DEEP (TAPPAAS_TEST_DEEP=1): additionally read-only-validates the LIVE
#   config/environments (if present) against the schema. Never writes to live.
#
# Prints "Results: N passed, M failed"; exits 1 on any failure.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOUNDATION_DIR="$(cd "${HERE}/../../.." && pwd)"
SCHEMA_DIR="${FOUNDATION_DIR}/schemas"

MIGRATE="${HERE}/migrate-variants.sh"
MINIMAL="${HERE}/create-minimal-environments.sh"
VALIDATE="${HERE}/validate-environment.sh"

FIX="${HERE}/test/fixtures"

PASS=0
FAIL=0
ok()  { echo "  ok: $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/env-test.XXXXXX")"
cleanup() { [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf -- "$WORK"; return 0; }
trap cleanup EXIT INT TERM

# Validate a single file/dir quietly against the schema + references.
run_validate() {
    "$VALIDATE" --schema-dir "$SCHEMA_DIR" --config-dir "$1" --quiet "${2:-$1/environments}" >/dev/null 2>&1
}

echo "== environment-manager FAST tests =="

# ---------------------------------------------------------------------------
# 0. Build a fixture config dir (configuration.json + zones.json + people org).
# ---------------------------------------------------------------------------
CFG="${WORK}/config"
mkdir -p "${CFG}/people/organizations"
cp "${FIX}/configuration.json" "${CFG}/configuration.json"
cp "${FIX}/zones.json" "${CFG}/zones.json"
cp "${FIX}/people/organizations/test2.json" "${CFG}/people/organizations/test2.json"

# ---------------------------------------------------------------------------
# 1. Migration: default + named variant -> environments
# ---------------------------------------------------------------------------
if "$MIGRATE" --config-dir "$CFG" >/dev/null 2>&1; then
    ok "migrate-variants.sh runs on fixture configuration.json"
else
    bad "migrate-variants.sh should succeed"
fi

ENVDIR="${CFG}/environments"
[[ -f "${ENVDIR}/default.json" ]] && ok "produced default.json" || bad "expected default.json"
[[ -f "${ENVDIR}/foo.json" ]]     && ok "produced foo.json (named variant)" || bad "expected foo.json"

# ---------------------------------------------------------------------------
# 2. default.json shape: domains.primary + dnsMode + network.zone; NO tlsCertRefid
# ---------------------------------------------------------------------------
D="${ENVDIR}/default.json"
if [[ -f "$D" ]]; then
    [[ "$(jq -r '.name' "$D")" == "default" ]]                  && ok "default.json name=default" || bad "default.json name"
    [[ "$(jq -r '.domains.primary' "$D")" == "test2.tapaas.org" ]] && ok "default.json domains.primary carried over" || bad "default.json domains.primary"
    [[ "$(jq -r '.domains.dnsMode' "$D")" == "wildcard" ]]      && ok "default.json domains.dnsMode carried over (wildcard)" || bad "default.json dnsMode"
    [[ "$(jq -r '.network.zone' "$D")" == "default" ]]         && ok "default.json network.zone defaults to 'default'" || bad "default.json network.zone"
    [[ "$(jq -r '.ownerOrg' "$D")" == "test2" ]]               && ok "default.json ownerOrg <- site owner (test2)" || bad "default.json ownerOrg"
    if jq -e '.. | objects | has("tlsCertRefid")' "$D" >/dev/null 2>&1; then
        bad "default.json should NOT contain tlsCertRefid (must be DROPPED)"
    else
        ok "default.json has NO tlsCertRefid (dropped)"
    fi
else
    bad "default.json missing — cannot assert shape"
fi

# foo.json: domain + per-service dnsMode + explicit zone home
F="${ENVDIR}/foo.json"
if [[ -f "$F" ]]; then
    [[ "$(jq -r '.domains.primary' "$F")" == "foo-company.nl" ]] && ok "foo.json domains.primary" || bad "foo.json domains.primary"
    [[ "$(jq -r '.domains.dnsMode' "$F")" == "per-service" ]]    && ok "foo.json dnsMode=per-service" || bad "foo.json dnsMode"
    [[ "$(jq -r '.network.zone' "$F")" == "home" ]]              && ok "foo.json network.zone=home (explicit)" || bad "foo.json zone"
    if jq -e '.. | objects | has("tlsCertRefid")' "$F" >/dev/null 2>&1; then
        bad "foo.json should NOT contain tlsCertRefid"
    else
        ok "foo.json has NO tlsCertRefid (dropped)"
    fi
fi

# ---------------------------------------------------------------------------
# 3. Migrated environments validate (schema + references)
# ---------------------------------------------------------------------------
if run_validate "$CFG"; then
    ok "migrated environments validate (schema + zone/ownerOrg references)"
else
    bad "migrated environments should validate"
fi

# ---------------------------------------------------------------------------
# 4. Schema REJECTS an authored tlsCertRefid
# ---------------------------------------------------------------------------
BADENV="${WORK}/badenv"
mkdir -p "$BADENV"
cat > "${BADENV}/evil.json" <<'JSON'
{
  "name": "evil",
  "displayName": "Evil",
  "ownerOrg": "test2",
  "domains": { "primary": "evil.example", "tlsCertRefid": "abc123" },
  "network": { "zone": "home" }
}
JSON
if "$VALIDATE" --schema-dir "$SCHEMA_DIR" --config-dir "$CFG" --quiet "${BADENV}/evil.json" >/dev/null 2>&1; then
    bad "schema/validator should REJECT an authored tlsCertRefid"
else
    ok "schema/validator REJECTS an authored tlsCertRefid"
fi

# 4b. tlsCertRefid at top level also rejected
cat > "${BADENV}/evil2.json" <<'JSON'
{
  "name": "evil2",
  "displayName": "Evil2",
  "ownerOrg": "test2",
  "tlsCertRefid": "topbeef",
  "network": { "zone": "home" }
}
JSON
if "$VALIDATE" --schema-dir "$SCHEMA_DIR" --config-dir "$CFG" --quiet "${BADENV}/evil2.json" >/dev/null 2>&1; then
    bad "schema should REJECT a top-level tlsCertRefid"
else
    ok "schema REJECTS a top-level tlsCertRefid"
fi

# ---------------------------------------------------------------------------
# 5. Reference checks catch dangling zone / ownerOrg
# ---------------------------------------------------------------------------
cat > "${BADENV}/badzone.json" <<'JSON'
{ "name": "badzone", "displayName": "Bad Zone", "ownerOrg": "test2", "network": { "zone": "no-such-zone" } }
JSON
if "$VALIDATE" --schema-dir "$SCHEMA_DIR" --config-dir "$CFG" --quiet "${BADENV}/badzone.json" >/dev/null 2>&1; then
    bad "should catch network.zone referencing an unknown zone"
else
    ok "catches dangling network.zone reference"
fi

cat > "${BADENV}/badorg.json" <<'JSON'
{ "name": "badorg", "displayName": "Bad Org", "ownerOrg": "no-such-org", "network": { "zone": "home" } }
JSON
if "$VALIDATE" --schema-dir "$SCHEMA_DIR" --config-dir "$CFG" --quiet "${BADENV}/badorg.json" >/dev/null 2>&1; then
    bad "should catch ownerOrg referencing an unknown organization"
else
    ok "catches dangling ownerOrg reference"
fi

# ---------------------------------------------------------------------------
# 6. create-minimal-environments produces mgmt + default
# ---------------------------------------------------------------------------
CFG2="${WORK}/bootstrap"
mkdir -p "${CFG2}/people/organizations"
cp "${FIX}/people/organizations/test2.json" "${CFG2}/people/organizations/test2.json"
cp "${FIX}/zones.json" "${CFG2}/zones.json"
if "$MINIMAL" --config-dir "$CFG2" >/dev/null 2>&1; then
    ok "create-minimal-environments.sh runs"
else
    bad "create-minimal-environments.sh should succeed"
fi
M="${CFG2}/environments/mgmt.json"
DD="${CFG2}/environments/default.json"
[[ -f "$M" ]]  && ok "bootstrap produced mgmt.json"  || bad "expected mgmt.json"
[[ -f "$DD" ]] && ok "bootstrap produced default.json" || bad "expected default.json"
if [[ -f "$M" ]]; then
    [[ "$(jq -r '.network.zone' "$M")" == "mgmt" ]] && ok "mgmt.json network.zone=mgmt" || bad "mgmt.json zone"
    if jq -e 'has("domains")' "$M" | grep -q true; then
        bad "mgmt.json should have NO domains"
    else
        ok "mgmt.json has NO domains (internal-DNS only)"
    fi
fi
if run_validate "$CFG2"; then
    ok "bootstrap environments validate"
else
    bad "bootstrap environments should validate"
fi

# ---------------------------------------------------------------------------
# 7. Idempotency: re-running migrate + minimal does not error and does not clobber
# ---------------------------------------------------------------------------
default_before="$(cat "$D" 2>/dev/null || true)"
if "$MIGRATE" --config-dir "$CFG" >/dev/null 2>&1; then
    ok "migrate-variants.sh idempotent re-run succeeds"
else
    bad "migrate-variants.sh re-run should succeed"
fi
default_after="$(cat "$D" 2>/dev/null || true)"
[[ "$default_before" == "$default_after" ]] && ok "re-run did not clobber existing default.json" || bad "re-run changed default.json"

mgmt_before="$(cat "$M" 2>/dev/null || true)"
"$MINIMAL" --config-dir "$CFG2" >/dev/null 2>&1 || bad "create-minimal re-run should succeed"
mgmt_after="$(cat "$M" 2>/dev/null || true)"
[[ "$mgmt_before" == "$mgmt_after" ]] && ok "create-minimal re-run did not clobber mgmt.json" || bad "re-run changed mgmt.json"

# 7b. --force overwrites
if "$MIGRATE" --config-dir "$CFG" --force >/dev/null 2>&1; then
    ok "migrate-variants.sh --force succeeds"
else
    bad "migrate-variants.sh --force should succeed"
fi

# ---------------------------------------------------------------------------
# 8. P3 example shapes validate (foo/bar/default/mgmt from the ADR)
# ---------------------------------------------------------------------------
EX="${WORK}/examples"
mkdir -p "${EX}/people/organizations"
cp "${FIX}/zones.json" "${EX}/zones.json"
# add the orgs the examples reference + the example zones (foo, bar)
for o in test2 foo-company bar-company myOrg; do
    cat > "${EX}/people/organizations/${o}.json" <<JSON
{ "name": "${o}", "type": "company", "displayName": "${o}", "owner": "lars" }
JSON
done
jq '. + {"foo":{"type":"Service","vlantag":201,"bridge":"lan"},"bar":{"type":"Service","vlantag":202,"bridge":"lan"}}' \
    "${EX}/zones.json" > "${EX}/zones.json.tmp" && mv "${EX}/zones.json.tmp" "${EX}/zones.json"
mkdir -p "${EX}/environments"
cat > "${EX}/environments/mgmt.json" <<'JSON'
{ "name": "mgmt", "displayName": "Management", "ownerOrg": "myOrg", "network": { "zone": "mgmt" } }
JSON
cat > "${EX}/environments/foo.json" <<'JSON'
{ "name": "foo", "displayName": "Foo Company", "ownerOrg": "foo-company",
  "domains": { "primary": "foo-company.nl", "aliases": ["foocompany.com"], "aliasMode": "redirect" },
  "network": { "zone": "foo" }, "dataResidency": "eu-only",
  "backup": { "retention": "7y" }, "legal": { "processor": "myOrg BV" } }
JSON
if run_validate "$EX"; then
    ok "ADR P3 example environments (mgmt+foo) validate"
else
    bad "ADR P3 example environments should validate"
fi

# ---------------------------------------------------------------------------
# DEEP: read-only validate the LIVE config/environments if present
# ---------------------------------------------------------------------------
echo ""
echo "== environment-manager DEEP tests =="
if [[ "${TAPPAAS_TEST_DEEP:-0}" != "1" ]]; then
    echo "  SKIP: deep tier (set TAPPAAS_TEST_DEEP=1 to read-only-validate live config/environments)"
else
    LIVE="${TAPPAAS_CONFIG:-/home/tappaas/config}"
    if [[ -d "${LIVE}/environments" ]] && compgen -G "${LIVE}/environments/*.json" >/dev/null; then
        if "$VALIDATE" --schema-dir "$SCHEMA_DIR" --config-dir "$LIVE" --quiet >/dev/null 2>&1; then
            ok "live config/environments validate (read-only)"
        else
            bad "live config/environments did not validate"
        fi
    else
        echo "  SKIP: no live config/environments yet (migration not run on this host)"
    fi
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
