#!/usr/bin/env bash
# test-repository-stash.sh — `repository stash` is the surface that makes an
# auto-stash entry findable (#681).
#
# Before this verb a sweep printed "N auto-stash entries still held in <path>"
# and nothing else ever named them: `git stash list`, run by hand against a
# checkout the operator is told not to edit, was the only way to see what N
# meant. One estate carried 12 such entries in the TAPPaaS checkout and 2 in
# Community, the oldest months old.
#
# Asserts, against real local repos and an isolated fixture site.json (no forge,
# no cluster, the live /home/tappaas/config never read):
#   1. list names the entry with its repository, age and files;
#   2. show prints its diff;
#   3. restore puts it back and takes it off the stack;
#   4. discard refuses without --force, and drops with it;
#   5. an entry the operator stashed by hand is invisible to all four.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
REPO_SH="${CICD}/manager/site-manager/repository.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
has() { if [[ "$2" == *"$3"* ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (no '$3' in output)"; fail=$((fail+1)); fi; }
hasnt() { if [[ "$2" != *"$3"* ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 ('$3' should not appear)"; fail=$((fail+1)); fi; }

command -v jq >/dev/null 2>&1 || { echo "jq not found — skipping"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/repository-stash.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

# A checkout with one tagged auto-stash entry and one the operator made by hand.
git -c init.defaultBranch=main init -q "${TMP}/checkout"
(
    cd "${TMP}/checkout"
    git config user.email t@t; git config user.name t
    echo one > file.txt; echo keep > other.txt
    git add . && git commit -qm one
    echo "operator work in progress" > file.txt
    git stash push -q -u -m "tappaas repo-sync auto-stash 20260101-120000"
    echo "a hand-made experiment" > other.txt
    git stash push -q -u -m "wip: my own experiment"
)
AUTO_SHA="$(git -C "${TMP}/checkout" stash list --format='%H %gs' | grep 'repo-sync auto-stash' | cut -d' ' -f1)"
HAND_SHA="$(git -C "${TMP}/checkout" stash list --format='%H %gs' | grep 'my own experiment' | cut -d' ' -f1)"

cat > "${TMP}/site.json" <<JSON
{
  "name": "fixture",
  "repositories": [
    { "name": "TAPPaaS", "url": "codeberg.org/TAPPaaS/TAPPaaS", "branch": "main",
      "path": "${TMP}/checkout", "managed": "full" }
  ]
}
JSON

repo() { CONFIG_DIR="${TMP}" bash "${REPO_SH}" "$@" 2>&1; }

# ── 1. list names what is held ──────────────────────────────────────────────
out="$(repo stash list)"
has "list names the repository"        "${out}" "TAPPaaS"
has "list names the entry by sha"      "${out}" "${AUTO_SHA:0:12}"
has "list gives the entry an age"      "${out}" "stashed "
has "list names the file it holds"     "${out}" "file.txt"
hasnt "the hand-made entry is not listed" "${out}" "${HAND_SHA:0:12}"

# ── 2. show prints the diff ─────────────────────────────────────────────────
out="$(repo stash show TAPPaaS "${AUTO_SHA:0:12}")"
has "show prints the diff"             "${out}" "operator work in progress"
out="$(repo stash show TAPPaaS "${HAND_SHA:0:12}")"
has "show refuses a hand-made entry"   "${out}" "no auto-stash entry"

# ── 3. discard refuses without --force ──────────────────────────────────────
out="$(repo stash discard TAPPaaS "${AUTO_SHA:0:12}")"
has "discard without --force refuses"  "${out}" "Re-run with --force"
ck  "…and the entry is still there" 2 "$(git -C "${TMP}/checkout" stash list | grep -c .)"

# ── 4. restore puts the work back ───────────────────────────────────────────
out="$(repo stash restore TAPPaaS "${AUTO_SHA:0:12}")"
has "restore reports what it restored" "${out}" "Restored ${AUTO_SHA:0:12}"
ck  "the operator's work is in the tree" "operator work in progress" "$(cat "${TMP}/checkout/file.txt")"
ck  "…and the entry is off the stack"    1 "$(git -C "${TMP}/checkout" stash list | grep -c .)"
ck  "nothing is held any more"           0 "$(repo stash list | grep -c "${AUTO_SHA:0:12}" || true)"

# ── 5. discard --force drops one ────────────────────────────────────────────
git -C "${TMP}/checkout" checkout -q -- file.txt
echo "second round" > "${TMP}/checkout/file.txt"
git -C "${TMP}/checkout" stash push -q -u -m "tappaas repo-sync auto-stash 20260102-120000"
SHA2="$(git -C "${TMP}/checkout" stash list --format='%H %gs' | grep 'repo-sync auto-stash' | cut -d' ' -f1)"
out="$(repo stash discard TAPPaaS "${SHA2:0:12}" --force)"
has "discard --force drops it"         "${out}" "Dropped ${SHA2:0:12}"
ck  "…and only the hand-made entry remains" 1 "$(git -C "${TMP}/checkout" stash list | grep -c .)"
ck  "the hand-made entry survived everything" "${HAND_SHA}" \
    "$(git -C "${TMP}/checkout" stash list --format='%H' | head -1)"

# ── 6. an unknown repository or sha is a clear refusal ──────────────────────
out="$(repo stash show nosuchrepo "${HAND_SHA:0:12}")"
has "an unknown repository is refused"  "${out}" "no repository named"
out="$(repo stash list)"
has "an empty list says so"             "${out}" "No auto-stash entries held"

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
