#!/usr/bin/env bash
#
# test-repo-sync.sh — unit tests for reconcile_repo_checkout (lib/repo-sync.sh).
#
# Exercises the managed-checkout reconciler against TEMP local bare repos only —
# never the live checkout, never the network. Verifies the forge-migration fix:
#   - a change of FORGE (origin url) + BRANCH is applied (origin re-pointed, the
#     branch checked out at the NEW remote's tip, upstream set) — the bug that
#     silently kept pulling the old forge (github->codeberg incident);
#   - re-running is idempotent;
#   - a same-forge advance fast-forwards to the new tip.
#
# Usage: test-repo-sync.sh   (prints "Results: N passed, M failed"; exit 1 on fail)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info(){ :; }; warn(){ :; }                 # silence the lib's progress in tests
# shellcheck source=/dev/null
. "${HERE}/repo-sync.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); }
no(){ fail=$((fail+1)); echo "FAIL: $1"; }
check(){ if [ "$2" = "$3" ]; then ok; else no "$1 (got '$2', want '$3')"; fi; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
W="$(mktemp -d "${TMPDIR:-/tmp}/repo-sync-test.XXXXXX")"
trap 'rm -rf "${W}"' EXIT

git init -q --bare -b main "${W}/forgeA.git"
git init -q --bare -b main "${W}/forgeB.git"

# forgeA: v1 on main
git clone -q "${W}/forgeA.git" "${W}/a"
( cd "${W}/a" && echo v1 > f && git add f && git commit -qm v1 && git push -q origin main )

# forgeB: v2 on main + a 'dev' branch carrying an extra file
git clone -q "${W}/forgeA.git" "${W}/b"
( cd "${W}/b" && git remote set-url origin "${W}/forgeB.git" \
   && echo v2 > f && git commit -qam v2 && git push -q origin main \
   && git checkout -qb dev && echo devwork > d && git add d && git commit -qm dev && git push -q origin dev )

# The managed checkout: starts on forgeA/main
git clone -q "${W}/forgeA.git" "${W}/work"
cd "${W}/work"

# 1. Forge switch (A->B) + branch switch (main->dev)
reconcile_repo_checkout "${W}/work" "file://${W}/forgeB.git" dev >/dev/null 2>&1
case "$(git remote get-url origin)" in *forgeB.git) ok ;; *) no "origin re-pointed ($(git remote get-url origin))" ;; esac
check "on branch dev" "$(git branch --show-current)" "dev"
[ -f d ] && ok || no "has forgeB:dev content"
check "upstream is origin/dev" "$(git rev-parse @{u} 2>/dev/null)" "$(git rev-parse origin/dev)"

# 2. Idempotent re-run (same forge/branch)
if reconcile_repo_checkout "${W}/work" "file://${W}/forgeB.git" dev >/dev/null 2>&1; then ok; else no "idempotent re-run"; fi

# 3. Same-forge advance -> fast-forward to the new tip
( cd "${W}/b" && echo more >> d && git commit -qam more && git push -q origin dev )
reconcile_repo_checkout "${W}/work" "file://${W}/forgeB.git" dev >/dev/null 2>&1
check "fast-forwarded to new tip" "$(git rev-parse HEAD)" "$(git rev-parse origin/dev)"

echo "Results: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
