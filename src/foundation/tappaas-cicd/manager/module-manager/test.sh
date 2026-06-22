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
    case "${b}" in install.sh|update.sh|test.sh|validate.sh) continue ;; esac
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

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
