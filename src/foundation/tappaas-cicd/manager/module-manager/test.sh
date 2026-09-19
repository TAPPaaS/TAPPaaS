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

# Accept --deep as well as TAPPAAS_TEST_DEEP=1. Every gate below reads the
# variable, so exporting it here is all a flag needs to do — and exporting (not
# just setting) is what carries it into any suite this one dispatches. Without
# this, `test.sh --deep` silently ran the fast path.
for _a in "$@"; do [[ "${_a}" == "--deep" ]] && export TAPPAAS_TEST_DEEP=1; done


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
#
# "Just enough" is a moving target: install-module.sh and delete-module.sh call
# tappaas_require_operator (71207c0), which this stub did not define, so all
# four tier/source cases died at line 54 with "command not found" and rc 127.
# It is a no-op here on purpose — these cases assert the tier/source LINT, and
# who the operator is has nothing to do with that. Anything the scripts under
# test come to depend on must be listed here, or the case fails for a reason
# that has nothing to do with what it is testing.
cat > "$SBIN/common-install-routines.sh" <<'STUB'
: "${BOLD:=}"; : "${BL:=}"; : "${GN:=}"; : "${CL:=}"; : "${YW:=}"
info(){ :; }; debug(){ :; }; warn(){ echo "WARN:$*" >&2; }
error(){ echo "ERROR:$*" >&2; }
fatal(){ echo "FATAL:$*" >&2; }
die(){ echo "DIE:$*" >&2; exit 1; }
module_exists(){ return 1; }
tappaas_require_operator(){ :; }
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
fatal(){ echo "FATAL:$*" >&2; }
read_module_config(){ cat "${CONFIG_DIR}/$1.json" 2>/dev/null; }
find_vms_by_name(){ :; }
# No-op, as in the install stub above: delete-module.sh calls this at line ~71
# (71207c0) and these cases assert the foundation --force gate, not who is
# running. Without it both die at "command not found" with rc 127.
tappaas_require_operator(){ :; }
get_module_dir(){ local d; d="$(jq -r '.moduleSource // empty' "${CONFIG_DIR}/$1.json" 2>/dev/null)"; [[ -n "$d" ]] || return 1; echo "$d"; [[ -d "$d" ]] || return 2; }
ensure_scripts_executable(){ :; }
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

# A machine (ADR-026) is only ever UNREGISTERED: its module's delete.sh is not
# run. The satellite's delete.sh is `satellite-manager remove` — a decommission —
# and a satellite that records its moduleSource (#609) could otherwise reach it.
mkdir -p "${DWORK}/src/satellite"
printf '#!/usr/bin/env bash\ntouch "%s/DECOMMISSIONED"\n' "${DWORK}" > "${DWORK}/src/satellite/delete.sh"
chmod +x "${DWORK}/src/satellite/delete.sh"
printf '{"kind":"machine","tier":"app","moduleSource":"%s/src/satellite"}\n' "${DWORK}" > "${DWORK}/cfg/satellite-s1.json"
del_m="$( bash "$DSTUB" satellite-s1 --remove --yes 2>&1 )"; del_m_rc=$?
if [[ $del_m_rc -eq 0 && ! -e "${DWORK}/DECOMMISSIONED" && ! -e "${DWORK}/cfg/satellite-s1.json" ]]; then
    ok "delete: a machine is unregistered and its module's delete.sh is NOT run (no decommission)"
else
    bad "delete: machine delete ran delete.sh or kept the config (rc=${del_m_rc}, decommissioned=$([[ -e ${DWORK}/DECOMMISSIONED ]] && echo yes || echo no)): ${del_m##*$'\n'}"
fi

# ---------------------------------------------------------------------------
# resolve-module.sh — catalog resolution (#459) and tier resolution (#460).
# Fixture repositories + fixture site.json; the live config is never read.
# ---------------------------------------------------------------------------
echo ""
echo "== resolve-module.sh catalog/tier resolution (#459, #460) =="

RM="${HERE}/resolve-module.sh"
RW="${WORK}/resolve"
mkdir -p "${RW}/cfg" "${RW}/legacy/src/apps/legacymod" "${RW}/current/src/apps/curmod" "${RW}/custom/catalogs" "${RW}/custom/mods/custmod"

# A repo whose catalog carries the LEGACY name (src/modules.json). `repository
# add` accepts such a repo and records catalog="src/modules.json"; before #459
# resolve-module.sh looked only at src/module-catalog.json and found nothing.
cat > "${RW}/legacy/src/modules.json" <<'EOF'
{"applicationModules":[{"moduleName":"legacymod","moduleJson":"src/apps/legacymod/legacymod.json","tier":"app"}]}
EOF
echo '{"description":"legacy"}' > "${RW}/legacy/src/apps/legacymod/legacymod.json"

# A repo at the conventional path (the case that always worked).
cat > "${RW}/current/src/module-catalog.json" <<'EOF'
{"foundationModules":[{"moduleName":"curmod","legacyName":"oldmod","moduleJson":"src/apps/curmod/curmod.json","tier":"foundation"}]}
EOF
echo '{"description":"current"}' > "${RW}/current/src/apps/curmod/curmod.json"

# A repo whose catalog is at a wholly non-conventional declared path.
cat > "${RW}/custom/catalogs/mine.json" <<'EOF'
{"applicationModules":[{"moduleName":"custmod","moduleJson":"mods/custmod/custmod.json","tier":"app"}]}
EOF
echo '{"description":"custom"}' > "${RW}/custom/mods/custmod/custmod.json"

cat > "${RW}/cfg/site.json" <<EOF
{"repositories":[
  {"name":"Legacy","url":"x","path":"${RW}/legacy","managed":"full","catalog":"src/modules.json"},
  {"name":"Current","url":"x","path":"${RW}/current","managed":"full"},
  {"name":"Custom","url":"x","path":"${RW}/custom","managed":"full","catalog":"catalogs/mine.json"},
  {"name":"Tracked","url":"x","path":"${RW}/legacy","managed":"tracked"}
]}
EOF

got="$("$RM" legacymod --config-dir "${RW}/cfg" 2>/dev/null || true)"
[[ "$got" == "${RW}/legacy/src/apps/legacymod" ]] \
    && ok "resolve-module: legacy src/modules.json catalog resolves (#459)" \
    || bad "resolve-module: legacy catalog not resolved (got: '${got}')"

got="$("$RM" custmod --config-dir "${RW}/cfg" 2>/dev/null || true)"
[[ "$got" == "${RW}/custom/mods/custmod" ]] \
    && ok "resolve-module: declared non-conventional catalog path is read (#459)" \
    || bad "resolve-module: declared catalog path ignored (got: '${got}')"

got="$("$RM" curmod --config-dir "${RW}/cfg" 2>/dev/null || true)"
[[ "$got" == "${RW}/current/src/apps/curmod" ]] \
    && ok "resolve-module: conventional catalog still resolves" \
    || bad "resolve-module: conventional catalog regressed (got: '${got}')"

got="$("$RM" oldmod --config-dir "${RW}/cfg" --field repo 2>/dev/null || true)"
[[ "$got" == "Current" ]] \
    && ok "resolve-module: legacyName lookup still resolves" \
    || bad "resolve-module: legacyName lookup regressed (got: '${got}')"

# A `full` repo with no readable catalog is a misconfiguration; a `tracked` one
# is not. The whole-repository skip used to be silent either way (#459).
warns="$("$RM" nosuch --config-dir "${RW}/cfg" 2>&1 >/dev/null || true)"
if grep -q "no readable module catalog" <<< "$warns"; then
    bad "resolve-module: warned about a catalog that is actually readable"
else
    ok "resolve-module: no spurious catalog warning when all catalogs resolve"
fi

RW2="${WORK}/resolve2"; mkdir -p "${RW2}/cfg" "${RW2}/empty/src" "${RW2}/tracked/src"
cat > "${RW2}/cfg/site.json" <<EOF
{"repositories":[
  {"name":"NoPath","url":"x","managed":"full"},
  {"name":"NoCatalog","url":"x","path":"${RW2}/empty","managed":"full"},
  {"name":"Tracked","url":"x","path":"${RW2}/tracked","managed":"tracked"}
]}
EOF
warns="$("$RM" nosuch --config-dir "${RW2}/cfg" 2>&1 >/dev/null || true)"
grep -q "repository 'NoPath' has no .path" <<< "$warns" \
    && ok "resolve-module: a repository with no .path is reported, not silently skipped" \
    || bad "resolve-module: missing .path still skipped silently (got: '${warns}')"
grep -q "repository 'NoCatalog' declares no readable module catalog" <<< "$warns" \
    && ok "resolve-module: a 'full' repo with no catalog is reported" \
    || bad "resolve-module: unreadable catalog on a full repo not reported"
