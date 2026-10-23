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
#   - site.json .name == "testsite"; .defaultEnvironment defaults to --name (#426)
#   - --organization decouples .defaultEnvironment/.owner from .name
#   - site.json validates against site-fields.json (validate-site.sh)
#   - NO configuration.json is created in the temp dir (site-native)
#   - no hardware block (the nodes are their pvehost instances)
#   - non-force re-run REFUSES (exit != 0) and leaves site.json unchanged
#   - --force re-run is idempotent (succeeds, still valid)
#   - --name is required (no --name -> error)
#   - --force keeps an operator-set channel (ADR-028 D9) and ipv6 (#149)
#   - the TAPPaaS trust anchor bootstrap.sh left is written and verified (ADR-033
#     D5); one that does not hold refuses and leaves site.json unchanged
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
# .defaultEnvironment defaults to --name when --organization omitted (#426)
[[ "$(jqv "$SITE" '.defaultEnvironment')" == "testsite" ]] && ok ".defaultEnvironment defaults to name" || bad ".defaultEnvironment wrong (got '$(jqv "$SITE" '.defaultEnvironment')')"
# displayName from name; owner from org (== name here)
[[ "$(jqv "$SITE" '.displayName')" == "testsite" ]] && ok ".displayName derived from name" || bad ".displayName wrong"
[[ "$(jqv "$SITE" '.owner')" == "testsite" ]] && ok ".owner derived from org (==name)" || bad ".owner wrong"

# schema validation
if run_validate "$SITE"; then ok "site.json validates against site-fields.json"; else bad "site.json failed schema validation"; fi

# repositories present + correct default shape
[[ "$(jqv "$SITE" '.repositories[0].name')" == "TAPPaaS" ]] && ok "repositories[0].name = TAPPaaS" || bad "repositories not built"
[[ "$(jqv "$SITE" '.repositories[0].branch')" == "stable" ]] && ok "repositories[0].branch = stable (default)" || bad "branch default wrong"

# environments and organizations are NOT site fields (their directories are the lists)
[[ "$(jqv "$SITE" 'has("environments")')" == "false" ]] && ok "no .environments field" || bad ".environments should not be written"
[[ "$(jqv "$SITE" 'has("organizations")')" == "false" ]] && ok "no .organizations field" || bad ".organizations should not be written"

# the nodes are not a site field: they are their pvehost instances (ADR-036 D6)
[[ "$(jqv "$SITE" 'has("hardware")')" == "false" ]] && ok "no .hardware field (the nodes are their pvehost instances)" || bad ".hardware should not be written"

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

# --- Case 4: --organization decouples the org/env name from the site code (#426) ---
C4="${WORK}/case4"
mkdir -p "$C4"
"$CREATE" --name warmelo1 --organization warmelo --config-dir "$C4" >"$C4/run.log" 2>&1
S4="$C4/site.json"
if [[ -f "$S4" ]]; then ok "create-site --name + --organization writes site.json"; else bad "site.json not created (see $C4/run.log)"; fi
[[ "$(jqv "$S4" '.name')" == "warmelo1" ]]                                         && ok ".name == site code (warmelo1)"                 || bad ".name wrong (got '$(jqv "$S4" '.name')')"
[[ "$(jqv "$S4" '.defaultEnvironment')" == "warmelo" ]]                            && ok ".defaultEnvironment == org (warmelo)"          || bad ".defaultEnvironment wrong (got '$(jqv "$S4" '.defaultEnvironment')')"
[[ "$(jqv "$S4" '.owner')" == "warmelo" ]]                                         && ok ".owner == org (decoupled from .name)"          || bad ".owner wrong (got '$(jqv "$S4" '.owner')')"
[[ "$(jqv "$S4" '.displayName')" == "warmelo1" ]]                                  && ok ".displayName from site code"                  || bad ".displayName wrong"
run_validate "$S4" && ok "decoupled site.json validates against site-fields.json" || bad "decoupled site.json failed schema validation"

# --- Case 5: invalid --organization (uppercase) is rejected ---
C5="${WORK}/case5"
mkdir -p "$C5"
if "$CREATE" --name testsite --organization "BadOrg" --config-dir "$C5" >/dev/null 2>&1; then
    bad "invalid --organization 'BadOrg' should be rejected"
else
    ok "invalid --organization is rejected (slug validation)"
fi

