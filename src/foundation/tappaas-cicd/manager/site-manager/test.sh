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
#   - owner is derived from config/identities/organizations/ when present
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
    #
    # A SWEEP over what compiled, not a list of six names: a list is how a test
    # file comes to exist and run nowhere (the Test 9z lesson, one directory
    # over). A new test/unit/<name>.test.ts runs the day it lands.
    _ut_ran=0
    for _utjs in "${DIST_TEST}/manager/site-manager/test/unit/"*.test.js; do
        [[ -f "${_utjs}" ]] || continue
        t="$(basename "${_utjs}" .test.js)"
        _ut_ran=$((_ut_ran + 1))
        if run_ts "node '${_utjs}'" >/dev/null 2>&1; then
            ok "TypeScript ${t} unit tests pass"
        else
            bad "TypeScript ${t} unit tests FAILED (rerun: node ${_utjs})"
        fi
    done
    if [[ "${_ut_ran}" -gt 0 ]]; then
        ok "swept ${_ut_ran} unit test file(s) — a new one runs without being listed here"
    else
        bad "no compiled unit tests found to run"
    fi
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

# --- ADR-017 D6: validate reports the schedule with the renderer's mapping ---
SCHED="${WORK}/sched-site.json"
echo '{ "name": "s", "updateSchedule": ["daily", "Tuesday", 2] }' > "$SCHED"
_out="$("$VALIDATE" --schema-dir "$SCHEMA_DIR" "$SCHED" 2>&1 || true)"
grep -q "inert under 'daily'" <<<"$_out" && ok "validate reports a weekday under daily as inert" || bad "inert weekday not reported"
echo '{ "name": "s", "updateSchedule": ["hourly", null, 2] }' > "$SCHED"
_out="$("$VALIDATE" --schema-dir "$SCHEMA_DIR" "$SCHED" 2>&1 || true)"
grep -q "VALIDATION: updateSchedule frequency 'hourly'" <<<"$_out" && ok "validate refuses an unknown frequency" || bad "unknown frequency not refused"

# The object form (ADR-017 D7 / migration 0003): validate reads it, and reads
# the legacy triple too — a site can be restored from a backup that predates it.
echo '{ "name": "s", "updateSchedule": {"frequency":"weekly","weekday":"Tuesday","hour":4} }' > "$SCHED"
_out="$("$VALIDATE" --schema-dir "$SCHEMA_DIR" "$SCHED" 2>&1 || true)"
grep -q 'OnCalendar=Tue \*-\*-\* 04:00:00' <<<"$_out" \
    && ok "validate maps the object form to OnCalendar" || bad "object form not mapped: ${_out}"
echo '{ "name": "s", "updateSchedule": {"frequency":"hourly","hour":2} }' > "$SCHED"
_out="$("$VALIDATE" --schema-dir "$SCHEMA_DIR" "$SCHED" 2>&1 || true)"
grep -q "updateSchedule frequency 'hourly'" <<<"$_out" \
    && ok "validate refuses an unknown frequency in the object form" || bad "object unknown frequency not refused"
echo '{ "name": "s", "updateSchedule": {"frequency":"none"} }' > "$SCHED"
_out="$("$VALIDATE" --schema-dir "$SCHEMA_DIR" "$SCHED" 2>&1 || true)"
grep -q 'no scheduled update' <<<"$_out" \
    && ok "validate reports 'none' as no scheduled update" || bad "none not reported"

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

# ---------------------------------------------------------------------------
# #408 — the first node is the master for country / keyboard / timezone.
# ---------------------------------------------------------------------------
echo "== site master data (#408) =="

_loc_site() {   # a minimal valid site.json carrying the given location object
    printf '{"name":"s","displayName":"S","owner":"o","defaultEnvironment":"o","location":%s,"hardware":{"nodes":[]},"repositories":[]}' "$1"
}