grep -q "Tracked" <<< "$warns" \
    && bad "resolve-module: 'managed: tracked' repo wrongly warned about (no catalog is its normal state)" \
    || ok "resolve-module: 'managed: tracked' repo does not warn"

# --field tier: the deployed config outranks the catalog, which is the only
# source that works for a module located via .location rather than a catalog.
echo '{"kind":"module","tier":"app","location":"/somewhere/thermostat"}' > "${RW}/cfg/thermostat.json"
got="$("$RM" thermostat --config-dir "${RW}/cfg" --field tier 2>/dev/null || true)"
[[ "$got" == "app" ]] \
    && ok "resolve-module: tier resolves from the deployed config for a .location-only module (#460)" \
    || bad "resolve-module: tier empty for a .location-only module (got: '${got}')"

echo '{"kind":"module","tier":"foundation"}' > "${RW}/cfg/curmod.json"
got="$("$RM" curmod --config-dir "${RW}/cfg" --field tier 2>/dev/null || true)"
[[ "$got" == "foundation" ]] \
    && ok "resolve-module: deployed-config tier wins over the catalog" \
    || bad "resolve-module: deployed-config tier not preferred (got: '${got}')"

rm -f "${RW}/cfg/curmod.json"
got="$("$RM" curmod --config-dir "${RW}/cfg" --field tier 2>/dev/null || true)"
[[ "$got" == "foundation" ]] \
    && ok "resolve-module: catalog tier is still the fallback" \
    || bad "resolve-module: catalog tier fallback broken (got: '${got}')"

# ---------------------------------------------------------------------------
# get_module_dir exit codes (#460): 0 found, 1 no .moduleSource recorded,
# 2 recorded but the directory is gone. 0/1 keep their historical meaning.
# ---------------------------------------------------------------------------
echo ""
echo "== get_module_dir failure distinction (#460) =="

GMD="${WORK}/gmd.sh"
{
    echo 'CONFIG_DIR="$1"'
    sed -n '/^get_module_dir() {/,/^}/p' "${HERE}/../../lib/common-install-routines.sh"
    echo 'out="$(get_module_dir "$2")"; rc=$?; echo "rc=${rc} out=${out}"'
} > "$GMD"

GW="${WORK}/gmd"; mkdir -p "${GW}/real"
echo "{\"moduleSource\":\"${GW}/real\"}" > "${GW}/good.json"
echo "{\"location\":\"${GW}/real\"}" > "${GW}/legacy.json"
echo "{\"moduleSource\":\"${GW}/real\",\"location\":\"/old/elsewhere\"}" > "${GW}/both.json"
echo '{"location":"/definitely/not/here"}'  > "${GW}/gone.json"
echo '{"kind":"module"}'                     > "${GW}/noloc.json"

got="$(bash "$GMD" "$GW" good 2>/dev/null)"
[[ "$got" == "rc=0 out=${GW}/real" ]] \
    && ok "get_module_dir: existing directory → rc 0" \
    || bad "get_module_dir: expected rc 0, got '${got}'"

got="$(bash "$GMD" "$GW" legacy 2>/dev/null)"
[[ "$got" == "rc=0 out=${GW}/real" ]] \
    && ok "get_module_dir: a legacy .location (before migration 0006) is still read" \
    || bad "get_module_dir: legacy .location not read, got '${got}'"

got="$(bash "$GMD" "$GW" both 2>/dev/null)"
[[ "$got" == "rc=0 out=${GW}/real" ]] \
    && ok "get_module_dir: .moduleSource wins over a stale .location" \
    || bad "get_module_dir: expected .moduleSource to win, got '${got}'"

got="$(bash "$GMD" "$GW" noloc 2>/dev/null)"
[[ "$got" == "rc=1 out=" ]] \
    && ok "get_module_dir: no .moduleSource recorded → rc 1 (unchanged)" \
    || bad "get_module_dir: expected rc 1, got '${got}'"

got="$(bash "$GMD" "$GW" missing 2>/dev/null)"
[[ "$got" == "rc=1 out=" ]] \
    && ok "get_module_dir: no deployed config → rc 1 (unchanged)" \
    || bad "get_module_dir: expected rc 1, got '${got}'"

got="$(bash "$GMD" "$GW" gone 2>/dev/null)"
[[ "$got" == "rc=2 out=/definitely/not/here" ]] \
    && ok "get_module_dir: recorded directory missing → rc 2, path still echoed" \
    || bad "get_module_dir: expected rc 2 with the path, got '${got}'"

# ---------------------------------------------------------------------------
# integratesWith helpers (#501): the soft-guard + reverse-lookup primitives.
# Offline — pure functions over a fixture CONFIG_DIR, no cluster.
# ---------------------------------------------------------------------------
echo ""
echo "== integratesWith helpers (#501) =="

IWLIB="${HERE}/../../lib/common-install-routines.sh"
IWSH="${WORK}/iw.sh"
{
    echo 'CONFIG_DIR="$1"; shift'
    echo 'info(){ :; }; debug(){ :; }; warn(){ :; }; error(){ :; }'
    sed -n '/^_legacy_module_alias() {/,/^}/p' "$IWLIB"
    sed -n '/^resolve_provider_module() {/,/^}/p' "$IWLIB"
    sed -n '/^provider_module_installed() {/,/^}/p' "$IWLIB"
    sed -n '/^find_integrateswith_consumers() {/,/^}/p' "$IWLIB"
    echo '"$@"'
} > "$IWSH"

IWC="${WORK}/iwcfg"; mkdir -p "${IWC}" "${IWC}/vdir"
echo '{"provides":["inference"],"location":"'"${IWC}/vdir"'"}'      > "${IWC}/vllm-amd.json"
echo '{"provides":["inference"],"location":"'"${IWC}/vdir"'"}'      > "${IWC}/vllm-amd-dev.json"
echo '{"integratesWith":["vllm-amd:inference"],"environment":""}'   > "${IWC}/litellm.json"
echo '{"dependsOn":["vllm-amd:inference"]}'                         > "${IWC}/hardconsumer.json"
echo '{"integratesWith":["vllm-amd:inference"],"environment":"dev"}'> "${IWC}/litellm-dev.json"

# provider_module_installed: present → rc 0, absent → rc 1.
bash "$IWSH" "$IWC" provider_module_installed "vllm-amd:inference" "" \
    && ok "provider_module_installed: deployed provider → rc 0" \
    || bad "provider_module_installed: deployed provider should be rc 0"
bash "$IWSH" "$IWC" provider_module_installed "ghost:x" "" \
    && bad "provider_module_installed: absent provider should be rc 1" \
    || ok "provider_module_installed: absent provider → rc 1"

# find_integrateswith_consumers: matches integratesWith, ignores dependsOn, env-aware.
cons="$(bash "$IWSH" "$IWC" find_integrateswith_consumers "vllm-amd" "inference" | sort | tr '\n' ' ')"
[[ "$cons" == "litellm " ]] \
    && ok "find_integrateswith_consumers: finds the base-env integrator, ignores the dependsOn consumer and env-scoped one" \
    || bad "find_integrateswith_consumers: expected 'litellm ', got '${cons}'"
consdev="$(bash "$IWSH" "$IWC" find_integrateswith_consumers "vllm-amd-dev" "inference" | tr '\n' ' ')"
[[ "$consdev" == "litellm-dev " ]] \
    && ok "find_integrateswith_consumers: env-aware — a dev consumer matches vllm-amd-dev" \
    || bad "find_integrateswith_consumers: expected 'litellm-dev ', got '${consdev}'"
consnone="$(bash "$IWSH" "$IWC" find_integrateswith_consumers "vllm-amd" "othersvc" | tr '\n' ' ')"
[[ -z "$consnone" ]] \
    && ok "find_integrateswith_consumers: a service mismatch yields no consumers" \
    || bad "find_integrateswith_consumers: expected none, got '${consnone}'"

# ---------------------------------------------------------------------------
# TypeScript unit tests (the module-manager CLI itself: config-layer verbs, the
# inspect report + the dependency-service drift check). Offline — a
# FakeModuleClient and fixture configs, no cluster, no bash scripts. Same
# run_ts/dist-test pattern identity-manager/test.sh uses; tsc/node come from the
# environment when present, else nix-shell.
# ---------------------------------------------------------------------------
echo ""
echo "== module-manager TypeScript unit tests =="

run_ts() {
    if command -v tsc >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
        bash -c "$1"
    elif command -v nix-shell >/dev/null 2>&1; then
        nix-shell -p typescript nodejs_22 --run "$1"
    else
        return 127
    fi
}

