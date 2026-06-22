#!/usr/bin/env bash
#
# test.sh — OFFLINE tests for people-manager (no Authentik, no cluster).
#
# Covers:
#   - committed example files under config/people/ validate
#   - minimal-org/ validates with placeholder tokens treated as valid slugs
#   - validate.sh catches: missing required field, dangling ownerOrg,
#     dangling memberOf, dangling role reference
#   - a user with multiple roles + membership across >1 org validates
#   - user-setup.sh copies + substitutes correctly; result has the expected
#     shape and passes validate.sh
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
# Repo root = foundation/.. ; committed examples live at <repo>/config/people
REPO_ROOT="$(cd "${FOUNDATION_DIR}/../.." && pwd)"
EXAMPLE_PEOPLE="${REPO_ROOT}/config/people"

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
        ok "committed example config/people validates"
    else
        bad "committed example config/people should validate"
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

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
