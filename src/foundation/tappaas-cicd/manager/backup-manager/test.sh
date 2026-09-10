#!/usr/bin/env bash
# test.sh — backup-manager offline test suite (ADR-007 P9; TS-native since the
# post-implementation refactor, Phase 7.4 — the legacy bash layer is retired).
#
# FAST + non-disruptive by default: compiles the TypeScript sources + unit
# tests, runs the offline unit suite (cascade / validate / reconcile / modify
# against fixtures + FakeClient), then exercises the compiled `backup-manager`
# CLI against temp fixtures — never the live config or PBS.
# TAPPAAS_TEST_DEEP=1 adds nothing live here (the manager is pure config).
set -uo pipefail

# Accept --deep as well as TAPPAAS_TEST_DEEP=1. Every gate below reads the
# variable, so exporting it here is all a flag needs to do — and exporting (not
# just setting) is what carries it into any suite this one dispatches. Without
# this, `test.sh --deep` silently ran the fast path.
for _a in "$@"; do [[ "${_a}" == "--deep" ]] && export TAPPAAS_TEST_DEEP=1; done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
ok()   { echo "  ok: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1" >&2; fail=$((fail + 1)); }

# ── Syntax: every remaining script parses ────────────────────────────
for f in "${HERE}"/*.sh; do
    b="$(basename "$f")"
    if bash -n "$f"; then ok "${b} parses"; else bad "${b} syntax"; fi
done

# ── Build the TypeScript CLI + unit tests ────────────────────────────
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

# `list`/`show` read job membership from backup-controller (#627). This suite is
# offline BY CONSTRUCTION, and on the mothership the real controller is on PATH
# and PBS is reachable — so pin the binary to an absent path. Tests that want
# the job-sourced path point this at a stub instead.
export BACKUP_CONTROLLER_BIN="${HERE}/dist-test/no-such-controller"

DIST_TEST="${HERE}/dist-test"
# tsconfig rootDir is the tappaas-cicd root (shared lib/ts base), so the
# compiled tree mirrors manager/backup-manager/ under dist-test.
BM_JS="${DIST_TEST}/manager/backup-manager/src/main.js"
rm -rf -- "$DIST_TEST"

if run_ts "tsc --noEmit -p '${HERE}/tsconfig.json'" >/dev/null 2>&1; then
    ok "tsc --noEmit clean (src)"
else
    bad "tsc --noEmit reported type errors (src)"
fi
if run_ts "tsc -p '${HERE}/test/unit/tsconfig.json'" >/dev/null 2>&1; then
    ok "TypeScript sources + unit tests compile"
else
    bad "TypeScript unit tests failed to compile"
    rm -rf -- "$DIST_TEST"
    echo ""
    echo "backup-manager test: ${pass} passed, ${fail} failed"
    exit 1
fi

# ── TS unit suite (cascade/validate/reconcile/restore/modify, FakeClient) ─
if run_ts "node '${DIST_TEST}/manager/backup-manager/test/unit/cascade.test.js'"; then
    ok "TypeScript cascade unit tests pass"
else
    bad "TypeScript cascade unit tests FAILED"
fi

# The compiled CLI, exercised exactly as the retired bash entry points were.
BM() { run_ts "node '${BM_JS}' $*"; }

# ── Build a fixture config dir for the cascade ───────────────────────
FIX="$(mktemp -d "${TMPDIR:-/tmp}/bm-fix.XXXXXX")"
trap 'rm -rf "${FIX}" "${DIST_TEST}"' EXIT
mkdir -p "${FIX}/environments"

# site: defaultRetention 7y, eu-only offsite, target set.
cat > "${FIX}/site.json" <<'JSON'
{ "name": "test-site", "displayName": "Test", "owner": "o",
  "location": {"country":"NL","timezone":"Europe/Amsterdam"},
  "hardware": {"nodes":[{"name":"tappaas1"}]},
  "repositories": [{"name":"r","url":"u"}],
  "backup": {"target":"pbs1","offsite":"buddy","offsiteResidency":"eu-only","defaultRetention":"7y"} }
JSON

# env bar: override retention 5y, eu-only.
cat > "${FIX}/environments/bar.json" <<'JSON'
{ "name":"bar","displayName":"Bar","ownerOrg":"o","network":{"zone":"srv"},
  "dataResidency":"eu-only",
  "backup": {"retention":"5y","residency":"eu-only"} }
JSON

# env global-env: global residency.
cat > "${FIX}/environments/globalenv.json" <<'JSON'
{ "name":"globalenv","displayName":"G","ownerOrg":"o","network":{"zone":"srv"},
  "dataResidency":"global",
  "backup": {"residency":"global"} }
JSON

# Modules:
#   m-site:   no environment, no module backup -> inherits site 7y
#   m-env:    environment bar, no module override -> 5y
#   m-mod:    environment bar, module retention 1y -> 1y
#   m-off:    environment bar, module backup.enabled false -> disabled
cat > "${FIX}/m-site.json"  <<'JSON'
{ "vmname":"m-site","vmid":201,"dependsOn":["cluster:vm","backup:vm"] }
JSON
cat > "${FIX}/m-env.json"   <<'JSON'
{ "vmname":"m-env","vmid":202,"environment":"bar","dependsOn":["cluster:vm","backup:vm"] }
JSON
cat > "${FIX}/m-mod.json"   <<'JSON'
{ "vmname":"m-mod","vmid":203,"environment":"bar","dependsOn":["cluster:vm","backup:vm"],
  "backup":{"retention":"1y","exclude":["/var/cache"]} }
JSON
cat > "${FIX}/m-off.json"   <<'JSON'
{ "vmname":"m-off","vmid":204,"environment":"bar","dependsOn":["cluster:vm","backup:vm"],
  "backup":{"enabled":false} }
JSON

R() { BM "resolve $1 --config-dir '${FIX}'"; }
field() { jq -r "$2" <<<"$(R "$1")"; }

# ── Cascade: site-only ───────────────────────────────────────────────
[[ "$(field m-site .retention)" == "7y" ]] && ok "cascade site-only retention=7y" || bad "site-only retention != 7y"
[[ "$(field m-site .residency)" == "eu-only" ]] && ok "cascade site-only residency=eu-only" || bad "site-only residency"
[[ "$(field m-site .target)" == "pbs1" ]] && ok "site target propagates" || bad "site target"

# ── Cascade: environment override ────────────────────────────────────
[[ "$(field m-env .retention)" == "5y" ]] && ok "cascade env override retention=5y" || bad "env override retention != 5y"
[[ "$(field m-env .environment)" == "bar" ]] && ok "env recorded on policy" || bad "env not recorded"

# ── Cascade: module override (the demo: 7y -> 5y -> 1y) ───────────────
[[ "$(field m-mod .retention)" == "1y" ]] && ok "cascade module override retention=1y (7y->5y->1y)" || bad "module override retention != 1y"
[[ "$(field m-mod '.exclude[0]')" == "/var/cache" ]] && ok "module exclude propagates" || bad "module exclude"

# ── Cascade: module enabled:false -> disabled ────────────────────────
[[ "$(field m-off .enabled)" == "false" ]] && ok "module backup.enabled:false -> disabled" || bad "enabled:false not honoured"
[[ "$(field m-mod .enabled)" == "true" ]] && ok "default enabled=true" || bad "default enabled"

# ── Environment-name override via --environment ──────────────────────
[[ "$(BM "resolve m-site --environment bar --config-dir '${FIX}'" | jq -r .retention)" == "5y" ]] \
    && ok "--environment override applies env policy" || bad "--environment override"

# ── list (was backup-status): lists all fixture modules ──────────────
sj="$(BM "list --json --config-dir '${FIX}'")"
cnt="$(jq 'length' <<<"$sj")"
[[ "$cnt" == "4" ]] && ok "list --json lists 4 fixture modules" || bad "list count=${cnt} (expected 4)"
[[ "$(jq -r '.[] | select(.module=="m-off") | .enabled' <<<"$sj")" == "false" ]] \
    && ok "list reflects disabled module" || bad "list disabled module"
[[ "$(jq -r '.[] | select(.module=="m-site") | .optedIn' <<<"$sj")" == "true" ]] \
    && ok "list reports the backup:vm opt-in" || bad "list optedIn"
# #627: the fixtures have no PBS, so membership falls back to the declaration —
# and SAYS so. An unlabelled fallback is the whole defect: the column read as
# job membership while it only ever read the declaration.
[[ "$(jq -r '.[] | select(.module=="m-site") | .membershipSource' <<<"$sj")" == "declaration" ]] \
    && ok "list labels a PBS-unreachable membership as declaration-sourced" \
    || bad "list membershipSource"
[[ "$(jq -r '.[] | select(.module=="m-site") | .inPbsJob' <<<"$sj")" == "true" ]] \
    && ok "list falls back to the opt-in when PBS is unreachable" || bad "list inPbsJob fallback"

# An ARCHIVED module declares backup:vm but has no VM to snapshot. The two
# columns must disagree — one boolean hid exactly this (#627).
ARCH="$(mktemp -d "${TMPDIR:-/tmp}/bm-arch.XXXXXX")"
cp "${FIX}/site.json" "${ARCH}/site.json"
# vmid 411: deliberately NOT one the stub controller's job holds — an archived
# module's guest is destroyed, so it must be absent from the job.
jq '.status="archived" | .vmid=411' "${FIX}/m-site.json" > "${ARCH}/m-gone.json"
aj="$(BM "list --json --config-dir '${ARCH}'")"
[[ "$(jq -r '.[0].optedIn' <<<"$aj")" == "true" ]] \
    && ok "archived module still reports its opt-in" || bad "archived optedIn"
[[ "$(jq -r '.[0].archived' <<<"$aj")" == "true" ]] \
    && ok "list surfaces status=archived" || bad "archived flag"
BM "list --config-dir '${ARCH}'" 2>&1 | grep -q "OPTED-IN" \
    && ok "list table has a separate OPTED-IN column" || bad "OPTED-IN column missing"

# ── membership read from the JOB (the fix), via a stub controller ─────
# m-site (201) is in the daily job, m-env (202) in the WEEKLY one, m-mod (203)
# in neither. A weekly member reading `false` was the second half of #627, so
# the stub covers a bucket the daily list cannot see.
STUB="$(mktemp -d "${TMPDIR:-/tmp}/bm-stub.XXXXXX")"
cat > "${STUB}/backup-controller" <<'STUBEOF'
#!/usr/bin/env bash
# Stub backup-controller: answers job-status only, from a fixed bucket layout.
[[ "$1" == "job-status" ]] || exit 2
cat <<'JSON'
{"reachable":true,"jobId":"daily-job","storage":"tappaas_backup",
 "vmids":["201"],
 "buckets":[{"bucket":"daily","jobId":"daily-job","vmids":["201"]},
            {"bucket":"weekly","jobId":"weekly-job","vmids":["202"]}]}
JSON
STUBEOF
chmod +x "${STUB}/backup-controller"

lj="$(BACKUP_CONTROLLER_BIN="${STUB}/backup-controller" BM "list --json --config-dir '${FIX}'")"
[[ "$(jq -r '.[] | select(.module=="m-site") | .membershipSource' <<<"$lj")" == "job" ]] \
    && ok "membership is labelled job-sourced when PBS answers" || bad "membershipSource=job"
[[ "$(jq -r '.[] | select(.module=="m-site") | .jobBucket' <<<"$lj")" == "daily" ]] \
    && ok "a daily member reports its bucket" || bad "daily jobBucket"
[[ "$(jq -r '.[] | select(.module=="m-env") | .inPbsJob' <<<"$lj")" == "true" ]] \
    && ok "a WEEKLY-bucket member reads true (#627 bucket blind spot)" || bad "weekly member inPbsJob"
[[ "$(jq -r '.[] | select(.module=="m-env") | .jobBucket' <<<"$lj")" == "weekly" ]] \
    && ok "a weekly member reports the weekly bucket" || bad "weekly jobBucket"
[[ "$(jq -r '.[] | select(.module=="m-mod") | .inPbsJob' <<<"$lj")" == "false" ]] \
    && ok "a declared module the job does not hold reads FALSE (was true)" || bad "m-mod inPbsJob"
[[ "$(jq -r '.[] | select(.module=="m-mod") | .optedIn' <<<"$lj")" == "true" ]] \
    && ok "and its opt-in still reads true — the gap is visible" || bad "m-mod optedIn"

# The archived module against a live job: declared, not a member, and the table
# says WHY rather than reading as drift.
aj2="$(BACKUP_CONTROLLER_BIN="${STUB}/backup-controller" BM "list --config-dir '${ARCH}'" 2>&1)"
grep -q "false (archived)" <<<"$aj2" \
    && ok "an archived non-member is reported as archived, not bare false" || bad "archived cell"
rm -rf "${STUB}" "${ARCH}"
dis="$(BM "list --json --disabled-only --config-dir '${FIX}'" | jq 'length')"
[[ "$dis" == "1" ]] && ok "list --disabled-only finds 1" || bad "disabled-only count=${dis}"

# ── validate: good fixture passes ────────────────────────────────────
if BM "validate --config-dir '${FIX}'" >/dev/null 2>&1; then
    ok "validate passes on good fixture"
else
    bad "validate rejected a good fixture"
fi

# ── validate: eu-only env -> non-EU offsite is rejected ──────────────
BADFIX="$(mktemp -d "${TMPDIR:-/tmp}/bm-bad.XXXXXX")"
mkdir -p "${BADFIX}/environments"
jq '.backup.offsiteResidency="global"' "${FIX}/site.json" > "${BADFIX}/site.json"
cp "${FIX}/environments/bar.json" "${BADFIX}/environments/"   # eu-only env
if BM "validate --config-dir '${BADFIX}'" >/dev/null 2>&1; then
    bad "validate accepted eu-only env -> non-EU offsite"
else
    ok "validate rejects eu-only env -> non-EU offsite"
fi
rm -rf "${BADFIX}"

# ── validate: bad retention string rejected ──────────────────────────
BADR="$(mktemp -d "${TMPDIR:-/tmp}/bm-badr.XXXXXX")"
jq '.backup.defaultRetention="seven-years"' "${FIX}/site.json" > "${BADR}/site.json"
if BM "validate --config-dir '${BADR}'" >/dev/null 2>&1; then
    bad "validate accepted bad retention string"
else
    ok "validate rejects bad retention string"
fi
rm -rf "${BADR}"

# ── validate: bad residency enum rejected ────────────────────────────
BADE="$(mktemp -d "${TMPDIR:-/tmp}/bm-bade.XXXXXX")"
mkdir -p "${BADE}/environments"
cp "${FIX}/site.json" "${BADE}/site.json"
jq '.backup.residency="mars-only"' "${FIX}/environments/bar.json" > "${BADE}/environments/bar.json"
if BM "validate --config-dir '${BADE}'" >/dev/null 2>&1; then
    bad "validate accepted bad residency enum"
else
    ok "validate rejects bad residency enum"
fi
rm -rf "${BADE}"

# ── validate: dangling target (enabled module in job, no target) ─────
BADT="$(mktemp -d "${TMPDIR:-/tmp}/bm-badt.XXXXXX")"
jq 'del(.backup.target)' "${FIX}/site.json" > "${BADT}/site.json"
cp "${FIX}/m-site.json" "${BADT}/"   # enabled + in PBS job
if BM "validate --config-dir '${BADT}'" >/dev/null 2>&1; then
    bad "validate accepted dangling (no target) with enabled in-job module"
else
    ok "validate rejects dangling target"
fi
rm -rf "${BADT}"

echo ""
echo "backup-manager test: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
