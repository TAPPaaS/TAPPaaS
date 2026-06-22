#!/usr/bin/env bash
#
# test.sh — tests for people-manager (ADR-007 P1, S2b-3).
#
# Three tiers:
#   A. OFFLINE bash tests (no Authentik, no cluster):
#      - example people fixtures validate
#      - minimal-org/ validates with placeholder tokens treated as valid slugs
#      - validate.sh catches: missing required field, dangling ownerOrg,
#        dangling memberOf, dangling role reference
#      - a user with multiple roles + membership across >1 org validates
#      - user-setup.sh copies + substitutes correctly; result has the expected
#        shape and passes validate.sh
#   B. TypeScript UNIT tests (offline, fake in-memory PrimitiveClient) covering
#      every ADR-007 P1 reconcile Test Criteria bullet — run via tsc + node.
#   C. LIVE integration test (scoped to zztest- names, self-cleaning) against
#      real Authentik via `people-manager sync` + `authentik-manager`. SKIPS
#      gracefully if Authentik is unreachable; NEVER touches non-zztest- entities.
#
# Prints "Results: N passed, M failed"; exits 1 on any failure.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="${HERE}/validate.sh"
USER_SETUP="${HERE}/user-setup.sh"
MINIMAL_ORG="${HERE}/minimal-org"
FOUNDATION_DIR="$(cd "${HERE}/../../.." && pwd)"
SCHEMA_DIR="${FOUNDATION_DIR}/schemas"
# Example people domain (myOrg/foo/bar) — TEST FIXTURE ONLY, never committed as
# runtime config. "config" = the target system's ~tappaas/config, created/edited
# by the installer + people-manager, NOT stored in the repo.
EXAMPLE_PEOPLE="${HERE}/test/fixtures/people"

PASS=0
FAIL=0

