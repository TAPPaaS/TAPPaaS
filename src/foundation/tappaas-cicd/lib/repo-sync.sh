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
# Callers define info()/warn()/error(); we only add fallbacks if they are missing.
command -v info  >/dev/null 2>&1 || info()  { echo "$*"; }
command -v warn  >/dev/null 2>&1 || warn()  { echo "WARN: $*" >&2; }
command -v error >/dev/null 2>&1 || error() { echo "ERROR: $*" >&2; }

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

# Scheme/user/.git/trailing-slash-insensitive form, for comparing two remote URLs
# without spuriously re-pointing. Also folds the scp-style spelling, so
# git@host:org/repo.git, ssh://git@host/org/repo and https://host/org/repo all
# canonicalize to host/org/repo (#433: an scp-style origin differed from the
# declared https URL by the ':' alone, read as a forge change, and took the
# hard-reset path below on an unattended run).
repo_sync_canon() {
    local u="${1:-}" auth after
    u="${u%.git}"
    u="${u#https://}"; u="${u#http://}"; u="${u#ssh://}"; u="${u#git+ssh://}"; u="${u#file://}"
    # Any user@ in the authority (git@host, tappaas@host) is not part of identity.
    auth="${u%%/*}"
    case "${auth}" in *@*) u="${u#*@}"; auth="${u%%/*}" ;; esac
    # scp-style host:path — the ':' is a path separator. A numeric :port is not.
    case "${auth}" in
        *:*)
            after="${auth#*:}"
            case "${after}" in
                ''|*[!0-9]*) u="${u%%:*}/${u#*:}" ;;
            esac
            ;;
    esac
    printf '%s' "${u%/}"
}

# Fetch <branch> from <url> into <path>'s object store WITHOUT touching its
# remotes, and print the fetched tip. Lets us decide whether converging on a new
# origin would destroy work BEFORE any state is mutated.
repo_sync_probe_tip() {
    local path="$1" url="$2" branch="$3"
    git -C "${path}" fetch --quiet "${url}" "refs/heads/${branch}" >/dev/null 2>&1 || return 1
    git -C "${path}" rev-parse --verify --quiet FETCH_HEAD
}

# repo_sync_at_risk_commits <path> <branch> [<new-tip>]
# Commits on <branch> that exist NOWHERE else: not reachable from any
# remote-tracking ref, nor from <new-tip> (the incoming origin's branch). Empty
# output means a reset can lose nothing.
#
# Excluding remote-tracking refs is what keeps a genuine forge migration
# automatic: in the github->codeberg case the local commits are all on the OLD
# origin/<branch>, so they are recoverable and not "at risk". Only work that was
# committed here and pushed nowhere trips the guard.
repo_sync_at_risk_commits() {
    local path="$1" branch="$2" new_tip="${3:-}"
    git -C "${path}" show-ref --verify --quiet "refs/heads/${branch}" || return 0
    # Every command here stays set -e-safe: this file is sourced into scripts
    # running `set -euo pipefail`, where a bare failing test would abort the run.
    local excl=(--not --remotes)
    if [ -n "${new_tip}" ]; then excl+=("${new_tip}"); fi
    git -C "${path}" rev-list "refs/heads/${branch}" "${excl[@]}" 2>/dev/null || true
}

# reconcile_repo_checkout <path> <url> <branch> [allow_discard]
# Ensure the checkout at <path> has origin == <url> and is on <branch> at the
# remote's tip. Re-points origin if <url> differs (provider/repo switch),
# auto-stashes local changes, creates a tracking branch if needed, and converges
# to the remote branch: hard-reset on a remote/branch switch (a managed checkout
# must MIRROR upstream, not merge divergent histories), fast-forward otherwise.
#
# allow_discard=1 permits that hard reset to discard commits that exist only in
# this checkout (they are snapshotted to a repo-sync/pre-reset-* branch first).
# Default 0 — the unattended path (pre-update.sh) must never make an operator's
# unpushed work unreachable on its own; only `site-manager repository modify
# --force`, run by a person who has seen the warning, may.
#
# Returns 0 on success, 2 when BLOCKED on that decision, non-zero on a hard failure.
reconcile_repo_checkout() {
    local path="$1" url="$2" branch="$3" allow_discard="${4:-0}"
    [ -d "${path}/.git" ] || { warn "  repo-sync: not a git checkout: ${path}"; return 1; }

    local desired cur remote_changed=0 on_branch
    desired="$(repo_sync_clone_url "${url}")"
    cur="$(git -C "${path}" remote get-url origin 2>/dev/null || true)"

    # site.json is the declaration; a checkout parked on another branch is a
    # config inconsistency. Say so — it is about to be corrected silently.
    on_branch="$(git -C "${path}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ -n "${on_branch}" ] && [ "${on_branch}" != "${branch}" ]; then
        warn "  repo-sync: ${path} is on '${on_branch}' but site.json declares '${branch}' — switching"
    fi

    if [ "$(repo_sync_canon "${desired}")" != "$(repo_sync_canon "${cur}")" ]; then
        # A real origin change. Converging means `reset --hard`, so decide BEFORE
        # mutating anything: re-point and reset are ONE step. A refusal therefore
        # leaves the checkout exactly as it was and every later run re-reports it
        # — where re-pointing first used to make the mismatch self-heal, reducing
        # the whole event to a single easily-missed warn line (#433).
        local new_tip at_risk count rescue
        new_tip="$(repo_sync_probe_tip "${path}" "${desired}" "${branch}")" || {
            warn "  repo-sync: cannot reach ${desired} (${branch}) — leaving origin at ${cur:-<none>}"
            return 1
        }
        at_risk="$(repo_sync_at_risk_commits "${path}" "${branch}" "${new_tip}")"

        if [ -n "${at_risk}" ] && [ "${allow_discard}" != "1" ]; then
            count="$(printf '%s\n' "${at_risk}" | grep -c . || true)"
            error "  repo-sync: REFUSING origin change ${cur:-<none>} -> ${desired}"
            error "    ${count} commit(s) on '${branch}' exist only in ${path} and a reset would orphan them:"
            git -C "${path}" log --oneline --no-decorate -n 5 "refs/heads/${branch}" --not --remotes "${new_tip}" 2>/dev/null \
                | while IFS= read -r _c; do error "      ${_c}"; done || true
            error "    Push them, or re-run with --force (site-manager repository modify <name> --url ${url} --force),"
            error "    which snapshots them to a repo-sync/pre-reset-* branch first."
            return 2
        fi

        if [ -n "${at_risk}" ]; then
            # --force path: keep the old tip reachable from a real ref. Unlike the
            # reflog it never expires, and unlike a stash it can be cherry-picked.
            rescue="repo-sync/pre-reset-${branch//\//-}-$(date +%Y%m%d-%H%M%S)"
            if git -C "${path}" branch "${rescue}" "refs/heads/${branch}" 2>/dev/null; then
                warn "  repo-sync: local-only commits preserved on '${rescue}' (git -C ${path} log ${rescue})"
            else
                error "  repo-sync: could not create rescue branch '${rescue}' — refusing to reset"
                return 2
            fi
        fi

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
