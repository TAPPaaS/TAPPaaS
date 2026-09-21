#!/usr/bin/env bash
# test-repo-sync-stash.sh — the auto-stash is transient (#572).
#
# reconcile_repo_checkout stashes a dirty checkout so it can move. Before this
# guard nothing ever put the entry back: one site had 19 of them, the oldest
# three months old, and an operator whose work was in entry 7 had no way to know.
#
# Asserts, against real local repos (no forge, no cluster):
#   1. uncommitted work is back in the tree after a successful sync, with no
#      stash entry left behind;
#   2. a change that no longer applies is KEPT and reported, not silently lost;
#   3. entries that accumulated earlier are counted out loud, with the age of
#      the oldest and the verb that resolves them (#681);
#   4. the restore also runs when the sync itself fails;
#   5. repo_sync_stash_entries lists OUR entries only — an entry the operator
#      stashed by hand is not ours to offer for restore or discard (#681).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
# shellcheck source=../../lib/repo-sync.sh
. "${CICD}/lib/repo-sync.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/repo-sync-stash.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

# A bare origin with two commits on main, and a checkout one commit behind.
git init -q --bare "${TMP}/origin.git"
git -c init.defaultBranch=main clone -q "${TMP}/origin.git" "${TMP}/work" 2>/dev/null
(
    cd "${TMP}/work"
    git config user.email t@t; git config user.name t
    echo one > file.txt; echo keep > other.txt
    git add . && git commit -qm one && git branch -M main && git push -q origin main
)
# The bare repo's HEAD follows whatever init.defaultBranch was: point it at the
# branch we actually pushed, or every clone below checks out nothing.
git -C "${TMP}/origin.git" symbolic-ref HEAD refs/heads/main
fresh_checkout() {
    rm -rf "${TMP}/checkout"
    git clone -q "${TMP}/origin.git" "${TMP}/checkout" 2>/dev/null
    git -C "${TMP}/checkout" config user.email t@t
    git -C "${TMP}/checkout" config user.name t
}
advance_origin() {
    (cd "${TMP}/work" && echo "$1" > file.txt && git commit -qam "$1" && git push -q origin main)
}
sync_it() { reconcile_repo_checkout "${TMP}/checkout" "${TMP}/origin.git" main 0 2>&1; }
stash_count() { git -C "${TMP}/checkout" stash list | grep -c 'repo-sync auto-stash' || true; }

# ── 1. work on a file the update does not touch comes back ──────────────────
fresh_checkout
advance_origin two
echo "operator edit" > "${TMP}/checkout/other.txt"
out="$(sync_it)"; rc=$?
ck "the sync succeeded"                   0 "${rc}"
ck "the operator's edit is back"          "operator edit" "$(cat "${TMP}/checkout/other.txt")"
ck "the update arrived"                   two             "$(cat "${TMP}/checkout/file.txt")"
ck "no auto-stash entry is left"          0 "$(stash_count)"
[[ "${out}" == *"restored"* ]] && ck "the restore is reported" ok ok || ck "the restore is reported" ok missing

# ── 2. an untracked file is restored too (stash push -u) ────────────────────
fresh_checkout
advance_origin three
echo scratch > "${TMP}/checkout/untracked.txt"
sync_it >/dev/null
ck "an untracked file survives the sync" scratch "$(cat "${TMP}/checkout/untracked.txt" 2>/dev/null)"
ck "and leaves no entry"                 0 "$(stash_count)"

# ── 3. a change that no longer applies is kept, loudly ──────────────────────
# The operator edits the same line the incoming commit rewrites.
fresh_checkout
echo "local rewrite" > "${TMP}/checkout/file.txt"
advance_origin four
out="$(sync_it)"
ck "a conflicting change is kept as a stash entry" 1 "$(stash_count)"
[[ "${out}" == *"KEPT"* && "${out}" == *"repository stash list"* ]] \
    && ck "…and the sanctioned recovery verb is printed" ok ok \
    || ck "…and the sanctioned recovery verb is printed" ok missing
[[ "${out}" == *"1 auto-stash entry"* ]] \
    && ck "the remaining entry is counted" ok ok \
    || ck "the remaining entry is counted" ok missing

# ── 4. entries that accumulated before are counted, even on a clean sync ────
# (the 19-entry site: nothing is dirty now, but the backlog must still show)
advance_origin five
out="$(sync_it)"
[[ "${out}" == *"auto-stash entry"* ]] \
    && ck "an old entry is reported on a later sweep too" ok ok \
    || ck "an old entry is reported on a later sweep too" ok missing
# A bare count is what let 19 entries sit unread: the age of the oldest and the
# verb that resolves them are part of the same line (#681).
[[ "${out}" == *"oldest "* ]] \
    && ck "the oldest entry's age is named" ok ok \
    || ck "the oldest entry's age is named" ok missing
[[ "${out}" == *"site-manager repository stash list"* ]] \
    && ck "the verb that resolves them is named" ok ok \
    || ck "the verb that resolves them is named" ok missing

# ── 4b. the entries are addressable, one line each ─────────────────────────
entries="$(repo_sync_stash_entries "${TMP}/checkout")"
ck "one line per held entry" 1 "$(printf '%s\n' "${entries}" | grep -c .)"
e_sha="$(printf '%s' "${entries}" | cut -d"$(printf '\001')" -f1)"
e_ref="$(printf '%s' "${entries}" | cut -d"$(printf '\001')" -f2)"
e_age="$(printf '%s' "${entries}" | cut -d"$(printf '\001')" -f3)"
ck "it carries a sha"        40 "${#e_sha}"
ck "it carries a stash ref"  "stash@{0}" "${e_ref}"
[[ -n "${e_age}" ]] && ck "it carries an age" ok ok || ck "it carries an age" ok missing
# A sha prefix resolves to the ref, as with git — that is what the verb addresses
# entries by, because indices shift as entries are dropped.
ck "a sha prefix resolves to its ref" "stash@{0}" "$(repo_sync_stash_ref "${TMP}/checkout" "${e_sha:0:12}")"
if repo_sync_stash_ref "${TMP}/checkout" deadbeef >/dev/null 2>&1; then
    ck "an unknown sha does not resolve" ok resolved
else
    ck "an unknown sha does not resolve" ok ok
fi

# ── 4c. an entry the operator stashed by hand is not ours ─────────────────
echo "hand edit" >> "${TMP}/checkout/other.txt"
git -C "${TMP}/checkout" stash push -q -m "operator: half-finished experiment"
ck "a hand-made entry is not listed" 1 "$(repo_sync_stash_entries "${TMP}/checkout" | grep -c .)"
ck "…and it is still on the stack"   2 "$(git -C "${TMP}/checkout" stash list | grep -c .)"
git -C "${TMP}/checkout" stash drop -q 'stash@{0}'

# ── 5. the restore runs even when the sync fails ────────────────────────────
# An unreachable origin: the fetch fails before the stash, so nothing is stashed;
# make the pull fail instead by pointing the branch at one that cannot ff.
fresh_checkout
echo "work in progress" > "${TMP}/checkout/other.txt"
git -C "${TMP}/checkout" commit -qam "local divergence"
advance_origin six
echo "uncommitted too" >> "${TMP}/checkout/other.txt"
sync_it >/dev/null
ck "a failed sync still restores the tree" "work in progress
uncommitted too" "$(cat "${TMP}/checkout/other.txt")"

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