WORK="$(mktemp -d "${TMPDIR:-/tmp}/people-test.XXXXXX")"
cleanup() { [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf -- "$WORK"; return 0; }
trap cleanup EXIT INT TERM

ok()   { echo "  ok: $*"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# run validate.sh quietly; returns its exit code
run_validate() {
    "$VALIDATE" --schema-dir "$SCHEMA_DIR" --quiet "$1" >/dev/null 2>&1
}

# Build a known-good people tree in $1 (multi-org, multi-role user).
seed_good_tree() {
    local d="$1"
    mkdir -p "$d"/{roles,organizations,groups,users}

    cat > "$d/roles/root.json"  <<'JSON'
{ "name": "root",  "displayName": "Platform Root", "description": "superuser" }
JSON
    cat > "$d/roles/admin.json" <<'JSON'
{ "name": "admin", "displayName": "Administrator", "description": "admin" }
JSON
    cat > "$d/roles/user.json"  <<'JSON'
{ "name": "user",  "displayName": "User", "description": "user" }
JSON

    cat > "$d/organizations/orgA.json" <<'JSON'
{ "name": "orgA", "type": "company", "displayName": "Org A", "owner": "alice" }
JSON
    cat > "$d/organizations/orgB.json" <<'JSON'
{ "name": "orgB", "type": "customer", "displayName": "Org B", "owner": "alice", "parentOrg": "orgA" }
JSON

    cat > "$d/groups/orgA__admins.json" <<'JSON'
{ "name": "orgA__admins", "type": "team", "displayName": "A admins", "ownerOrg": "orgA", "roles": ["admin"] }
JSON
    cat > "$d/groups/orgB__users.json" <<'JSON'
{ "name": "orgB__users", "type": "team", "displayName": "B users", "ownerOrg": "orgB", "roles": ["user"] }
JSON

    # alice: 2 direct roles + membership across orgA and orgB
    cat > "$d/users/alice.json" <<'JSON'
{
  "name": "alice",
  "displayName": "Alice",
  "primaryEmail": "alice@example.com",
  "memberOf": ["orgA__admins", "orgB__users"],
  "roles": ["root", "admin"]
}
JSON
}

echo "== people-manager offline tests =="

# ---------------------------------------------------------------------------
# 1. Committed example files validate
# ---------------------------------------------------------------------------
if [[ -d "$EXAMPLE_PEOPLE" ]]; then
    if run_validate "$EXAMPLE_PEOPLE"; then
        ok "example people fixtures validate"
    else
        bad "example people fixtures should validate"
    fi
else
    bad "example people dir not found: ${EXAMPLE_PEOPLE}"
fi

# ---------------------------------------------------------------------------
# 2. minimal-org validates with placeholder tokens
# ---------------------------------------------------------------------------
if run_validate "$MINIMAL_ORG"; then
    ok "minimal-org validates with placeholder tokens"
else
    bad "minimal-org should validate with placeholder tokens"
fi

# ---------------------------------------------------------------------------
# 3. Known-good multi-org / multi-role user tree validates
# ---------------------------------------------------------------------------
GOOD="${WORK}/good"
seed_good_tree "$GOOD"
if run_validate "$GOOD"; then
    ok "user with multiple roles + membership across >1 org validates"
else
    bad "good multi-org tree should validate"
fi

# ---------------------------------------------------------------------------
# 4. Broken fixtures — each must FAIL validation
# ---------------------------------------------------------------------------

# 4a. missing required field (user.primaryEmail)
B1="${WORK}/broken-missing-field"
seed_good_tree "$B1"
cat > "$B1/users/bob.json" <<'JSON'
{ "name": "bob", "displayName": "Bob", "memberOf": ["orgA__admins"] }
JSON
if run_validate "$B1"; then
    bad "missing required field (primaryEmail) should be caught"
else
    ok "catches missing required field (primaryEmail)"
fi

# 4b. dangling ownerOrg
B2="${WORK}/broken-ownerorg"
seed_good_tree "$B2"
cat > "$B2/groups/ghost__team.json" <<'JSON'
{ "name": "ghost__team", "type": "team", "displayName": "Ghost", "ownerOrg": "no-such-org", "roles": ["user"] }
JSON
if run_validate "$B2"; then
    bad "dangling ownerOrg should be caught"
else
    ok "catches dangling group.ownerOrg"
fi

# 4c. dangling memberOf
B3="${WORK}/broken-memberof"
seed_good_tree "$B3"
cat > "$B3/users/carol.json" <<'JSON'
{ "name": "carol", "displayName": "Carol", "primaryEmail": "carol@example.com", "memberOf": ["no-such-group"] }
JSON
if run_validate "$B3"; then
    bad "dangling memberOf should be caught"
else
    ok "catches dangling user.memberOf"
fi

# 4d. dangling role reference (user.roles)
B4="${WORK}/broken-role"
seed_good_tree "$B4"
cat > "$B4/users/dave.json" <<'JSON'
{ "name": "dave", "displayName": "Dave", "primaryEmail": "dave@example.com", "roles": ["no-such-role"] }
JSON
if run_validate "$B4"; then
    bad "dangling role reference should be caught"
else
    ok "catches dangling user.roles reference"
fi

# ---------------------------------------------------------------------------
# 5. user-setup.sh copies + substitutes correctly
# ---------------------------------------------------------------------------
DEST="${WORK}/setup/people"
if "$USER_SETUP" --org acme-site --user lars --email lars@example.com \
        --people-dir "$DEST" --minimal-org "$MINIMAL_ORG" >/dev/null 2>&1; then
    ok "user-setup.sh runs and self-validates"
else
    bad "user-setup.sh should succeed and self-validate"
fi

# Shape assertions (only meaningful if the copy happened)
if [[ -d "$DEST" ]]; then
    n_org=$(find "$DEST/organizations" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
    n_grp=$(find "$DEST/groups" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
    n_usr=$(find "$DEST/users" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
    n_rol=$(find "$DEST/roles" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')

    [[ "$n_org" == "1" ]] && ok "result has exactly 1 organization" || bad "expected 1 org, found ${n_org}"
    [[ "$n_rol" == "3" ]] && ok "result has 3 roles" || bad "expected 3 roles, found ${n_rol}"
    [[ "$n_usr" == "1" ]] && ok "result has 1 installer user" || bad "expected 1 user, found ${n_usr}"

    # group files named <org>__admin and <org>__users
    if [[ "$n_grp" == "2" && -f "$DEST/groups/acme-site__admin.json" && -f "$DEST/groups/acme-site__users.json" ]]; then
        ok "result has groups acme-site__admin + acme-site__users"
    else
        bad "expected groups acme-site__admin + acme-site__users (found ${n_grp} group files)"
    fi

    # placeholders fully substituted (no __ORG__/__USER__/__EMAIL__ remain)
    if grep -rqE '__(ORG|USER|EMAIL)__' "$DEST" 2>/dev/null; then
        bad "placeholders remain after substitution"
    else
        ok "no placeholder tokens remain after substitution"
    fi

    # installer user: name=lars, root role, member of acme-site__admin, email substituted
    uf="$DEST/users/lars.json"
    if [[ -f "$uf" ]] \
        && [[ "$(jq -r '.name' "$uf")" == "lars" ]] \
        && [[ "$(jq -r '.primaryEmail' "$uf")" == "lars@example.com" ]] \
        && [[ "$(jq -r '.roles | index("root") != null' "$uf")" == "true" ]] \
        && [[ "$(jq -r '.memberOf | index("acme-site__admin") != null' "$uf")" == "true" ]]; then
        ok "installer user has root role + membership in acme-site__admin"
    else
        bad "installer user lars.json not shaped as expected"
    fi

    # the produced tree passes validate.sh independently
    if run_validate "$DEST"; then
        ok "user-setup.sh result passes validate.sh"
    else
        bad "user-setup.sh result should pass validate.sh"
    fi
else
    bad "user-setup.sh did not create destination ${DEST}"
fi

# ---------------------------------------------------------------------------
# 6. user-setup.sh arg validation (missing required arg fails)
# ---------------------------------------------------------------------------
if "$USER_SETUP" --org acme --user lars --people-dir "${WORK}/never" \
        --minimal-org "$MINIMAL_ORG" >/dev/null 2>&1; then
    bad "user-setup.sh should fail when --email is missing"
else
    ok "user-setup.sh rejects missing --email"
fi

# ===========================================================================
# B. TypeScript UNIT tests (offline; fake in-memory PrimitiveClient)
# ===========================================================================
echo ""
echo "== people-manager TypeScript unit tests =="

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
        if run_ts "node '${DIST_TEST}/test/unit/reconcile.test.js'"; then
            ok "TypeScript reconcile unit tests pass"
        else
            bad "TypeScript reconcile unit tests FAILED"
        fi
    else
        bad "TypeScript unit tests failed to compile"
    fi
    rm -rf -- "$DIST_TEST"
else
    bad "unit test tsconfig not found: ${UNIT_TSCONFIG}"
fi

# ===========================================================================
# C. LIVE integration test (scoped to zztest- names; self-cleaning)
# ===========================================================================
echo ""
echo "== people-manager live integration test (zztest- scope) =="

PM_BIN="${PEOPLE_MANAGER_BIN:-people-manager}"
AK_BIN="${AUTHENTIK_MANAGER_BIN:-authentik-manager}"
ZUSER1="zztest-user-alpha"
ZUSER2="zztest-user-beta"
ZORG="zztest-org"
ZGROUP="${ZORG}__admins"
ZROLE="zztest-role"

# Delete a single zztest- core group (or role-marked group) via the Authentik
# REST API. The identity-controller people primitive set has NO group/role
# delete verb (existence is additive by design), so the test purges its own
# zztest- groups/roles directly — STRICTLY guarded to names beginning zztest-.
AK_CREDS="${AUTHENTIK_CREDENTIALS:-/home/tappaas/.authentik-credentials.txt}"
zz_delete_group() {
    local name="$1"
    case "$name" in zztest-*) ;; *) return 0 ;; esac  # hard scope guard
    [[ -f "$AK_CREDS" ]] || return 0
    command -v curl >/dev/null 2>&1 || return 0
    local url tok pk
    url="$(grep '^url=' "$AK_CREDS" | cut -d= -f2-)"
    tok="$(grep '^token=' "$AK_CREDS" | cut -d= -f2-)"
    [[ -n "$url" && -n "$tok" ]] || return 0
    pk="$(curl -sf -H "Authorization: Bearer ${tok}" "${url}/api/v3/core/groups/?name=${name}" \
            | jq -r '.results[0].pk // empty' 2>/dev/null || true)"
    [[ -n "$pk" ]] && curl -sf -X DELETE -H "Authorization: Bearer ${tok}" \
        "${url}/api/v3/core/groups/${pk}/" >/dev/null 2>&1 || true
    return 0
}

# Hard-delete every zztest- entity we might have created. Safe to call anytime;
# only ever names zztest- entities, so non-zztest- is never touched.
zz_cleanup() {
    command -v "$AK_BIN" >/dev/null 2>&1 || return 0
    "$AK_BIN" delete-user --name "$ZUSER1" >/dev/null 2>&1 || true
    "$AK_BIN" delete-user --name "$ZUSER2" >/dev/null 2>&1 || true
    # groups + role-marked groups via REST (no people-primitive delete exists)
    zz_delete_group "$ZGROUP"
    zz_delete_group "$ZROLE"
    return 0
}

# Confirm Authentik reachability without mutating anything.
if ! command -v "$PM_BIN" >/dev/null 2>&1; then
    echo "  SKIP: people-manager not on PATH (run install.sh first)"
elif ! "$AK_BIN" test >/dev/null 2>&1; then
    echo "  SKIP: Authentik unreachable (authentik-manager test failed) — live test skipped"
else
    # Always clean up zztest- residue on exit, even on failure.
    LIVE_WORK="$(mktemp -d "${TMPDIR:-/tmp}/people-live.XXXXXX")"
    live_cleanup() {
        zz_cleanup
        [[ -n "${LIVE_WORK:-}" && -d "$LIVE_WORK" ]] && rm -rf -- "$LIVE_WORK"
        return 0
    }
    trap live_cleanup EXIT INT TERM

    zz_cleanup  # start from a clean slate

    CFG="${LIVE_WORK}/people"
    mkdir -p "$CFG"/{roles,organizations,groups,users}
    cat > "$CFG/roles/${ZROLE}.json" <<JSON
{ "name": "${ZROLE}", "displayName": "zztest role" }
JSON
    cat > "$CFG/organizations/${ZORG}.json" <<JSON
{ "name": "${ZORG}", "type": "company", "displayName": "zztest org", "owner": "${ZUSER1}" }
JSON
    cat > "$CFG/groups/${ZGROUP}.json" <<JSON
{ "name": "${ZGROUP}", "type": "team", "displayName": "zztest admins", "ownerOrg": "${ZORG}", "roles": ["${ZROLE}"] }
JSON
    cat > "$CFG/users/${ZUSER1}.json" <<JSON
{ "name": "${ZUSER1}", "displayName": "zztest alpha", "primaryEmail": "${ZUSER1}@example.invalid", "state": "active", "memberOf": ["${ZGROUP}"] }
JSON
    cat > "$CFG/users/${ZUSER2}.json" <<JSON
{ "name": "${ZUSER2}", "displayName": "zztest beta", "primaryEmail": "${ZUSER2}@example.invalid", "state": "planned" }
JSON

    # 1. sync (active alpha created; planned beta NOT created)
    if "$PM_BIN" sync --config-dir "$CFG" >/dev/null 2>&1; then
        ok "live: people-manager sync applied"
    else
        bad "live: people-manager sync failed"
    fi

    users_json="$("$AK_BIN" list-users 2>/dev/null || echo '[]')"
    if printf '%s' "$users_json" | jq -e --arg n "$ZUSER1" 'any(.[]; .name == $n)' >/dev/null 2>&1; then
        ok "live: active user ${ZUSER1} present in Authentik"
    else
        bad "live: active user ${ZUSER1} should be present"
    fi
    if printf '%s' "$users_json" | jq -e --arg n "$ZUSER2" 'any(.[]; .name == $n)' >/dev/null 2>&1; then
        bad "live: planned user ${ZUSER2} should NOT be created"
    else
        ok "live: planned user ${ZUSER2} correctly absent"
    fi
    # alpha should have the role conferred via the group
    if printf '%s' "$users_json" | jq -e --arg n "$ZUSER1" --arg r "$ZROLE" \
            'any(.[]; .name == $n and (.roles | index($r) != null))' >/dev/null 2>&1; then
        ok "live: ${ZUSER1} has inherited role ${ZROLE}"
    else
        bad "live: ${ZUSER1} should have inherited role ${ZROLE}"
    fi

    # 2. idempotent re-run → empty plan
    plan_out="$("$PM_BIN" sync --dry-run --config-dir "$CFG" 2>/dev/null || true)"
    if printf '%s' "$plan_out" | grep -qE 'Plan: 0 action'; then
        ok "live: second sync is idempotent (0 actions)"
    else
        bad "live: second sync should be idempotent"
    fi

    # 3. terminate alpha → deleted
    cat > "$CFG/users/${ZUSER1}.json" <<JSON
{ "name": "${ZUSER1}", "displayName": "zztest alpha", "primaryEmail": "${ZUSER1}@example.invalid", "state": "terminated" }
JSON
    "$PM_BIN" sync --config-dir "$CFG" >/dev/null 2>&1 || true
    if "$AK_BIN" list-users 2>/dev/null | jq -e --arg n "$ZUSER1" 'any(.[]; .name == $n)' >/dev/null 2>&1; then
        bad "live: terminated user ${ZUSER1} should be removed"
    else
        ok "live: terminated user ${ZUSER1} removed from Authentik"
    fi

    # 4. cleanup + confirm zero zztest- residue (users, groups, AND roles)
    zz_cleanup
    ru="$("$AK_BIN" list-users  2>/dev/null | jq -r '.[].name' 2>/dev/null | grep -c '^zztest-' || true)"
    rg="$("$AK_BIN" list-groups 2>/dev/null | jq -r '.[].name' 2>/dev/null | grep -c '^zztest-' || true)"
    rr="$("$AK_BIN" list-roles  2>/dev/null | jq -r '.[].name' 2>/dev/null | grep -c '^zztest-' || true)"
    if [[ "${ru:-0}" -eq 0 && "${rg:-0}" -eq 0 && "${rr:-0}" -eq 0 ]]; then
        ok "live: zero zztest- residue after cleanup (users/groups/roles)"
    else
        bad "live: zztest- residue remains (users=${ru} groups=${rg} roles=${rr})"
    fi
    # disarm the live trap; restore the offline WORK cleanup
    trap cleanup EXIT INT TERM
    live_cleanup
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