# --- Case 6: --force keeps the operator's channel (ADR-028 D9) and ipv6 (#149) ---
# Dropping channel would silently move an unstable/staging site to production.
[[ "$(jqv "$SITE" 'has("channel")')" == "false" ]] && ok "fresh site.json has no .channel (= production)" || bad "fresh site.json wrote .channel"
jq '.channel = "unstable" | .ipv6 = true' "$SITE" > "$SITE.tmp" && mv "$SITE.tmp" "$SITE"
if "$CREATE" --name testsite --config-dir "$C1" --force >/dev/null 2>&1; then
    ok "--force re-run with channel/ipv6 set exits 0"
else
    bad "--force re-run with channel/ipv6 set failed"
fi
[[ "$(jqv "$SITE" '.channel')" == "unstable" ]] && ok ".channel preserved across --force" || bad ".channel dropped by --force (got '$(jqv "$SITE" '.channel')')"
[[ "$(jqv "$SITE" '.ipv6')" == "true" ]]       && ok ".ipv6 preserved across --force"    || bad ".ipv6 dropped by --force (got '$(jqv "$SITE" '.ipv6')')"
run_validate "$SITE" && ok "site.json with channel validates" || bad "site.json with channel failed schema validation"

# --- Case 7: the TAPPaaS trust anchor (ADR-033 D5) ---
# A throwaway signed repository stands in for /home/tappaas/TAPPaaS: the
# TAPPaaS entry's path is pointed at it, and bootstrap.sh's anchor file is
# written beside the trust record, as bootstrap does.
(
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    . "${HERE}/../../lib/verify-repo.sh"
    R="${WORK}/tappaas-repo"; git init -q -b stable "$R"
    ssh-keygen -q -t ed25519 -N '' -C k -f "${WORK}/k" </dev/null
    mkdir -p "$R/.tappaas"
    printf 'lars@x namespaces="git" %s\n' "$(cut -d' ' -f1-2 "${WORK}/k.pub")" > "$R/.tappaas/allowed_signers"
    git -C "$R" add -A; git -C "$R" commit -qm r1
    git -C "$R" -c gpg.format=ssh -c user.signingkey="${WORK}/k" tag -s v1.0 -m "TAPPaaS 1.0" -m "$(verify_tag_lines "$R" HEAD)"
    printf '%s %s\n' "$(git -C "$R" rev-parse HEAD)" "$(ssh-keygen -lf "${WORK}/k.pub" | awk '{print $2}')"
) > "${WORK}/anchor.out" 2>/dev/null
read -r ACOMMIT AFP < "${WORK}/anchor.out"
jq --arg p "${WORK}/tappaas-repo" '.repositories[0].path = $p | del(.repositories[0].trust)' "$SITE" > "$SITE.tmp" && mv "$SITE.tmp" "$SITE"
mkdir -p "$C1/.trust"
jq -n --arg c "$ACOMMIT" --arg s "$AFP" '{introduction: "v1.0", introductionCommit: $c, signer: $s}' > "$C1/.trust/TAPPaaS.introduction.json"
if "$CREATE" --name testsite --config-dir "$C1" --force >/dev/null 2>&1; then
    ok "--force with a TAPPaaS anchor exits 0"
else
    bad "--force with a good TAPPaaS anchor failed"
fi
[[ "$(jqv "$SITE" '.repositories[0].trust.introduction + " " + .repositories[0].trust.signer')" == "v1.0 ${AFP}" ]] \
    && ok "TAPPaaS entry carries the anchor" || bad "anchor not written (got '$(jqv "$SITE" '.repositories[0].trust')')"
run_validate "$SITE" && ok "site.json with a trust anchor validates" || bad "site.json with a trust anchor failed schema validation"
cp "$SITE" "$SITE.before"
jq '.repositories[0].trust.signer = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' "$SITE" > "$SITE.tmp" && mv "$SITE.tmp" "$SITE"
cp "$SITE" "$SITE.bad"
if "$CREATE" --name testsite --config-dir "$C1" --force >/dev/null 2>&1; then
    bad "an anchor with the wrong signer was accepted"
else
    ok "an anchor with the wrong signer refuses"
fi
cmp -s "$SITE" "$SITE.bad" && ok "…and site.json is left as it was" || bad "site.json changed on a refused anchor"

echo ""
echo "Results:${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
[[ "$FAIL" -eq 0 ]]
