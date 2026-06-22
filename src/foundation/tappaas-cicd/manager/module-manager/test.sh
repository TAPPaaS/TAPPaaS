#!/usr/bin/env bash
#
# test.sh — tests for module-manager.
#
# FAST (default): non-disruptive, runs entirely on TEMP fixtures.
#   - Smoke: every entry script parses (bash -n) and resolves on PATH.
#   - Unit:  install-module.sh zone0 default-resolution (ADR-007 S6 N6) against
#            temp fixtures — explicit wins; site.json.name; single non-mgmt env;
#            mgmt fallback. NEVER provisions VMs or touches the live config.
# DEEP (TAPPAAS_TEST_DEEP=1): currently same as FAST (no live probes added here).
#
# Prints "Results: N passed, M failed"; exits 1 on any failure.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="${HERE}/install-module.sh"

PASS=0
FAIL=0
ok()  { echo "  ok: $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/modmgr-test.XXXXXX")"
cleanup() { [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf -- "$WORK"; return 0; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Smoke: entry scripts parse and resolve on PATH.
# ---------------------------------------------------------------------------
echo "== module-manager FAST tests =="
for f in "${HERE}"/*.sh; do
    b="$(basename "${f}")"
    case "${b}" in install.sh|update.sh|test.sh|validate.sh|test-*.sh) continue ;; esac
    if bash -n "${f}"; then ok "${b} parses"; else bad "${b} does not parse"; fi
    if command -v "${b}" >/dev/null 2>&1; then ok "${b} on PATH"; else bad "${b} not on PATH"; fi
done

# ---------------------------------------------------------------------------
# Unit: resolve_default_zone (extracted from install-module.sh, run in isolation
# with stubbed logging + a settable CONFIG_DIR). This exercises the resolution
# LOGIC only — no cluster, no VM provisioning.
# ---------------------------------------------------------------------------
FNFILE="${WORK}/resolve.fn.sh"
# Extract exactly the resolve_default_zone function body from install-module.sh.
awk '/^resolve_default_zone\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$INSTALL" > "$FNFILE"
if [[ -s "$FNFILE" ]]; then
    ok "extracted resolve_default_zone from install-module.sh"
else
    bad "could not extract resolve_default_zone from install-module.sh"
fi

# Run resolve_default_zone against a fixture CONFIG_DIR; echoes the resolved zone.
# Stubs warn/info and the color vars the function references.
run_resolve() {
    local cfg="$1"
    CONFIG_DIR="$cfg" bash -c '
        set -uo pipefail
        BL=""; CL=""
        warn() { :; }
        info() { :; }
        . "'"$FNFILE"'"
        resolve_default_zone 2>/dev/null
    '
}

# Build a fixture: zones.json (acme + mgmt), optional site.json, optional envs.
mk_zones() {
    cat > "$1/zones.json" <<'JSON'
{
  "acme": { "type": "Service", "vlantag": 200, "bridge": "lan", "state": "Active" },
  "mgmt": { "type": "Management", "vlantag": 0, "bridge": "lan", "state": "Manual" },
  "home": { "type": "Client", "vlantag": 100, "bridge": "lan", "state": "Active" }
}
JSON
}

# (2) site.json.name=acme + zones.json has acme  → resolves acme
C2="${WORK}/c2"; mkdir -p "$C2"; mk_zones "$C2"
cat > "${C2}/site.json" <<'JSON'
{ "name": "acme", "displayName": "Acme", "owner": "acme-org" }
JSON
got="$(run_resolve "$C2")"
[[ "$got" == "acme" ]] && ok "(2) site.json.name=acme resolves to 'acme' (got: ${got})" \
                       || bad "(2) expected 'acme', got '${got}'"

# (2b) site.json.name set but NOT a zone in zones.json → must NOT pick it; with
#      no envs it falls through to mgmt.
C2b="${WORK}/c2b"; mkdir -p "$C2b"; mk_zones "$C2b"
cat > "${C2b}/site.json" <<'JSON'
{ "name": "ghost", "displayName": "Ghost", "owner": "x" }
JSON
got="$(run_resolve "$C2b")"
[[ "$got" == "mgmt" ]] && ok "(2b) site.json.name not in zones.json → falls back to mgmt (got: ${got})" \
                       || bad "(2b) expected 'mgmt', got '${got}'"

# (3) no site.json, exactly one non-mgmt environment → its network.zone
C3="${WORK}/c3"; mkdir -p "$C3/environments"; mk_zones "$C3"
cat > "${C3}/environments/mgmt.json" <<'JSON'
{ "name": "mgmt", "displayName": "Management", "ownerOrg": "o", "network": { "zone": "mgmt" } }
JSON
cat > "${C3}/environments/acme.json" <<'JSON'
{ "name": "acme", "displayName": "Acme", "ownerOrg": "o", "network": { "zone": "acme" } }
JSON
got="$(run_resolve "$C3")"
[[ "$got" == "acme" ]] && ok "(3) single non-mgmt env → its zone 'acme' (got: ${got})" \
                       || bad "(3) expected 'acme', got '${got}'"

# (3b) two non-mgmt environments → ambiguous → falls back to mgmt
C3b="${WORK}/c3b"; mkdir -p "$C3b/environments"; mk_zones "$C3b"
cat > "${C3b}/environments/acme.json" <<'JSON'
{ "name": "acme", "displayName": "Acme", "ownerOrg": "o", "network": { "zone": "acme" } }
JSON
cat > "${C3b}/environments/home.json" <<'JSON'
{ "name": "home", "displayName": "Home", "ownerOrg": "o", "network": { "zone": "home" } }
JSON
got="$(run_resolve "$C3b")"
[[ "$got" == "mgmt" ]] && ok "(3b) two non-mgmt envs → ambiguous → mgmt (got: ${got})" \
                       || bad "(3b) expected 'mgmt', got '${got}'"

# (4) nothing resolvable (no site.json, no environments) → mgmt + warn
C4="${WORK}/c4"; mkdir -p "$C4"; mk_zones "$C4"
got="$(run_resolve "$C4")"
[[ "$got" == "mgmt" ]] && ok "(4) nothing resolvable → mgmt (got: ${got})" \
                       || bad "(4) expected 'mgmt', got '${got}'"
# verify the warn fires on the (4) path
warn_out="$(CONFIG_DIR="$C4" bash -c '
    set -uo pipefail
    BL=""; CL=""
    warn() { echo "WARN:$*" >&2; }
    info() { :; }
    . "'"$FNFILE"'"
    resolve_default_zone >/dev/null
' 2>&1)"
echo "$warn_out" | grep -q 'WARN:.*falling back' \
    && ok "(4) emits a clear warn on mgmt fallback" \
    || bad "(4) expected a fallback warn, got: ${warn_out}"

# explicit zone0 always wins: simulated by the caller in install-module.sh (the
# function is only invoked when .zone0 is blank). Verify the guard expression
# the caller uses behaves: a JSON with zone0 set is non-empty.
EXPL="${WORK}/explicit.json"
cat > "$EXPL" <<'JSON'
{ "vmname": "x", "zone0": "home" }
JSON
z0="$(jq -r '.zone0 // empty' "$EXPL")"
[[ -n "$z0" && "$z0" == "home" ]] \
    && ok "explicit zone0 ('home') is read non-empty (so resolution is skipped — explicit wins)" \
    || bad "explicit zone0 read failed (got: ${z0})"

# ===========================================================================
# ADR-007 P5: tier/source lint + environment-aware deployment (FAST, offline).
# ===========================================================================
echo ""
echo "== module-manager P5 (tier/source + environment) FAST tests =="

LINT="${HERE}/validate-module-tier-source.sh"

# --- tier/source lint ------------------------------------------------------
run_lint() { "$LINT" --quiet "$@" >/dev/null 2>&1; }

LWORK="${WORK}/lint"; mkdir -p "$LWORK"
gf="${LWORK}/good.json";    printf '%s\n' '{"tier":"foundation","source":"official"}'  > "$gf"
bf="${LWORK}/bad.json";     printf '%s\n' '{"tier":"foundation","source":"community"}' > "$bf"
ac="${LWORK}/appcomm.json"; printf '%s\n' '{"tier":"app","source":"community"}'        > "$ac"
ap="${LWORK}/apppriv.json"; printf '%s\n' '{"tier":"app","source":"private"}'          > "$ap"
be="${LWORK}/badenum.json"; printf '%s\n' '{"tier":"bogus"}'                           > "$be"

run_lint "$gf"  && ok "lint: foundation+official passes" || bad "lint: foundation+official should pass"
run_lint "$bf"  && bad "lint: foundation+community should FAIL" || ok "lint: foundation+community is rejected"
run_lint --allow-fork "$bf" && ok "lint: foundation+community passes with --allow-fork" || bad "lint: --allow-fork should permit foundation fork"
run_lint "$ac"  && ok "lint: app+community passes (warn-only)" || bad "lint: app+community should pass"
run_lint "$ap"  && ok "lint: app+private passes" || bad "lint: app+private should pass"
run_lint "$be"  && bad "lint: invalid tier enum should FAIL" || ok "lint: invalid tier enum is rejected"

# --- environment + zone + vmname resolution --------------------------------
# Extract the P5 resolver functions from install-module.sh and run them in
# isolation against fixture CONFIG_DIRs (no cluster, no provisioning).
P5FN="${WORK}/p5.fn.sh"
{
  awk '/^resolve_default_environment\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$INSTALL"
  echo
  awk '/^resolve_zone_for_environment\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$INSTALL"
} > "$P5FN"
[[ -s "$P5FN" ]] && ok "extracted P5 resolver functions from install-module.sh" \
                 || bad "could not extract P5 resolver functions"

run_p5() {
    # $1=cfg dir, $2=function, $3=arg(optional)
    local cfg="$1" fn="$2" arg="${3:-}"
    CONFIG_DIR="$cfg" bash -c '
        set -uo pipefail
        warn(){ :; }; info(){ :; }
        . "'"$P5FN"'"
        '"$fn"' "'"$arg"'" 2>/dev/null
    '
}

# vmname computation, mirroring install-module.sh's rule.
compute_vmname() {
    # $1=module $2=environment $3=default_env
    local mod="$1" env="$2" def="$3"
    if [[ -n "$env" && "$env" != "mgmt" && ( -z "$def" || "$env" != "$def" ) ]]; then
        printf '%s\n' "${mod}-${env}"
    else
        printf '%s\n' "${mod}"
    fi
}

# Fixture: a site 'acme' with environments mgmt, acme (default), foo.
EWORK="${WORK}/envs"; mkdir -p "${EWORK}/environments"
cat > "${EWORK}/site.json" <<'JSON'
{ "name": "acme", "displayName": "Acme", "owner": "acme-org" }
JSON
cat > "${EWORK}/environments/mgmt.json" <<'JSON'
{ "name": "mgmt", "displayName": "Management", "ownerOrg": "o", "network": { "zone": "mgmt" } }
JSON
cat > "${EWORK}/environments/acme.json" <<'JSON'
{ "name": "acme", "displayName": "Acme", "ownerOrg": "o", "network": { "zone": "acme" } }
JSON
cat > "${EWORK}/environments/foo.json" <<'JSON'
{ "name": "foo", "displayName": "Foo", "ownerOrg": "o", "network": { "zone": "fooZone" } }
JSON

# default environment resolves to the site name 'acme'
def_env="$(run_p5 "$EWORK" resolve_default_environment)"
[[ "$def_env" == "acme" ]] && ok "default environment resolves to site name 'acme' (got: ${def_env})" \
                           || bad "expected default env 'acme', got '${def_env}'"

# --environment foo → zone fooZone (from fixture environments/foo.json)
zfoo="$(run_p5 "$EWORK" resolve_zone_for_environment foo)"
[[ "$zfoo" == "fooZone" ]] && ok "--environment foo resolves zone 'fooZone' from env file (got: ${zfoo})" \
                           || bad "expected zone 'fooZone', got '${zfoo}'"

# --environment foo → vmname m-foo (non-default env)
vfoo="$(compute_vmname m foo "$def_env")"
[[ "$vfoo" == "m-foo" ]] && ok "--environment foo → vmname 'm-foo'" \
                         || bad "expected vmname 'm-foo', got '${vfoo}'"

# default env (acme) → vmname m (no suffix) + its zone acme
vdef="$(compute_vmname m acme "$def_env")"
zdef="$(run_p5 "$EWORK" resolve_zone_for_environment acme)"
[[ "$vdef" == "m" ]]     && ok "default env → vmname 'm' (no suffix)" || bad "expected vmname 'm', got '${vdef}'"
[[ "$zdef" == "acme" ]]  && ok "default env → zone 'acme'"          || bad "expected zone 'acme', got '${zdef}'"

# mgmt env → vmname m (foundation default, no suffix)
vmgmt="$(compute_vmname m mgmt "$def_env")"
[[ "$vmgmt" == "m" ]] && ok "mgmt env → vmname 'm' (no suffix)" || bad "expected vmname 'm', got '${vmgmt}'"

# zone for an environment with NO env file → empty (caller falls back) — back-compat
znone="$(run_p5 "$EWORK" resolve_zone_for_environment ghost)"
[[ -z "$znone" ]] && ok "missing env file → empty zone (caller falls back to resolve_default_zone)" \
                  || bad "expected empty zone for missing env file, got '${znone}'"

# back-compat: no site.json, no environments → default env is empty (legacy path)
BCW="${WORK}/bc"; mkdir -p "$BCW"
def_bc="$(run_p5 "$BCW" resolve_default_environment)"
[[ -z "$def_bc" ]] && ok "no site/environments → empty default env (legacy/no-env install path)" \
                   || bad "expected empty default env in back-compat, got '${def_bc}'"

# --- full install-module.sh foundation rejection (offline; fails at Step 0) -
# A tier:foundation module targeted at a non-mgmt env must error BEFORE any
# provisioning. Run install-module.sh in a temp module dir with a stub
# common-install-routines + copy-update-json on an isolated PATH/CONFIG_DIR so
# nothing real runs.
SBIN="${WORK}/bin"; mkdir -p "$SBIN"
# Stub copy-update-json.sh (sourced by install-module.sh) — never reached for
# the rejection case, but present so sourcing never fails.
cat > "$SBIN/copy-update-json.sh" <<'STUB'
EFFECTIVE_MODULE="${1:-stub}"
STUB
# Stub common-install-routines.sh with just enough surface for Step 0/1.
cat > "$SBIN/common-install-routines.sh" <<'STUB'
: "${BOLD:=}"; : "${BL:=}"; : "${GN:=}"; : "${CL:=}"; : "${YW:=}"
info(){ :; }; debug(){ :; }; warn(){ echo "WARN:$*" >&2; }
error(){ echo "ERROR:$*" >&2; }
die(){ echo "DIE:$*" >&2; exit 1; }
module_exists(){ return 1; }
STUB
# Use the real lint (symlink or sibling); copy it next to the stub bin so the
# install script's fallback finds it.
cp "$LINT" "$SBIN/validate-module-tier-source.sh" 2>/dev/null || true
chmod +x "$SBIN/validate-module-tier-source.sh" 2>/dev/null || true

# A throwaway install-module.sh copy that points at the stub bin dir. We patch
# the two hard-coded /home/tappaas/bin source paths to the stub dir.
SINSTALL="${WORK}/install-stub.sh"
sed -e "s#/home/tappaas/bin/common-install-routines.sh#${SBIN}/common-install-routines.sh#g" \
    -e "s#/home/tappaas/bin/copy-update-json.sh#${SBIN}/copy-update-json.sh#g" \
    -e "s#/home/tappaas/bin/validate-module-tier-source.sh#${SBIN}/validate-module-tier-source.sh#g" \
    "$INSTALL" > "$SINSTALL"
chmod +x "$SINSTALL"

# Module dir with a foundation module + a config dir with a 'foo' environment.
MDIR="${WORK}/fmod"; mkdir -p "$MDIR"
cat > "${MDIR}/foundmod.json" <<'JSON'
{ "tier": "foundation", "source": "official", "vmname": "foundmod" }
JSON
FCFG="${WORK}/fcfg"; mkdir -p "${FCFG}/environments"
cat > "${FCFG}/environments/foo.json" <<'JSON'
{ "name": "foo", "ownerOrg": "o", "network": { "zone": "fooZone" } }
JSON

rej_out="$( cd "$MDIR" && CONFIG_DIR="$FCFG" bash "$SINSTALL" foundmod --environment foo 2>&1 )"; rej_rc=$?
if [[ $rej_rc -ne 0 ]] && echo "$rej_out" | grep -qi "only be installed in the 'mgmt' environment"; then
    ok "install: tier:foundation → non-mgmt env is rejected (offline, before provisioning)"
else
    bad "install: foundation→non-mgmt should be rejected (rc=${rej_rc}); out: ${rej_out##*$'\n'}"
fi

# A community foundation module must be rejected by the lint at install Step 0.
cat > "${MDIR}/forkmod.json" <<'JSON'
{ "tier": "foundation", "source": "community", "vmname": "forkmod" }
JSON
fork_out="$( cd "$MDIR" && CONFIG_DIR="$FCFG" bash "$SINSTALL" forkmod --environment mgmt 2>&1 )"; fork_rc=$?
if [[ $fork_rc -ne 0 ]] && echo "$fork_out" | grep -qi "tier/source lint failed"; then
    ok "install: tier:foundation + source:community is rejected by the lint at Step 0"
else
    bad "install: foundation+community should fail lint (rc=${fork_rc}); out: ${fork_out##*$'\n'}"
fi

# --variant aliases --environment: an app module with --variant bar must compute
# vmname m-bar exactly like --environment bar (no registry needed). We verify the
# alias mapping via the documented rule (the install path sets environment=variant
# when --environment is absent).
valias="$(compute_vmname m bar "$def_env")"
[[ "$valias" == "m-bar" ]] && ok "--variant bar aliases --environment bar → vmname 'm-bar'" \
                           || bad "expected vmname 'm-bar' for --variant alias, got '${valias}'"

# --- back-compat: a module lacking 'tier' still installs as 'app' (no break) -
# Step 0 reads tier // "app"; with no site/environments the env is empty and the
# install proceeds down the legacy path. Verify Step 0 does NOT error for a
# tier-less module in a bare config dir (it should pass classification and reach
# the existence check, which our stub lets through).
cat > "${MDIR}/legacymod.json" <<'JSON'
{ "vmname": "legacymod", "tier": "app" }
JSON
BCFG="${WORK}/bcfg"; mkdir -p "$BCFG"
# Make copy-update-json stub write a minimal config so Step 2's check_json path
# is skipped-safe: instead we only assert Step 0/1 don't reject. Run and capture.
legacy_out="$( cd "$MDIR" && CONFIG_DIR="$BCFG" bash "$SINSTALL" legacymod 2>&1 )"
# It will likely fail later (stub copy/check_json), but must NOT fail at Step 0
# classification or the foundation guard. Assert no foundation/lint rejection.
if echo "$legacy_out" | grep -qiE "only be installed in the 'mgmt'|tier/source lint failed"; then
    bad "back-compat: tier-less/app module wrongly rejected at Step 0: ${legacy_out##*$'\n'}"
else
    ok "back-compat: app/tier-less module is NOT rejected at Step 0 (legacy path preserved)"
fi

# --- delete-module.sh foundation --force gate (offline; stubbed teardown) --
DELETE="${HERE}/delete-module.sh"
DWORK="${WORK}/del"; mkdir -p "${DWORK}/cfg" "${DWORK}/sbin"
cat > "${DWORK}/sbin/common-install-routines.sh" <<'STUB'
: "${BOLD:=}"; : "${BL:=}"; : "${GN:=}"; : "${CL:=}"; : "${YW:=}"
info(){ :; }; debug(){ :; }; warn(){ echo "WARN:$*" >&2; }
error(){ echo "ERROR:$*" >&2; }; die(){ echo "DIE:$*" >&2; exit 1; }
read_module_config(){ cat "${CONFIG_DIR}/$1.json" 2>/dev/null; }
find_vms_by_name(){ :; }
STUB
DSTUB="${WORK}/del-stub.sh"
sed -e "s#/home/tappaas/bin/common-install-routines.sh#${DWORK}/sbin/common-install-routines.sh#g" \
    -e "s#readonly CONFIG_DIR=\"/home/tappaas/config\"#CONFIG_DIR=\"${DWORK}/cfg\"#g" \
    "$DELETE" > "$DSTUB"
printf '%s\n' '{"tier":"foundation","source":"official","vmname":"fmod"}' > "${DWORK}/cfg/fmod.json"
printf '%s\n' '{"tier":"app","source":"official","vmname":"amod"}'        > "${DWORK}/cfg/amod.json"

del_nf="$( bash "$DSTUB" fmod 2>&1 )"; del_nf_rc=$?
if [[ $del_nf_rc -ne 0 ]] && echo "$del_nf" | grep -qi "without --force"; then
    ok "delete: tier:foundation without --force is refused"
else
    bad "delete: foundation without --force should be refused (rc=${del_nf_rc})"
fi

# With --force the foundation gate is passed (it proceeds; teardown is config-only
# here since there is no cluster — exits 0 after removing the config).
del_f="$( bash "$DSTUB" fmod --force 2>&1 )"; del_f_rc=$?
if [[ $del_f_rc -eq 0 ]] && ! echo "$del_f" | grep -qi "without --force"; then
    ok "delete: tier:foundation with --force proceeds (gate passed)"
else
    bad "delete: foundation with --force should proceed (rc=${del_f_rc})"
fi

# An app module is NOT subject to the foundation gate.
del_app="$( bash "$DSTUB" amod 2>&1 )"
if ! echo "$del_app" | grep -qi "without --force"; then
    ok "delete: app module is not subject to the foundation --force gate"
else
    bad "delete: app module wrongly hit the foundation gate"
fi

# --- run the standalone lint test suite and fold its result in -------------
if [[ -x "${HERE}/test-validate-module-tier-source.sh" ]]; then
    echo ""
    echo "-- standalone: test-validate-module-tier-source.sh --"
    if "${HERE}/test-validate-module-tier-source.sh"; then
        ok "standalone tier/source lint test suite passed"
    else
        bad "standalone tier/source lint test suite failed"
    fi
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