GOODLOC="${WORK}/loc-good.json"
_loc_site '{"country":"DK","timezone":"Europe/Copenhagen","locale":"en_US","keyboard":"dk","latitude":55.6761,"longitude":12.5683}' > "$GOODLOC"
if run_validate "$GOODLOC"; then ok "location accepts keyboard + latitude/longitude"; else bad "location with keyboard/lat/lon wrongly rejected"; fi

# A pattern and a numeric bound are only enforced by the real JSON-Schema
# validator; the jq-only fallback checks required fields and types, so these two
# say so rather than failing on a machine without python jsonschema.
if python3 -c "import jsonschema" >/dev/null 2>&1; then
    BADKB="${WORK}/loc-badkb.json"
    _loc_site '{"country":"DK","timezone":"Europe/Copenhagen","keyboard":"not a layout!"}' > "$BADKB"
    if run_validate "$BADKB"; then bad "a keyboard with spaces/punctuation wrongly passed"; else ok "keyboard must look like a layout"; fi

    BADLAT="${WORK}/loc-badlat.json"
    _loc_site '{"country":"DK","timezone":"Europe/Copenhagen","latitude":355.0}' > "$BADLAT"
    if run_validate "$BADLAT"; then bad "latitude 355 wrongly passed"; else ok "latitude is bounded to +/-90"; fi
else
    echo "  skip: keyboard pattern + latitude bound (no python jsonschema here; the jq fallback checks neither)"
fi

# The helpers, with ssh stubbed: the node's answers win over this machine's, and
# a node that cannot be reached leaves local detection in charge.
_CS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/create-site.sh"
STUBDIR="${WORK}/stub"; mkdir -p "$STUBDIR"
cat > "${STUBDIR}/ssh" <<'STUB'
#!/usr/bin/env bash
# Answers as tappaas1 would: timezone, XKBLAYOUT, LANG — one per line.
[[ "${TAPPAAS_STUB_UNREACHABLE:-0}" == "1" ]] && exit 255
printf 'Europe/Copenhagen\ndk\nen_DK.UTF-8\n'
STUB
chmod +x "${STUBDIR}/ssh"

_master="$(PATH="${STUBDIR}:$PATH" TAPPAAS_CREATE_SITE_LIB=1 bash -c '
    . '"${_CS_LIB}"'
    detect_from_node tappaas1.mgmt.internal
    printf "%s|%s|%s|%s" "$(master_timezone)" "$(master_keyboard)" "$(master_locale)" "$(country_from_timezone "$(master_timezone)")"' 2>/dev/null)"
[[ "$_master" == "Europe/Copenhagen|dk|en_DK|DK" ]] \
    && ok "master data read from the node (tz/keyboard/locale, country derived)" \
    || bad "master data from the node wrong: got '${_master}'"

_fallback="$(PATH="${STUBDIR}:$PATH" TAPPAAS_STUB_UNREACHABLE=1 TAPPAAS_CREATE_SITE_LIB=1 bash -c '
    . '"${_CS_LIB}"'
    detect_from_node tappaas1.mgmt.internal
    printf "%s|%s" "$(master_timezone)" "$(master_keyboard)"' 2>/dev/null)"
[[ -n "${_fallback%%|*}" && "${_fallback##*|}" == "" ]] \
    && ok "an unreachable node falls back to local detection, and claims no keyboard" \
    || bad "unreachable-node fallback wrong: got '${_fallback}'"

# The merge rule: what the operator recorded wins; a fact never recorded is filled.
_merged="$(jq -c --arg c DK --arg t Europe/Copenhagen --arg l en_US --arg k dk \
    '(.location // {}) as $l0
     | {country: $c, timezone: $t, locale: $l}
       + (if $k == "" then {} else {keyboard: $k} end)
       + $l0' <<<'{"location":{"country":"NL","timezone":"Europe/Amsterdam"}}')"
[[ "$(jq -r '.country' <<<"$_merged")" == "NL" && "$(jq -r '.keyboard' <<<"$_merged")" == "dk" ]] \
    && ok "merge keeps the operator's country and fills the missing keyboard" \
    || bad "location merge wrong: ${_merged}"

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
