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
# And the #433 guard:
#   - protocol spelling (scp-style git@host:org/repo) is NOT a forge change;
#   - a real forge change is REFUSED (rc 2, nothing mutated) when the branch
#     carries commits that exist only in the checkout;
#   - allow_discard=1 proceeds but snapshots them to repo-sync/pre-reset-*;
#   - a forge change whose commits ARE on the old remote still applies
#     automatically (the github->codeberg migration must not need --force).
#
# Usage: test-repo-sync.sh   (prints "Results: N passed, M failed"; exit 1 on fail)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info(){ :; }; warn(){ :; }; error(){ :; }  # silence the lib's progress in tests
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

# 4. Canonicalisation: protocol spelling is not identity (#433). The live bug was
#    an scp-style origin reading as a forge change against a declared https URL.
check "scp == https"      "$(repo_sync_canon 'git@codeberg.org:TAPPaaS/TAPPaaS.git')" "$(repo_sync_canon 'https://codeberg.org/TAPPaaS/TAPPaaS')"
check "ssh:// == https"   "$(repo_sync_canon 'ssh://git@codeberg.org/TAPPaaS/TAPPaaS.git')" "$(repo_sync_canon 'codeberg.org/TAPPaaS/TAPPaaS')"
check "user@ stripped"    "$(repo_sync_canon 'ssh://tappaas@host/o/r')" "host/o/r"
check ":port preserved"   "$(repo_sync_canon 'ssh://git@host:2222/o/r.git')" "host:2222/o/r"
check "different repo"    "$(repo_sync_canon 'git@host:o/other')" "host/o/other"

# forgeC: another forge that also carries 'dev' — a genuine origin change target.
git clone -q --bare "${W}/forgeB.git" "${W}/forgeC.git"

# 5. A real forge change must NOT orphan commits that live only here.
( cd "${W}/work" && git commit -q --allow-empty -m local-only )
only_sha="$(git rev-parse HEAD)"
origin_before="$(git remote get-url origin)"
reconcile_repo_checkout "${W}/work" "file://${W}/forgeC.git" dev >/dev/null 2>&1
check "blocked with rc 2"     "$?" "2"
check "origin left untouched" "$(git remote get-url origin)" "${origin_before}"
check "HEAD left untouched"   "$(git rev-parse HEAD)" "${only_sha}"

# 6. Same change with allow_discard=1: resets, but the old tip stays reachable.
reconcile_repo_checkout "${W}/work" "file://${W}/forgeC.git" dev 1 >/dev/null 2>&1
check "forced change applied" "$(git rev-parse HEAD)" "$(git rev-parse origin/dev)"
rescue="$(git branch --list 'repo-sync/pre-reset-dev-*' --format='%(refname:short)' | head -1)"
[ -n "${rescue}" ] && ok || no "rescue branch created"
check "local-only commit preserved" "$(git rev-parse "${rescue:-HEAD}")" "${only_sha}"

# 7. A forge change whose commits are all on the OLD remote needs no --force:
#    that is the github->codeberg migration, and it must stay automatic.
if reconcile_repo_checkout "${W}/work" "file://${W}/forgeB.git" dev >/dev/null 2>&1; then ok; else no "clean forge migration still automatic"; fi
case "$(git remote get-url origin)" in *forgeB.git) ok ;; *) no "migrated back to forgeB ($(git remote get-url origin))" ;; esac

# 8. The guard must be set -e-safe: pre-update.sh runs `set -euo pipefail`, where a
#    bare failing command inside the refusal path would abort the whole update run
#    instead of skipping one repository. rc 2 proves it reached its own `return 2`.
( cd "${W}/work" && git commit -q --allow-empty -m local-only-2 )
origin_before="$(git remote get-url origin)"
rc8=0
( set -euo pipefail; reconcile_repo_checkout "${W}/work" "file://${W}/forgeC.git" dev >/dev/null 2>&1 ) || rc8=$?
check "set -e safe, still rc 2"    "${rc8}" "2"
check "set -e safe, origin intact" "$(git remote get-url origin)" "${origin_before}"

echo "Results: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