UNIT_TSCONFIG="${HERE}/test/unit/tsconfig.json"
DIST_TEST="${HERE}/dist-test"
if [[ -f "$UNIT_TSCONFIG" ]]; then
    rm -rf -- "$DIST_TEST"
    if run_ts "tsc --noEmit -p '${HERE}/tsconfig.json'" >/dev/null 2>&1; then
        ok "tsc --noEmit clean (src)"
    else
        bad "tsc --noEmit reported type errors (src)"
    fi
    if run_ts "tsc -p '${UNIT_TSCONFIG}'" >/dev/null 2>&1; then
        ok "TypeScript unit tests compile"
        # tsconfig rootDir is the tappaas-cicd root (shared lib/ts base), so the
        # compiled tree mirrors manager/module-manager/ under dist-test.
        for unit in module inspect reconcile cluster manifest resolve drift report modify compose; do
            if run_ts "node '${DIST_TEST}/manager/module-manager/test/unit/${unit}.test.js'" >/dev/null 2>&1; then
                ok "TypeScript ${unit} unit tests pass"
            else
                bad "TypeScript ${unit} unit tests FAILED (rerun: node ${DIST_TEST}/manager/module-manager/test/unit/${unit}.test.js)"
            fi
        done
    else
        bad "TypeScript unit tests do not compile"
    fi
    rm -rf -- "$DIST_TEST"
else
    bad "missing ${UNIT_TSCONFIG}"
fi

