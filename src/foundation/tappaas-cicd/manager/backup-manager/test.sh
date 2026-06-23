#!/usr/bin/env bash
# test.sh — backup-manager offline test suite (ADR-007 P9).
#
# FAST + non-disruptive by default: cascade resolution, validate good/bad
# fixtures, status listing — all against temp fixtures, never the live config or
# PBS. TAPPAAS_TEST_DEEP=1 adds nothing live here (the manager is pure config).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
ok()   { echo "  ok: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1" >&2; fail=$((fail + 1)); }

BM="${HERE}/backup-manager.sh"
VB="${HERE}/validate-backup.sh"
ST="${HERE}/backup-status.sh"

# ── Syntax: every script parses ──────────────────────────────────────
for f in "${HERE}"/*.sh; do
    b="$(basename "$f")"
    if bash -n "$f"; then ok "${b} parses"; else bad "${b} syntax"; fi
done

# ── Build a fixture config dir for the cascade ───────────────────────
FIX="$(mktemp -d "${TMPDIR:-/tmp}/bm-fix.XXXXXX")"
trap 'rm -rf "${FIX}"' EXIT
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

R() { CONFIG_DIR="${FIX}" "${BM}" resolve "$1"; }
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
[[ "$(CONFIG_DIR="${FIX}" "${BM}" resolve m-site --environment bar | jq -r .retention)" == "5y" ]] \
    && ok "--environment override applies env policy" || bad "--environment override"

# ── status: lists all fixture modules ────────────────────────────────
sj="$(CONFIG_DIR="${FIX}" "${ST}" --json)"
cnt="$(jq 'length' <<<"$sj")"
[[ "$cnt" == "4" ]] && ok "status lists 4 fixture modules" || bad "status count=${cnt} (expected 4)"
[[ "$(jq -r '.[] | select(.module=="m-off") | .enabled' <<<"$sj")" == "false" ]] \
    && ok "status reflects disabled module" || bad "status disabled module"
dis="$(CONFIG_DIR="${FIX}" "${ST}" --json --disabled-only | jq 'length')"
[[ "$dis" == "1" ]] && ok "status --disabled-only finds 1" || bad "disabled-only count=${dis}"

# ── validate: good fixture passes ────────────────────────────────────
if CONFIG_DIR="${FIX}" "${VB}" --quiet >/dev/null 2>&1; then
    ok "validate passes on good fixture"
else
    bad "validate rejected a good fixture"
fi

# ── validate: eu-only env -> non-EU offsite is rejected ──────────────
BADFIX="$(mktemp -d "${TMPDIR:-/tmp}/bm-bad.XXXXXX")"
mkdir -p "${BADFIX}/environments"
jq '.backup.offsiteResidency="global"' "${FIX}/site.json" > "${BADFIX}/site.json"
cp "${FIX}/environments/bar.json" "${BADFIX}/environments/"   # eu-only env
if CONFIG_DIR="${BADFIX}" "${VB}" --quiet >/dev/null 2>&1; then
    bad "validate accepted eu-only env -> non-EU offsite"
else
    ok "validate rejects eu-only env -> non-EU offsite"
fi
rm -rf "${BADFIX}"

# ── validate: bad retention string rejected ──────────────────────────
BADR="$(mktemp -d "${TMPDIR:-/tmp}/bm-badr.XXXXXX")"
jq '.backup.defaultRetention="seven-years"' "${FIX}/site.json" > "${BADR}/site.json"
if CONFIG_DIR="${BADR}" "${VB}" --quiet >/dev/null 2>&1; then
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
if CONFIG_DIR="${BADE}" "${VB}" --quiet >/dev/null 2>&1; then
    bad "validate accepted bad residency enum"
else
    ok "validate rejects bad residency enum"
fi
rm -rf "${BADE}"

# ── validate: dangling target (enabled module in job, no target) ─────
BADT="$(mktemp -d "${TMPDIR:-/tmp}/bm-badt.XXXXXX")"
jq 'del(.backup.target)' "${FIX}/site.json" > "${BADT}/site.json"
cp "${FIX}/m-site.json" "${BADT}/"   # enabled + in PBS job
if CONFIG_DIR="${BADT}" "${VB}" --quiet >/dev/null 2>&1; then
    bad "validate accepted dangling (no target) with enabled in-job module"
else
    ok "validate rejects dangling target"
fi
rm -rf "${BADT}"

echo ""
echo "backup-manager test: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
