#!/usr/bin/env bash
# lib/repo-sync.sh — reconcile a managed git checkout to its site.json config.
#
# Shared by the routine update path (pre-update.sh) and the operator verb
# (site-manager repository modify) so BOTH apply a site.json repository change
# — including a change of forge/provider (github.com -> codeberg.org) and/or
# branch — the same, correct way.
#
# The bug this fixes: the old pull path only ran `git checkout <branch>` +
# `git pull` against the EXISTING `origin`. When site.json's `url` changed to a
# different forge, `origin` still pointed at the old one, so `main` resolved to
# the old forge's (stale) `main` — silently pulling the wrong tree. (Hit live
# during the Codeberg migration: a 2.0 checkout reverted to GitHub's 1.x `main`.)
#
# Callers define info()/warn(); we only add fallbacks if they are missing.
command -v info >/dev/null 2>&1 || info() { echo "$*"; }
command -v warn >/dev/null 2>&1 || warn() { echo "WARN: $*" >&2; }

# Build the canonical https clone URL from a site.json `url` (which is stored
# bare, e.g. "codeberg.org/TAPPaaS/TAPPaaS"). An explicit scheme is preserved.
repo_sync_clone_url() {
    local url="$1"
    case "${url}" in
        https://*|http://*|ssh://*|file://*|git@*) : ;;
        *) url="https://${url}" ;;
    esac
    case "${url}" in *.git) : ;; *) url="${url}.git" ;; esac
    printf '%s' "${url}"
}

# Scheme/.git/trailing-slash-insensitive form, for comparing two remote URLs
# without spuriously re-pointing (https vs bare, with/without .git).
repo_sync_canon() {
    local u="${1:-}"
    u="${u%.git}"; u="${u#https://}"; u="${u#http://}"; u="${u#ssh://}"; u="${u#git@}"
    printf '%s' "${u%/}"
}

# reconcile_repo_checkout <path> <url> <branch>
# Ensure the checkout at <path> has origin == <url> and is on <branch> at the
# remote's tip. Re-points origin if <url> differs (provider/repo switch),
# auto-stashes local changes, creates a tracking branch if needed, and converges
# to the remote branch: hard-reset on a remote/branch switch (a managed checkout
# must MIRROR upstream, not merge divergent histories), fast-forward otherwise.
# Returns 0 on success, non-zero on a hard failure.
reconcile_repo_checkout() {
    local path="$1" url="$2" branch="$3"
    [ -d "${path}/.git" ] || { warn "  repo-sync: not a git checkout: ${path}"; return 1; }

    local desired cur remote_changed=0
    desired="$(repo_sync_clone_url "${url}")"
    cur="$(git -C "${path}" remote get-url origin 2>/dev/null || true)"

    if [ "$(repo_sync_canon "${desired}")" != "$(repo_sync_canon "${cur}")" ]; then
        warn "  repo-sync: origin changed ${cur:-<none>} -> ${desired} (re-pointing)"
        if [ -n "${cur}" ]; then
            git -C "${path}" remote set-url origin "${desired}" || { warn "  repo-sync: set-url failed"; return 1; }
        else
            git -C "${path}" remote add origin "${desired}" || { warn "  repo-sync: remote add failed"; return 1; }
        fi
        remote_changed=1
    fi

    git -C "${path}" fetch origin --prune || { warn "  repo-sync: fetch failed (${desired})"; return 1; }

    # Auto-stash local changes so checkout/reset cannot be blocked. Preserved and
    # recoverable via 'git -C <path> stash list'.
    if [ -n "$(git -C "${path}" status --porcelain 2>/dev/null)" ]; then
        warn "  repo-sync: local changes present — auto-stashing (recover via 'git -C ${path} stash list')"
        git -C "${path}" stash push -u -m "tappaas repo-sync auto-stash $(date +%Y%m%d-%H%M%S)" \
            || warn "  repo-sync: stash failed — checkout may not switch"
    fi

    # Ensure the target branch exists locally and tracks the (possibly new) origin.
    if git -C "${path}" show-ref --verify --quiet "refs/heads/${branch}"; then
        git -C "${path}" checkout "${branch}" || { warn "  repo-sync: checkout ${branch} failed"; return 1; }
    else
        git -C "${path}" checkout -B "${branch}" --track "origin/${branch}" \
            || { warn "  repo-sync: checkout --track ${branch} failed"; return 1; }
    fi

    # Converge to the remote branch.
    if [ "${remote_changed}" = "1" ]; then
        git -C "${path}" reset --hard "origin/${branch}" || { warn "  repo-sync: reset to origin/${branch} failed"; return 1; }
    else
        git -C "${path}" pull --ff-only origin "${branch}" || { warn "  repo-sync: pull (ff-only) failed for ${branch}"; return 1; }
    fi

    git -C "${path}" branch --set-upstream-to="origin/${branch}" "${branch}" >/dev/null 2>&1 || true
    return 0
}