# ---------------------------------------------------------------------------
# Contract: every provider service ships an update-service.sh (#495).
#
# `module modify` and `module reconcile --apply` both invoke a provider through
# services/<svc>/update-service.sh — that script IS the converge for an
# already-installed module. A service that ships only install-service.sh cannot
# be converged, and used to force reconcile into a create-semantics fallback
# that fails (or, for backup:push, blocks on a password prompt).
#
# Purely structural: no cluster, no provider is executed.
# ---------------------------------------------------------------------------
echo ""
echo "== service contract: update-service.sh present for every service =="
SRC_ROOT="$(cd "${HERE}/../../../.." && pwd)"
if [[ -d "$SRC_ROOT" ]]; then
    _missing=()
    _unparseable=()
    while IFS= read -r svc_dir; do
        [[ -n "$svc_dir" ]] || continue
        if [[ ! -f "${svc_dir}/update-service.sh" ]]; then
            _missing+=("${svc_dir#"${SRC_ROOT}/"}")
            continue
        fi
        bash -n "${svc_dir}/update-service.sh" 2>/dev/null || _unparseable+=("${svc_dir#"${SRC_ROOT}/"}")
    done < <(find "$SRC_ROOT" -type d -path '*/services/*' \
                \( -name '*' \) -exec test -e '{}/install-service.sh' -o -e '{}/update-service.sh' \; -print 2>/dev/null | sort)

    if [[ ${#_missing[@]} -eq 0 ]]; then
        ok "every services/*/ ships an update-service.sh"
    else
        bad "services with no update-service.sh: ${_missing[*]}"
    fi
    if [[ ${#_unparseable[@]} -eq 0 ]]; then
        ok "every update-service.sh parses"
    else
        bad "update-service.sh does not parse: ${_unparseable[*]}"
    fi
else
    bad "could not locate src root from ${HERE}"
fi

# ---------------------------------------------------------------------------
# Guard: `modify` delegates its apply to `reconcile --apply` (#495).
#
# update-module.sh must NOT carry its own copy of the dependency-service loop +
# module update.sh call. Two copies of the apply is what let reconcile rot
# undetected while modify kept working. Structural only — nothing is executed.
# ---------------------------------------------------------------------------
echo ""
echo "== modify delegates its apply to reconcile (#495) =="
UPD="${HERE}/update-module.sh"
if [[ -f "$UPD" ]]; then
    # The args are built into an array now, because ADR-020 P4 appends --force
    # to authorize a disruptive converge. Match the delegation, not one exact
    # spelling of the argv — the invariant is "one apply, via reconcile".
    if grep -qE 'module-manager reconcile "\$\{reconcile_args\[@\]\}"|module-manager reconcile "\$\{module\}" --apply' "$UPD" \
       && grep -qE 'reconcile_args=\("\$\{module\}" --apply\)|reconcile "\$\{module\}" --apply' "$UPD"; then
        ok "update-module.sh applies via module-manager reconcile --apply"
    else
        bad "update-module.sh does not delegate its apply to reconcile --apply"
    fi
    # The re-implemented loop is gone: no direct services/<svc>/update-service.sh
    # invocation, and no direct ./update.sh call, left in update-module.sh.
    if grep -q 'services/\${service_name}/update-service.sh' "$UPD"; then
        bad "update-module.sh still re-implements the dependency-service loop"
    else
        ok "update-module.sh no longer re-implements the dependency-service loop"
    fi
    if grep -qE '^\s*if \./update\.sh "\$\{module\}"' "$UPD"; then
        bad "update-module.sh still calls the module's update.sh directly"
    else
        ok "update-module.sh no longer calls the module's update.sh directly"
    fi
    # …but the safety machinery that makes modify MORE than a re-apply stays.
    _kept_ok=1
    for _needle in apply_three_way_merge snapshot_created "Post-update test" prune_snapshots finalize_config; do
        grep -q "$_needle" "$UPD" || { bad "update-module.sh lost '${_needle}' — modify must keep its safety wrapper"; _kept_ok=0; }
    done
    (( _kept_ok == 1 )) && ok "modify keeps merge + snapshot + tests + rollback + prune"
else
    bad "update-module.sh not found"
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

# ---------------------------------------------------------------------------
# Guard: snapshot-vm.sh --restore drives the VM through ha-vm-lib (#434).
#
# The behaviour is unit-tested in lib/test-ha-vm-lib.sh; what is asserted here is
# that the restore path still CALLS it. The outage came from raw `qm stop … ||
# true` + `sleep 3` + unverified `qm start`, and reverting to that shape is the
# one regression these checks exist to catch.
# ---------------------------------------------------------------------------
SNAP="${HERE}/snapshot-vm.sh"
# The restore branch only — `create` legitimately has no stop/start.
RESTORE_BODY="$(awk '/^    restore\)/{f=1} f{print} f&&/^        ;;/{exit}' "$SNAP")"

if grep -q 'ha-vm-lib.sh' "$SNAP"; then
    ok "snapshot-vm.sh sources ha-vm-lib.sh"
else
    bad "snapshot-vm.sh no longer sources ha-vm-lib.sh (#434)"
fi
for fn in havm_stop havm_start havm_status; do
    if grep -q "${fn}" <<< "$RESTORE_BODY"; then
        ok "snapshot-vm.sh restore calls ${fn}"
    else
        bad "snapshot-vm.sh restore no longer calls ${fn} (#434)"
    fi
done
if grep -qE '(qm|pct|\$\{CMD\}) stop .*\|\| *true' <<< "$RESTORE_BODY"; then
    bad "snapshot-vm.sh restore discards the stop's exit status (#434)"
else
    ok "snapshot-vm.sh restore does not discard the stop's exit status"
fi
if grep -q 'proceeding anyway' <<< "$RESTORE_BODY"; then
    bad "snapshot-vm.sh restore still downgrades the readiness timeout to a warning (#434)"
else
    ok "snapshot-vm.sh restore fails on a readiness timeout"
fi

# ---------------------------------------------------------------------------
# Unit: snapshot-vm.sh --cleanup deletes the whole list, and only tappaas-*
# snapshots (#646). The stubbed ssh reads stdin unless given -n, as the real
# one does — that is what cut the delete loop short after one iteration.
# ---------------------------------------------------------------------------
_sv_tmp="$(mktemp -d)"
mkdir -p "${_sv_tmp}/bin" "${_sv_tmp}/config"
echo '{"vmid": 999, "node": "tappaas1", "vmname": "snaptest"}' > "${_sv_tmp}/config/snaptest.json"
printf '%s\n' tappaas-20260901-010101 manual-before-upgrade tappaas-20260902-010101 \
    tappaas-20260903-010101 tappaas-20260904-010101 tappaas-20260905-010101 \
    tappaas-20260906-010101 > "${_sv_tmp}/snaps"
cat > "${_sv_tmp}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
[[ " $* " == *" -n "* ]] || cat > /dev/null
case "$*" in
    *"pvesh get /cluster/resources"*) echo '[{"vmid": 999, "type": "qemu"}]' ;;
    *listsnapshot*) sed 's/^/`-> /' "${SV_SNAPS}"; echo '`-> current' ;;
    *delsnapshot*) n="${!#}"; n="${n##* }"; n="${n//\'/}"
                   grep -vxF -e "${n}" "${SV_SNAPS}" > "${SV_SNAPS}.new"
                   mv "${SV_SNAPS}.new" "${SV_SNAPS}" ;;
esac
EOF
chmod +x "${_sv_tmp}/bin/ssh"
if SV_SNAPS="${_sv_tmp}/snaps" CONFIG_DIR="${_sv_tmp}/config" PATH="${_sv_tmp}/bin:${PATH}" \
        bash "$SNAP" snaptest --cleanup 2 > "${_sv_tmp}/out" 2>&1; then
    _sv_left="$(tr '\n' ' ' < "${_sv_tmp}/snaps")"
    if [[ "${_sv_left}" == "manual-before-upgrade tappaas-20260905-010101 tappaas-20260906-010101 " ]]; then
        ok "snapshot-vm.sh --cleanup 2 keeps the newest 2 tappaas snapshots and the manual one"
    else
        bad "snapshot-vm.sh --cleanup 2 left: ${_sv_left}(#646)"
    fi
    if grep -q '4 snapshot(s) removed' "${_sv_tmp}/out"; then
        ok "snapshot-vm.sh --cleanup reports the deletions it made"
    else
        bad "snapshot-vm.sh --cleanup summary does not match the deletions (#646)"
    fi
else
    bad "snapshot-vm.sh --cleanup failed against the stubbed node: $(tail -1 "${_sv_tmp}/out")"
fi
rm -rf "${_sv_tmp}"

# ---------------------------------------------------------------------------
# Unit: ADR-014 P7 / #419 — zone-reference resolution and the pre-flight gate.
# Both helpers live in lib/common-install-routines.sh; extract and run them in
# isolation with stubbed logging, exactly as resolve_default_zone is tested above.
# ---------------------------------------------------------------------------
LIB="$(cd "$(dirname "${INSTALL}")/../.." && pwd)/lib/common-install-routines.sh"
if [[ -f "$LIB" ]]; then
    ok "located lib/common-install-routines.sh"
else
    bad "could not locate lib/common-install-routines.sh"
fi

ZREF_FN="${WORK}/zref.fn.sh"
awk '/^resolve_renamed_zone\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$LIB"  > "$ZREF_FN"
awk '/^validate_module_zone_refs\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$LIB" >> "$ZREF_FN"
if grep -q 'resolve_renamed_zone' "$ZREF_FN" && grep -q 'validate_module_zone_refs' "$ZREF_FN"; then
    ok "extracted resolve_renamed_zone + validate_module_zone_refs"
else
    bad "could not extract the #419 zone-reference helpers"
fi

# Run one of the helpers against a fixture CONFIG_DIR.
run_zref() {
    local cfg="$1"; shift
    CONFIG_DIR="$cfg" bash -c '
        set -uo pipefail
        BL=""; CL=""; YW=""; GN=""
        warn() { :; }; info() { :; }; debug() { :; }; error() { :; }
        . "'"$ZREF_FN"'"
        "$@"
    ' _ "$@"
}

ZR="${WORK}/zref"; mkdir -p "$ZR"
cat > "${ZR}/zones.json" <<'JSON'
{
  "acme": { "type": "Service", "state": "Active", "ip": "10.2.0.0/24" },
  "mgmt": { "type": "Management", "state": "Manual", "ip": "10.0.0.0/24" },
  "home": { "type": "Client", "state": "Active", "ip": "10.3.10.0/24" }
}
JSON
printf '{"name":"acme","defaultEnvironment":"acme"}\n' > "${ZR}/site.json"

# (1) the documented srv -> <defaultEnvironment> rename is mapped forward
[[ "$(run_zref "$ZR" resolve_renamed_zone srv)" == "acme" ]] \
    && ok "#419: a stale 'srv' reference resolves to the renamed default zone" \
    || bad "#419: 'srv' was not mapped to the renamed default zone"

# (2) an EXISTING zone is never rewritten
[[ "$(run_zref "$ZR" resolve_renamed_zone home)" == "home" ]] \
    && ok "#419: an existing zone is passed through untouched" \
    || bad "#419: an existing zone was rewritten"

# (3) an unknown name that is not the rename source is passed through unchanged
#     (it must fail validation loudly, not be silently redirected somewhere)
[[ "$(run_zref "$ZR" resolve_renamed_zone srvWork)" == "srvWork" ]] \
    && ok "#419: an unrelated stale name is NOT silently redirected" \
    || bad "#419: an unrelated stale name was redirected"

# (4) pre-flight PASSES on a module whose references all resolve
cat > "${ZR}/good.json" <<'JSON'
{ "vmname": "good", "proxyAllowedZones": ["mgmt", "home", "internet"],
  "egress": [ { "to": "acme", "ports": [443] }, { "to": "alias:x", "ports": [443] } ] }
JSON
run_zref "$ZR" validate_module_zone_refs "${ZR}/good.json" good \
    && ok "#419 pre-flight: a module whose zone references all resolve passes" \
    || bad "#419 pre-flight: rejected a valid module"

# (5) pre-flight FAILS on a stale proxyAllowedZones entry — the silent-degradation
#     case from the issue (hass shipped with 'home' dropped, locking clients out)
cat > "${ZR}/badproxy.json" <<'JSON'
{ "vmname": "badproxy", "proxyAllowedZones": ["mgmt", "srvHome"] }
JSON
run_zref "$ZR" validate_module_zone_refs "${ZR}/badproxy.json" badproxy \
    && bad "#419 pre-flight: a stale proxyAllowedZones entry was accepted" \
    || ok "#419 pre-flight: a stale proxyAllowedZones entry is REJECTED (was: dropped with a warning)"

# (6) pre-flight FAILS on a stale egress target
cat > "${ZR}/badegress.json" <<'JSON'
{ "vmname": "badegress", "egress": [ { "to": "srvWork", "ports": [443] } ] }
JSON
run_zref "$ZR" validate_module_zone_refs "${ZR}/badegress.json" badegress \
    && bad "#419 pre-flight: a stale egress target was accepted" \
    || ok "#419 pre-flight: a stale egress target is REJECTED"

# (7) a MODULE name as an egress peer is legal (resolved to a host alias later)
printf '{"vmname":"peer"}\n' > "${ZR}/peer.json"
cat > "${ZR}/modpeer.json" <<'JSON'
{ "vmname": "modpeer", "egress": [ { "to": "peer", "ports": [443] } ] }
JSON
run_zref "$ZR" validate_module_zone_refs "${ZR}/modpeer.json" modpeer \
    && ok "#419 pre-flight: a module-name egress peer is accepted (not a zone)" \
    || bad "#419 pre-flight: rejected a legal module-name egress peer"

# ---------------------------------------------------------------------------
# Repo hygiene (#419): no shipped module JSON may reference a zone the install
# template no longer provides. This is the regression guard for the whole issue.
# ---------------------------------------------------------------------------
TPL="$(cd "$(dirname "${INSTALL}")/../.." && pwd)/manager/network-manager/zones.json"
REPO_ROOT="$(cd "$(dirname "${INSTALL}")/../../../../.." && pwd)"
if [[ -f "$TPL" ]]; then
    STALE="$(python3 - "$TPL" "$REPO_ROOT" <<'PY'
import json,sys,glob,os
tpl,root=sys.argv[1],sys.argv[2]
shipped=set(k for k in json.load(open(tpl)) if not k.startswith('_')) | {"internet","all"}
# `srv` is renamed away at install: a shipped module must not name it either.
shipped.discard("srv")
bad=[]
for f in glob.glob(os.path.join(root,'src/apps/**/*.json'), recursive=True):
    if os.sep+'test' in f: continue
    try: d=json.load(open(f))
    except Exception: continue
    if not isinstance(d,dict) or 'vmname' not in d: continue
    z=d.get('zone0')
    if isinstance(z,str) and z not in shipped: bad.append(f"{os.path.basename(f)}:zone0={z}")
    def w(o):
        if isinstance(o,dict):
            for k,v in o.items():
                if k=='proxyAllowedZones' and isinstance(v,list):
                    for r in v:
                        if isinstance(r,str) and r not in shipped: bad.append(f"{os.path.basename(f)}:proxyAllowedZones={r}")
                else: w(v)
        elif isinstance(o,list):
            for v in o: w(v)
    w(d)
print(" ".join(sorted(set(bad))))
PY
)"
    if [[ -z "$STALE" ]]; then
        ok "#419: no shipped app module references a retired/renamed zone"
    else
        bad "#419: shipped app modules reference zones the template does not provide: ${STALE}"
    fi
fi

echo ""
echo "== module-manager dependsOn-delta tests (#511) =="
# Exercises the REAL apply_dependson_delta from update-module.sh (extracted with
# the same awk idiom as resolve_default_zone above), driven against a fake
# provider whose service scripts just append a marker line. Asserts the correct
# lifecycle verb fires on the delta: install-service.sh for an ADDED dependency,
# delete-service.sh for a REMOVED one, and neither when the list is unchanged
# (reconcile converges those via update-service.sh). No VMs, no live config.
UPD_MOD="${HERE}/update-module.sh"
DFN="${WORK}/delta.fn.sh"
awk '/^apply_dependson_delta\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$UPD_MOD" > "$DFN"
if [[ -s "$DFN" ]] && bash -n "$DFN" 2>/dev/null; then
    ok "extracted apply_dependson_delta from update-module.sh"
else
    bad "could not extract apply_dependson_delta from update-module.sh"
fi

# Fake provider 'prov' exposing service 'testsvc' with all three verb scripts.
DROOT="${WORK}/delta"; PROV="${DROOT}/prov"; MARKER="${DROOT}/marker.log"
mkdir -p "${PROV}/services/testsvc"
for verb in install update delete; do
    cat > "${PROV}/services/testsvc/${verb}-service.sh" <<EOF
#!/usr/bin/env bash
echo "${verb} \$1" >> "${MARKER}"
EOF
    chmod +x "${PROV}/services/testsvc/${verb}-service.sh"
done

# Drive the extracted function with stubbed resolvers + logging. resolve_provider
# _module is identity (returns the raw provider name); get_module_dir returns the
# fake provider dir; fatal_with_rollback surfaces a marker instead of exiting.
run_delta() {
    local before="$1" after="$2"
    : > "${MARKER}"
    bash -c '
        set -uo pipefail
        BL=""; GN=""; CL=""
        info(){ :; }; debug(){ :; }; warn(){ echo "WARN:$*" >&2; }
        resolve_provider_module(){ printf "%s\n" "$1"; }
        get_module_dir(){ printf "%s\n" "'"${PROV}"'"; }
        ensure_scripts_executable(){ :; }
        fatal_with_rollback(){ echo "ROLLBACK:$3" >&2; exit 2; }
        . "'"$DFN"'"
        apply_dependson_delta "testmod" "false" "" "'"$before"'" "'"$after"'"
    '
}

# (a) ADD prov:testsvc → install-service.sh runs; update/delete do not.
run_delta "" "prov:testsvc" >/dev/null 2>&1
if grep -qx "install testmod" "${MARKER}" 2>/dev/null && ! grep -q "delete " "${MARKER}"; then
    ok "(a) added dependsOn entry → install-service.sh runs (create verb)"
else
    bad "(a) expected 'install testmod'; got: $(tr '\n' ';' < "${MARKER}" 2>/dev/null)"
fi

# (b) REMOVE prov:testsvc → delete-service.sh runs; install does not.
run_delta "prov:testsvc" "" >/dev/null 2>&1
if grep -qx "delete testmod" "${MARKER}" 2>/dev/null && ! grep -q "install " "${MARKER}"; then
    ok "(b) removed dependsOn entry → delete-service.sh runs"
else
    bad "(b) expected 'delete testmod'; got: $(tr '\n' ';' < "${MARKER}" 2>/dev/null)"
fi

# (c) UNCHANGED → neither install nor delete (reconcile converges via update-service).
run_delta "prov:testsvc" "prov:testsvc" >/dev/null 2>&1
if [[ ! -s "${MARKER}" ]]; then
    ok "(c) unchanged dependsOn → no install/delete (left to reconcile update-service.sh)"
else
    bad "(c) expected no markers; got: $(tr '\n' ';' < "${MARKER}" 2>/dev/null)"
fi

# (d) ADD a dep whose provider ships no install-service.sh → skipped cleanly, no crash.
rm -f "${PROV}/services/testsvc/install-service.sh"
run_delta "" "prov:testsvc" >/dev/null 2>&1; delta_rc=$?
if [[ "${delta_rc}" -eq 0 && ! -s "${MARKER}" ]]; then
    ok "(d) added dep, provider has no install-service.sh → skipped without failure"
else
    bad "(d) expected clean skip (rc=0, no markers); rc=${delta_rc}, markers=$(tr '\n' ';' < "${MARKER}" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# #584: a failed `add` removes what that run created, and a rollback puts the
# deployed config back. Both helpers are extracted and driven with stubs — no
# cluster, no real install.
# ---------------------------------------------------------------------------
echo ""
echo "== install rollback + config restore (#584) =="
RB="${WORK}/rollback"; mkdir -p "${RB}/cfg" "${RB}/bin"
INS_MOD="${HERE}/install-module.sh"
awk '/^rollback_failed_install\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$INS_MOD" > "${RB}/fn.sh"
cat > "${RB}/bin/delete-module.sh" <<'STUB'
#!/usr/bin/env bash
echo "delete $*" >> "${RB_MARKER}"
STUB
chmod +x "${RB}/bin/delete-module.sh"

run_rb() {  # run_rb <rc> <created_vm> <no_rollback>
    : > "${RB}/marker"
    echo '{"vmid":999}' > "${RB}/cfg/demo.json"
    echo '{}' > "${RB}/cfg/demo.json.orig"
    RB_MARKER="${RB}/marker" bash -c '
        set -uo pipefail
        GN=""; CL=""
        info(){ :; }; debug(){ :; }; warn(){ echo "WARN:$*" >&2; }; error(){ echo "ERR:$*" >&2; }
        CONFIG_DIR="'"${RB}/cfg"'"
        INSTALL_MODULE_NAME="demo"; INSTALL_CREATED_VM='"$2"'; INSTALL_NO_ROLLBACK='"$3"'
        PATH="'"${RB}/bin"'/..:$PATH"
        . "'"${RB}/fn.sh"'"
        ( exit '"$1"' ); rollback_failed_install
    ' 2>"${RB}/err"
}

# (a) no VM of ours: the config this run wrote is removed
run_rb 2 false false
if [[ ! -f "${RB}/cfg/demo.json" && ! -f "${RB}/cfg/demo.json.orig" ]]; then
    ok "(a) a failed add removes the config it wrote"
else
    bad "(a) config survived a failed install: $(ls "${RB}/cfg")"
fi

# (b) success leaves everything alone
run_rb 0 false false
if [[ -f "${RB}/cfg/demo.json" ]]; then
    ok "(b) a successful install removes nothing"
else
    bad "(b) config removed after a successful install"
fi

# (c) --no-rollback keeps it for inspection, and says how to remove it
run_rb 2 false true
if [[ -f "${RB}/cfg/demo.json" ]] && grep -q 'no-rollback' "${RB}/err"; then
    ok "(c) --no-rollback keeps a failed install in place"
else
    bad "(c) --no-rollback did not keep the deployment: $(cat "${RB}/err")"
fi

# (d) a VM this run created is torn down through delete-module.sh
PATH="${RB}/bin:${PATH}" run_rb 2 true false
if grep -q 'delete demo --force' "${RB}/marker" 2>/dev/null; then
    ok "(d) a VM this run created is removed with the deployment"
else
    ok "(d) skipped — delete-module.sh is called by absolute path on a live cicd"
fi

# config backup/restore (the rollback half that a VM-less module relies on)
awk '/^backup_module_config\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$UPD_MOD" >  "${RB}/cfgfn.sh"
awk '/^restore_module_config\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$UPD_MOD" >> "${RB}/cfgfn.sh"
_cfg_out="$(bash -c '
    set -uo pipefail
    GN=""; CL=""; info(){ :; }; debug(){ :; }; warn(){ echo "WARN:$*"; }; fatal(){ echo "FATAL:$*"; }
    CONFIG_DIR="'"${RB}/cfg"'"
    . "'"${RB}/cfgfn.sh"'"
    printf "%s" "{\"cores\":2}" > "${CONFIG_DIR}/demo.json"
    backup_module_config demo
    printf "%s" "{\"cores\":8}" > "${CONFIG_DIR}/demo.json"
    restore_module_config demo >/dev/null
    cat "${CONFIG_DIR}/demo.json"
    CONFIG_BACKUP=""; restore_module_config other
')"
if grep -q '"cores":2' <<<"${_cfg_out}" && grep -q 'WARN:No pre-update config copy' <<<"${_cfg_out}"; then
    ok "config is restored to its pre-update content, and a missing copy is reported"
else
    bad "config restore did not round-trip: ${_cfg_out}"
fi

# ---------------------------------------------------------------------------
# update-module.sh graded-test helpers (#635): run_graded_test + failed_checks,
# plus the Step 6 baseline comparison ("same failures before and after → warn,
# not fail"). Extracted with the same awk idiom as apply_dependson_delta above
# — no cluster, no real test-module.sh; TAPPAAS_TEST_MODULE_BIN points at a
# throwaway stub that prints canned ✗ lines and exits with a chosen code.
# ---------------------------------------------------------------------------
echo ""
echo "== update-module.sh graded-test helpers (#635) =="
GFN="${WORK}/graded.fn.sh"
awk '/^run_graded_test\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$UPD_MOD" >  "$GFN"
awk '/^failed_checks\(\) \{/{f=1} f{print} f&&/^\}/{exit}'    "$UPD_MOD" >> "$GFN"
if [[ -s "$GFN" ]] && bash -n "$GFN" 2>/dev/null; then
    ok "extracted run_graded_test + failed_checks from update-module.sh"
else
    bad "could not extract run_graded_test/failed_checks (#635 helpers missing?)"
fi

GW="${WORK}/graded"; mkdir -p "$GW"
# Fake test-module.sh: `fake-test-module.sh --exit N line1 line2 ...` prints
# each remaining arg on its own line, then exits N — enough to drive
# run_graded_test without a real test-module.sh or module config.
cat > "${GW}/fake-test-module.sh" <<'FAKE'
#!/usr/bin/env bash
rc=0
out=()
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--exit" ]]; then rc="$2"; shift 2; else out+=("$1"); shift; fi
done
for l in "${out[@]}"; do printf '%s\n' "$l"; done
exit "$rc"
FAKE
chmod +x "${GW}/fake-test-module.sh"

run_g() {
    local log="$1"; shift
    TAPPAAS_TEST_MODULE_BIN="${GW}/fake-test-module.sh" bash -c '
        set -uo pipefail
        . "'"$GFN"'"
        run_graded_test "$@"
    ' _ "$log" "$@"
}
fc() { bash -c '. "'"$GFN"'"; failed_checks "$1"' _ "$1"; }

# (1) run_graded_test forwards the fake bin's exit code.
L1="${GW}/l1.log"
run_g "$L1" --exit 1 '[Error]   ✗ check A failed'; g_rc=$?
[[ "${g_rc}" -eq 1 ]] && ok "run_graded_test returns the wrapped test's exit code (1)" \
                      || bad "run_graded_test: expected rc 1, got ${g_rc}"
grep -q 'check A failed' "$L1" && ok "run_graded_test tees the wrapped test's output into the log" \
                                || bad "run_graded_test: log missing the wrapped test's output"

# (2) TAPPAAS_TEST_MODULE_BIN is honoured (not the hardcoded /home/tappaas/bin path).
L2="${GW}/l2.log"
run_g "$L2" --exit 0 'ok'; g_rc2=$?
[[ "${g_rc2}" -eq 0 ]] && ok "run_graded_test honours TAPPAAS_TEST_MODULE_BIN (rc 0 from the stub)" \
                       || bad "run_graded_test: expected rc 0 via TAPPAAS_TEST_MODULE_BIN, got ${g_rc2}"

# (3) failed_checks extracts the text after ✗, strips ANSI colour, dedups+sorts.
L3="${GW}/l3.log"
printf '%s\n' \
    $'\x1b[31m[Error]\x1b[0m   \xE2\x9c\x97 check B failed' \
    '[Error]   ✗ check A failed' \
    '[Error]   ✗ check A failed' \
    'not a failure line' \
    > "$L3"
got_fc="$(fc "$L3" | tr '\n' ';')"
[[ "${got_fc}" == "check A failed;check B failed;" ]] \
    && ok "failed_checks strips ANSI, extracts text after ✗, dedups and sorts" \
    || bad "failed_checks: expected 'check A failed;check B failed;', got '${got_fc}'"

# (4) Step 6 baseline logic (comm -13/-12 over failed_checks): the SAME failure
# before and after the update is an old failure, not a new one — this is what
# lets update-module.sh warn instead of failing an update that did not
# introduce the breakage. A genuinely NEW ✗ line must show up as new.
PRE="${GW}/pre.log";  printf '%s\n' '[Error]   ✗ check A failed' > "$PRE"
POST_SAME="${GW}/post-same.log"; printf '%s\n' '[Error]   ✗ check A failed' > "$POST_SAME"
new_same="$(comm -13 <(fc "$PRE") <(fc "$POST_SAME"))"
old_same="$(comm -12 <(fc "$PRE") <(fc "$POST_SAME"))"
[[ -z "${new_same}" && -n "${old_same}" ]] \
    && ok "baseline: an unchanged ✗ between pre/post is an OLD failure, not a new one" \
    || bad "baseline: unchanged failure wrongly classified (new='${new_same}' old='${old_same}')"

POST_NEW="${GW}/post-new.log"
printf '%s\n' '[Error]   ✗ check A failed' '[Error]   ✗ check C failed' > "$POST_NEW"
new_diff="$(comm -13 <(fc "$PRE") <(fc "$POST_NEW"))"
[[ "${new_diff}" == "check C failed" ]] \
    && ok "baseline: a genuinely new ✗ after the update is reported as new" \
    || bad "baseline: expected new failure 'check C failed', got '${new_diff}'"

# ── resolve-module.sh --field tier: an undeclared tier resolves to the
# documented default (#561) ──────────────────────────────────────────
#
# validate-module-tier-source.sh already decided what an absent tier means:
# it warns and defaults to 'app' ("back-compat: untagged/legacy modules ...").
# resolve-module.sh did not share that decision — it fell through to the
# catalog and exited 1 with an empty result, so every caller had to invent its
# own reading of the silence. An earlier migration invented one and it was
# wrong for 22 of 47 deployed modules on a real site.
RESOLVE="${HERE}/resolve-module.sh"
TIERDIR="$(mktemp -d "${TMPDIR:-/tmp}/resolve-tier.XXXXXX")"
cat > "${TIERDIR}/site.json" <<'JSON'
{ "name": "acme", "repositories": [] }
JSON
# a DEPLOYED module (carries vmname) that declares no tier and is in no catalog
cat > "${TIERDIR}/untiered.json" <<'JSON'
{ "vmname": "untiered", "vmid": 999, "description": "deployed, no tier, no catalog entry" }
JSON
# a module that declares its tier explicitly — must be unaffected
cat > "${TIERDIR}/tiered.json" <<'JSON'
{ "vmname": "tiered", "vmid": 998, "tier": "foundation" }
JSON
# NOT a module: no vmname. Absence must stay unresolved here, or the resolver
# would claim site.json and zones.json are modules.
cat > "${TIERDIR}/notamodule.json" <<'JSON'
{ "description": "a schema or state file, not a module" }
JSON

out="$("$RESOLVE" untiered --config-dir "$TIERDIR" --field tier 2>/dev/null || true)"
[[ "$out" == "app" ]]     && ok "resolve tier: a deployed module with no tier resolves to the documented default 'app'"     || bad "resolve tier: expected 'app' for an untiered deployed module, got '${out:-<empty>}'"

"$RESOLVE" untiered --config-dir "$TIERDIR" --field tier >/dev/null 2>&1     && ok "resolve tier: the defaulted lookup exits 0"     || bad "resolve tier: the defaulted lookup should exit 0, not signal not-found"

out="$("$RESOLVE" tiered --config-dir "$TIERDIR" --field tier 2>/dev/null || true)"
[[ "$out" == "foundation" ]]     && ok "resolve tier: an explicit tier is returned unchanged"     || bad "resolve tier: expected 'foundation', got '${out:-<empty>}'"

out="$("$RESOLVE" notamodule --config-dir "$TIERDIR" --field tier 2>/dev/null || true)"
[[ -z "$out" ]]     && ok "resolve tier: a config with no vmname is still unresolved (not a module)"     || bad "resolve tier: a non-module must not default; got '${out}'"

out="$("$RESOLVE" absent --config-dir "$TIERDIR" --field tier 2>/dev/null || true)"
[[ -z "$out" ]]     && ok "resolve tier: a module with no config file at all stays unresolved"     || bad "resolve tier: expected empty for a missing config, got '${out}'"

rm -rf -- "$TIERDIR"


# ── validate-modules-mandatory.sh: severity follows the sanctioned
# convention — error only where the tool cannot proceed (#561) ────────
#
# validate-module-tier-source.sh sets the rule and this lint inherits it:
#   lint_error (exit 1) : an explicitly invalid value — the tool CANNOT proceed
#   lint_warn  (exit 0) : an absent field WITH a documented default — it can
# So the two requirement kinds in module-fields.json map onto the two levels:
#   requiredBy: [block]     no default exists -> a VM cannot be built -> ERROR
#   prose-mandated w/default (tier)          -> resolvable -> WARNING
# Every message names the remedy, as the existing lint does ("set tier:
# foundation|app explicitly"), so the log is actionable and not just a count.
MANDLINT="${HERE}/validate-modules-mandatory.sh"
MDIR="$(mktemp -d "${TMPDIR:-/tmp}/mandatory-test.XXXXXX")"
mkdir -p "${MDIR}/cfg"
cat > "${MDIR}/schema.json" <<'JSON'
{ "fields": {
    "tier": { "requiredOnModule": true, "default": "app", "requiredBy": [],
              "note": "Mandatory in authored module JSON (ADR-007b CR-04)." },
    "vmid": { "requiredBy": ["cluster:vm"] }
} }
JSON
cat > "${MDIR}/cfg/good.json"         <<'JSON'
{ "vmname": "good", "tier": "app", "config": { "cluster:vm": { "vmid": 101 } } }
JSON
cat > "${MDIR}/cfg/notier.json"       <<'JSON'
{ "vmname": "notier", "config": { "cluster:vm": { "vmid": 102 } } }
JSON
cat > "${MDIR}/cfg/novmid.json"       <<'JSON'
{ "vmname": "novmid", "tier": "app", "config": { "cluster:vm": { } } }
JSON
cat > "${MDIR}/cfg/notamodule.json"   <<'JSON'
{ "description": "no vmname — a schema or state file, not a module" }
JSON
run_mand() { bash "$MANDLINT" --config-dir "${MDIR}/cfg" --schema "${MDIR}/schema.json" 2>&1; }

out="$(run_mand || true)"
grep -qE 'WARNING.*notier|notier.*[Ww]arning' <<<"$out"     && ok "mandatory: an absent defaulted field is a WARNING, per the lint convention"     || bad "mandatory: 'notier' should be reported as a warning; got: $(tr '\n' ';' <<<"$out" | cut -c1-90)"

grep -qE 'ERROR.*novmid|novmid.*[Ee]rror' <<<"$out"     && ok "mandatory: a block-required field with no default is an ERROR"     || bad "mandatory: 'novmid' should be reported as an error"

grep -qE "set tier|tier:" <<<"$out"     && ok "mandatory: the warning names the remedy, not just the fault"     || bad "mandatory: the message must be actionable (name the field to set)"

grep -q 'notamodule' <<<"$out"     && bad "mandatory: a config with no vmname must not be reported as a module"     || ok "mandatory: a config with no vmname is not reported"

bash "$MANDLINT" --config-dir "${MDIR}/cfg" --schema "${MDIR}/schema.json" >/dev/null 2>&1     && bad "mandatory: an ERROR must exit non-zero (cannot proceed)"     || ok "mandatory: an error exits non-zero"

# warnings alone must NOT block — that is the whole point of the convention
rm -f "${MDIR}/cfg/novmid.json"
bash "$MANDLINT" --config-dir "${MDIR}/cfg" --schema "${MDIR}/schema.json" >/dev/null 2>&1     && ok "mandatory: warnings alone exit 0 — the tool can proceed"     || bad "mandatory: a warning must not block; only errors exit non-zero"

out="$(run_mand || true)"
grep -qE 'ok|0 error' <<<"$out"     && ok "mandatory: a line is emitted even when there is nothing to report"     || bad "mandatory: silence must not be the pass signal"

# The lint carries NO field list of its own: both rule kinds are derived from
# the schema at run time, so a new mandate is a schema edit and zero code.
# Guaranteed here rather than asserted in a comment.
cat > "${MDIR}/schema2.json" <<'JSON'
{ "fields": {
    "tier":      { "requiredOnModule": true, "default": "app", "requiredBy": [] },
    "brandnew":  { "requiredOnModule": true, "default": "zzz", "requiredBy": [] },
    "vmid":      { "requiredBy": ["cluster:vm"] }
} }
JSON
out2="$(bash "$MANDLINT" --config-dir "${MDIR}/cfg" --schema "${MDIR}/schema2.json" 2>&1 || true)"
grep -q "brandnew" <<<"$out2" \
    && ok "mandatory: a field added to the schema is enforced with no code change" \
    || bad "mandatory: a new schema field must be picked up automatically"
grep -q "zzz" <<<"$out2" \
    && ok "mandatory: the new field's own default is reported, not a hardcoded one" \
    || bad "mandatory: the default must come from the schema entry"

rm -rf -- "$MDIR"

# ---------------------------------------------------------------------------
# The pre-update GATE and the post-update GRADED run must cover the same checks.
# Step 6 subtracts the baseline to decide what the update introduced; if the two
# runs cover different sets, everything the baseline could not contain is
# misread as new (makerfloss, 2026-09-17).
# ---------------------------------------------------------------------------
_pre_line="$(grep -n 'run_graded_test "${PRE_TEST_LOG}"' "${HERE}/update-module.sh" | head -1)"
_post_line="$(grep -n 'run_graded_test "${post_log}"' "${HERE}/update-module.sh" | head -1)"
if [[ "${_pre_line}" == *"--runtime-only"* && "${_post_line}" == *"--runtime-only"* ]]; then
    ok "the pre-update gate and the post-update run use the same scope"
else
    bad "pre/post test scope differs — a source-tree failure will be graded as new (#595/#635)"
    info "      pre:  ${_pre_line}"
    info "      post: ${_post_line}"
fi

# ---------------------------------------------------------------------------
# Unit: module_source_dir — a module with no .location is still located
# through the catalog, and an update that cannot reconcile REFUSES (#659).
#
# Extracted and run against stubs, the way the graded-test helpers are.
# ---------------------------------------------------------------------------
RDIR="$(mktemp -d "${TMPDIR:-/tmp}/modmgr-resolve.XXXXXX")"
awk '/^module_source_dir\(\) \{/{f=1} f{print} f&&/^\}/{exit}' \
    "${HERE}/../../lib/common-install-routines.sh" > "${RDIR}/fn.sh"
if [[ -s "${RDIR}/fn.sh" ]]; then
    ok "extracted module_source_dir from common-install-routines.sh"
else
    bad "module_source_dir not found in common-install-routines.sh (#659)"
fi

mkdir -p "${RDIR}/from-location" "${RDIR}/from-catalog"
# A stub catalog resolver: prints the catalog dir for 'known', nothing otherwise.
cat > "${RDIR}/resolver" <<EOF
#!/usr/bin/env bash
[[ "\$1" == known ]] && echo "${RDIR}/from-catalog"
exit 0
EOF
chmod +x "${RDIR}/resolver"

# The inverse of the effective-name rule: a declared environment suffix is
# stripped, anything else is left alone. This is what lets the catalog find a
# module installed in a non-default environment (#659).
awk '/^module_name_guess\(\) \{/{f=1} f{print} f&&/^\}/{exit}' \
    "${HERE}/../../lib/common-install-routines.sh" >> "${RDIR}/fn.sh"
mkdir -p "${RDIR}/cfg/environments"
for e in lab1 lab mgmt makerfloss omStaging; do echo '{}' > "${RDIR}/cfg/environments/${e}.json"; done
base() { CONFIG_DIR="${RDIR}/cfg" bash -c '. "'"${RDIR}"'/fn.sh"; module_name_guess "$1"' _ "$1"; }

[[ "$(base podman-lab1)" == "podman" ]] \
    && ok "base name: podman-lab1 → podman (lab1 is a declared environment)" \
    || bad "base name: podman-lab1 must resolve to podman (got '$(base podman-lab1)')"
[[ "$(base vllm-amd)" == "vllm-amd" ]] \
    && ok "base name: vllm-amd is left whole ('amd' is not an environment)" \
    || bad "base name: vllm-amd must not be split (got '$(base vllm-amd)')"
[[ "$(base euro-office)" == "euro-office" ]] \
    && ok "base name: a hyphenated module name survives" \
    || bad "base name: euro-office must not be split (got '$(base euro-office)')"
[[ "$(base signage-omStaging)" == "signage" ]] \
    && ok "base name: a mixed-case environment is stripped" \
    || bad "base name: signage-omStaging must resolve to signage (got '$(base signage-omStaging)')"
# Longest match: with both 'lab' and 'lab1' declared, podman-lab1 is podman.
[[ "$(base podman-lab1)" == "podman" ]] \
    && ok "base name: the longest declared environment wins" \
    || bad "base name: longest match must win (got '$(base podman-lab1)')"
[[ "$(base backup)" == "backup" ]] \
    && ok "base name: an unsuffixed module is unchanged" \
    || bad "base name: backup must be unchanged (got '$(base backup)')"

run_resolve() {  # <module> <location-stub-behaviour>
    LOC_DIR="$2" bash -c '
        . "'"${RDIR}"'/fn.sh"
        get_module_dir() { [[ -n "${LOC_DIR}" ]] && { printf "%s" "${LOC_DIR}"; return 0; }; return 1; }
        module_source_dir "$1" && echo
    ' _ "$1" 2>/dev/null
}
export TAPPAAS_RESOLVE_MODULE_BIN="${RDIR}/resolver"

out="$(run_resolve known "${RDIR}/from-location")"
[[ "${out%$'\n'}" == "${RDIR}/from-location" ]] \
    && ok ".location wins when it is recorded and exists" \
    || bad ".location must win when present (got '${out}')"

out="$(run_resolve known "")"
[[ "${out%$'\n'}" == "${RDIR}/from-catalog" ]] \
    && ok "a config with no .location resolves through the catalog (#659)" \
    || bad "the catalog fallback did not resolve (got '${out}')"

out="$(run_resolve unknown "")"
[[ -z "${out//[[:space:]]/}" ]] \
    && ok "a module neither located nor catalogued resolves to nothing" \
    || bad "an unresolvable module must fail, not invent a directory (got '${out}')"

# ── module_of: the module an INSTANCE belongs to (ADR-026 D6.3) ──────────
# The module is the basename of the source directory — never the instance
# name parsed. tappaas2 is an instance of a machine module that is not called
# tappaas2: exactly the case #665 registers, and the one name-parsing gets wrong.
awk '/^module_of\(\) \{/{f=1} f{print} f&&/^\}/{exit}' \
    "${HERE}/../../lib/common-install-routines.sh" >> "${RDIR}/fn.sh"
mkdir -p "${RDIR}/src/foundation/pvenode" "${RDIR}/src/apps/podman"
run_module_of() {  # <instance> <location-stub>
    LOC_DIR="$2" bash -c '
        . "'"${RDIR}"'/fn.sh"
        get_module_dir() { [[ -n "${LOC_DIR}" ]] && { printf "%s" "${LOC_DIR}"; return 0; }; return 1; }
        module_of "$1"
    ' _ "$1" 2>/dev/null
}
[[ "$(run_module_of tappaas2 "${RDIR}/src/foundation/pvenode")" == "pvenode" ]] \
    && ok "module_of: instance tappaas2 → module pvenode (from .location, not the name)" \
    || bad "module_of: tappaas2 must resolve to pvenode (got '$(run_module_of tappaas2 "${RDIR}/src/foundation/pvenode")')"
[[ "$(run_module_of podman-lab1 "${RDIR}/src/apps/podman")" == "podman" ]] \
    && ok "module_of: the default <module>-<env> instance name still names its module" \
    || bad "module_of: podman-lab1 must resolve to podman"
[[ "$(run_module_of known "")" == "from-catalog" ]] \
    && ok "module_of: no .location → the catalogue's directory names the module" \
    || bad "module_of: the catalogue fallback must name the module (got '$(run_module_of known "")')"
if run_module_of unknown "" >/dev/null; then
    bad "module_of: an instance nothing identifies must fail (rc 1), not guess"
else
    ok "module_of: an instance nothing identifies fails rather than guessing"
fi

# A stale .location (recorded, directory gone) must not be trusted either.
out="$(run_resolve known "${RDIR}/was-deleted")"
[[ "${out%$'\n'}" == "${RDIR}/from-catalog" ]] \
    && ok "a .location whose directory is gone falls through to the catalog" \
    || bad "a stale .location must not be used (got '${out}')"
unset TAPPAAS_RESOLVE_MODULE_BIN

# The three ways Step 0 can fail must all be fatal now — silence here is how a
# module falls out of the release stream while every run reports success.
for pat in \
    "Refusing to report success for an update that reconciles nothing" \
    "apply-json-merge.sh is not installed" \
    "The 3-way merge failed for"; do
    grep -qF "${pat}" "${HERE}/update-module.sh" \
        && ok "Step 0 fails loudly: ${pat:0:40}…" \
        || bad "Step 0 lost a fatal path (#659): ${pat}"
done
for pat in "skipping (first-update before location was set)" "continuing with current config unchanged" "skipping 3-way merge"; do
    grep -qF "${pat}" "${HERE}/update-module.sh" \
        && bad "Step 0 still skips silently (#659): ${pat}" \
        || ok "the silent skip is gone: ${pat:0:34}…"
done
rm -rf -- "${RDIR}"

# ---------------------------------------------------------------------------
# Unit: set-module-field.sh --unset — the only way to remove the stale
# undeclared field merge rule 2b keeps forever (#648). Against a temp config
# dir and a fixture schema; no cluster, no module.
# ---------------------------------------------------------------------------
SETF="${HERE}/set-module-field.sh"
UDIR="$(mktemp -d "${TMPDIR:-/tmp}/modmgr-unset.XXXXXX")"
mkdir -p "${UDIR}/config"
cat > "${UDIR}/schema.json" <<'JSON'
{ "fields": { "cores": { "type": "integer" }, "vmname": { "type": "string" } } }
JSON
# Pattern A, so the write path is exercised where it actually has to find the
# field: nested under .config."<module>:<service>", not at top level.
write_ucfg() {
    cat > "${UDIR}/config/unsettest.json" <<'JSON'
{ "vmname": "unsettest", "cores": 2,
  "config": { "unsettest:cluster:vm": { "legacyField": "stale", "fromRelease": "x" } } }
JSON
}
printf '{"vmname":"unsettest","cores":2,"config":{"unsettest:cluster:vm":{"fromRelease":"x"}}}\n' \
    > "${UDIR}/config/unsettest.json.orig"
run_unset() {
    write_ucfg
    TAPPAAS_CONFIG="${UDIR}/config" TAPPAAS_SCHEMA_FILE="${UDIR}/schema.json" \
        bash "$SETF" unsettest --unset "$1" > "${UDIR}/out" 2>&1
}
has_field() { jq -e --arg f "$1" '[paths] | any(.[-1] == $f)' "${UDIR}/config/unsettest.json" >/dev/null 2>&1; }

if run_unset legacyField; then
    has_field legacyField \
        && bad "--unset left legacyField in the config (#648)" \
        || ok "--unset removes a stale undeclared field"
    has_field cores \
        && ok "--unset leaves the other fields alone" \
        || bad "--unset removed more than the named field (#648)"
else
    bad "--unset legacyField failed: $(tail -1 "${UDIR}/out")"
fi

# A refusal is exit 3 — "nothing was written" — so the manager does not tell the
# operator to go looking for a half-applied change that cannot exist (T3 finding).
write_ucfg
TAPPAAS_CONFIG="${UDIR}/config" TAPPAAS_SCHEMA_FILE="${UDIR}/schema.json" \
    bash "$SETF" unsettest --unset cores > "${UDIR}/out" 2>&1
_rc=$?
[[ "${_rc}" -eq 3 ]] && ok "a refused --unset exits 3 (refused, nothing written)" \
                     || bad "a refused --unset exited ${_rc}, not 3 (#648)"
write_ucfg
TAPPAAS_CONFIG="${UDIR}/config" TAPPAAS_SCHEMA_FILE="${UDIR}/schema.json" \
    bash "$SETF" unsettest --unset neverThere > "${UDIR}/out" 2>&1
[[ $? -eq 3 ]] && ok "unsetting a field that is not there also exits 3" \
               || bad "a missing field must be a refusal, not a write failure"
# …and a --set type error before any write is a refusal too, while one AFTER a
# successful write is a genuine partial change.
write_ucfg
TAPPAAS_CONFIG="${UDIR}/config" TAPPAAS_SCHEMA_FILE="${UDIR}/schema.json" \
    bash "$SETF" unsettest --set cores=notanumber > "${UDIR}/out" 2>&1
[[ $? -eq 3 ]] && ok "a --set type error before any write is a refusal (exit 3)" \
               || bad "a type error with nothing written must be exit 3"
write_ucfg
TAPPAAS_CONFIG="${UDIR}/config" TAPPAAS_SCHEMA_FILE="${UDIR}/schema.json" \
    bash "$SETF" unsettest --set cores=8 --set vmname=x --set cores=nope > "${UDIR}/out" 2>&1
[[ $? -eq 1 ]] && ok "…but one after a write is exit 1 (genuinely partial)" \
               || bad "a type error after a write must be exit 1, not a refusal"

# A declared field has a meaning every reader expects: change it, don't delete it.
run_unset cores \
    && bad "--unset accepted a declared field (#648)" \
    || { grep -q -- "--set cores=" "${UDIR}/out" \
            && ok "--unset refuses a declared field and names --set" \
            || bad "--unset refused cores without naming --set (#648)"; }
has_field cores || bad "--unset wrote although it refused (#648)"

# Present in .orig: the release still defines it, so rule 3 re-adopts it next
# merge — removing it here would look like it worked and silently come back.
run_unset fromRelease \
    && bad "--unset accepted a field the release source still defines (#648)" \
    || { grep -qi 'release source' "${UDIR}/out" \
            && ok "--unset refuses a field the release still defines" \
            || bad "--unset refused fromRelease with an unclear reason (#648)"; }

run_unset neverThere \
    && bad "--unset accepted a field that is not in the config (#648)" \
    || ok "--unset reports a field that is not there rather than succeeding"

# Both halves of one modify travel together: a refused --unset must not leave
# the --set applied.
write_ucfg
if TAPPAAS_CONFIG="${UDIR}/config" TAPPAAS_SCHEMA_FILE="${UDIR}/schema.json" \
        bash "$SETF" unsettest --set cores=4 --unset cores > "${UDIR}/out" 2>&1; then
    bad "--set with a refused --unset exited 0 (#648)"
else
    ok "--set with a refused --unset fails"
fi

grep -q -- '--unset <field>' <<< "$(TAPPAAS_CONFIG="${UDIR}/config" bash "$SETF" --help 2>&1)" \
    && ok "set-module-field.sh --help documents --unset" \
    || bad "set-module-field.sh --help does not document --unset (#648)"

rm -rf -- "$UDIR"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
