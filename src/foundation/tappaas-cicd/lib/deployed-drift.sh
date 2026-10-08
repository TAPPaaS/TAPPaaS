#!/usr/bin/env bash
#
# deployed-drift.sh — is what runs on this mothership what its checkout declares?
# (ADR-028 D12, #746)
#
# D12 forbids patching a running site in place and stopping there: the deployed
# code then sits ahead of the declared code, nothing reports it, and the next
# control-plane refresh reverts it silently. This makes that state visible.
#
# Most of ~/bin is symlinks into the checkout, so an in-place patch of those is a
# change to the checkout itself — uncommitted, or committed locally and never on
# the channel. The few plain files in ~/bin are copies, and a copy can be edited
# where it lies; it is compared with its source in the checkout by name.
#
# deployed_drift <checkout> <bin dir> [<branch>]
#   prints one line per finding, nothing when what runs is what is declared.
#   rc 0 always: a report, never a gate.
#
# Sourced by tappaas-train.sh (status) and tappaas-selfcheck.sh (a warning).
deployed_drift() {
    local repo="$1" bin="$2" branch="${3:-}" n first f src srcs
    local -a git=(git -c "safe.directory=${repo}" -C "${repo}")
    if "${git[@]}" rev-parse --git-dir >/dev/null 2>&1; then
        n="$("${git[@]}" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')"
        if (( n > 0 )); then
            first="$("${git[@]}" status --porcelain --untracked-files=no 2>/dev/null | head -1 | cut -c4-)"
            echo "the checkout ${repo} has uncommitted changes in ${n} file(s) (${first}…) — commit them on a branch and land them, or they are lost at the next pull"
        fi
        if [[ -n "${branch}" ]] && "${git[@]}" rev-parse --verify --quiet "origin/${branch}" >/dev/null; then
            n="$("${git[@]}" rev-list --count "origin/${branch}..HEAD" 2>/dev/null || echo 0)"
            (( n > 0 )) && echo "the checkout ${repo} carries ${n} commit(s) that are not on ${branch} — what runs is ahead of the channel"
        fi
    fi
    [[ -d "${bin}" ]] || return 0
    for f in "${bin}"/*; do
        [[ -f "${f}" && ! -L "${f}" ]] || continue
        srcs="$(find "${repo}/src" -name "${f##*/}" -type f -not -path '*/node_modules/*' 2>/dev/null)"
        if [[ -z "${srcs}" ]]; then
            echo "${f} is a plain file with no source in the checkout — its origin is unknown"
            continue
        fi
        while IFS= read -r src; do cmp -s "${f}" "${src}" && continue 2; done <<<"${srcs}"
        echo "${f} differs from ${srcs%%$'\n'*} — patched in place? (ADR-028 D12)"
    done
    return 0
}
