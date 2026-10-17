#!/usr/bin/env bash
# lib/repo-sync.sh — reconcile a managed git checkout to its site.json config.
#
# Shared by the routine update path (scripts/refresh-control-plane.sh) and the operator verb
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
# The marker every auto-stash entry carries. It is what tells an entry this
# code made apart from one the operator made by hand, in both directions: we
# only ever list, restore or drop our own.
REPO_SYNC_STASH_TAG="tappaas repo-sync auto-stash"

# Callers define info()/warn()/error(); we only add fallbacks if they are missing.
command -v info  >/dev/null 2>&1 || info()  { echo "$*"; }
command -v warn  >/dev/null 2>&1 || warn()  { echo "WARN: $*" >&2; }
command -v error >/dev/null 2>&1 || error() { echo "ERROR: $*" >&2; }
declare -F debug >/dev/null 2>&1 || debug() { [[ "${TAPPAAS_DEBUG:-0}" == 1 ]] || return 0; echo "[Debug] $*" >&2; }

# Release verification (ADR-033): which branch is which channel, and whether a
# revision is a signed release. Both live beside this file.
_repo_sync_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=channels-lib.sh
declare -F branch_channel >/dev/null 2>&1 || . "${_repo_sync_dir}/channels-lib.sh"
# shellcheck source=verify-repo.sh
declare -F verify_target >/dev/null 2>&1 || . "${_repo_sync_dir}/verify-repo.sh"

# Where the last verified release of each repository is recorded (run state),
# and whether a repository that signs nothing may still move (site.json
# requireSigned, read by the caller). Both overridable for tests.
REPO_SYNC_TRUST_DIR="${REPO_SYNC_TRUST_DIR:-${TAPPAAS_CONFIG_DIR:-${CONFIG_DIR:-/home/tappaas/config}}/.trust}"
REPO_SYNC_REQUIRE_SIGNED="${REPO_SYNC_REQUIRE_SIGNED:-0}"

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

# repo_sync_verify_gate <path> <branch> <target> <name> <allow_discard>
# ADR-033 D6: may the checkout move to <target>? Decided after the fetch and
# before anything moves. Sets REPO_SYNC_VERIFIED=1 when <target> is a verified
# release, so the caller records it once the checkout is there.
#
#   unstable branch (or no channels.json)    moves; nothing is signed there (D1)
#   no keys in allowed_signers at the base   moves, warned — unless requireSigned (D9)
#   staging/production with keys             only to a release tag signed by a key
#                                            the BASE lists, whose tree hash matches,
#                                            and that does not go backwards
#
# Returns 0 to go ahead, 3 when refused. Not moving at all is never refused:
# what a checkout already runs is the health check's to report, not a reason
# to fail the sweep.
repo_sync_verify_gate() {
    local path="$1" branch="$2" target="$3" name="$4" allow_discard="${5:-0}"
    local channel base head rc=0
    REPO_SYNC_VERIFIED=0
    channel="$(branch_channel "${path}" "${branch}")"
    case "${channel}" in
        staging|production) ;;
        *) debug "  repo-sync: ${name} is on '${branch}' (${channel:-undeclared}) — not verified (unstable)"; return 0 ;;
    esac
    head="$(git -C "${path}" rev-parse -q --verify HEAD 2>/dev/null || true)"
    base="$(verify_base "${path}" "${REPO_SYNC_TRUST_DIR}" "${name}")"
    verify_target "${path}" "${target}" "${base:-${target}}" || rc=$?
    case "${rc}" in
        0)
            if [[ -n "${base}" ]] && ! verify_moves_forward "${path}" "${base}" "${target}"; then
                if [[ "${allow_discard}" == "1" ]]; then
                    warn "  repo-sync: ${name}: ${VERIFY_TAG} does not descend from the last verified release — moving anyway (--force)"
                else
                    error "  repo-sync: ${name}: REFUSED — ${VERIFY_TAG} does not descend from the last verified release $(git -C "${path}" rev-parse --short "${base}")"
                    error "    a signed OLD release is still signed; going back is an operator's decision, not a fetch result"
                    return 3
                fi
            fi
            info "  repo-sync: ${name}: ${VERIFY_TAG} verified — signed by ${VERIFY_SIGNER%% *}"
            REPO_SYNC_VERIFIED=1
            return 0 ;;
        4)
            if [[ "${REPO_SYNC_REQUIRE_SIGNED}" == "1" || "${REPO_SYNC_REQUIRE_SIGNED}" == "true" ]]; then
                [[ "${target}" == "${head}" ]] && return 0
                error "  repo-sync: ${name}: REFUSED — the site requires signed releases (requireSigned) and ${name} signs none (${VERIFY_REASON})"
                return 3
            fi
            debug "  repo-sync: ${name}: unsigned by declaration (${VERIFY_REASON})"
            return 0 ;;
        *)
            [[ "${target}" == "${head}" ]] && return 0
            error "  repo-sync: ${name}: REFUSED — $(git -C "${path}" rev-parse --short "${target}") on '${branch}' (${channel}) is not a verified release"
            error "    ${VERIFY_REASON}"
            error "    the checkout stays on the last verified release; see ADR-033 D6"
            return 3 ;;
    esac
}

# reconcile_repo_checkout <path> <url> <branch> [allow_discard] [name]
# Ensure the checkout at <path> has origin == <url> and is on <branch> at the
# remote's tip. Re-points origin if <url> differs (provider/repo switch),
# stashes local changes for the move and restores them afterwards (#572), creates
# a tracking branch if needed, and converges
# to the remote branch: hard-reset on a remote/branch switch (a managed checkout
# must MIRROR upstream, not merge divergent histories), fast-forward otherwise.
#
# allow_discard=1 permits that hard reset to discard commits that exist only in
# this checkout (they are snapshotted to a repo-sync/pre-reset-* branch first).
# Default 0 — the unattended path (refresh-control-plane.sh) must never make an operator's
# unpushed work unreachable on its own; only `site-manager repository modify
# --force`, run by a person who has seen the warning, may.
#
# On a staging or production branch the move is verified first (ADR-033 D6,
# repo_sync_verify_gate); <name> keys the trust record (default: the directory).
#
# Returns 0 on success, 2 when BLOCKED on that decision, 3 when the target is
# not a verified release, non-zero on a hard failure.
reconcile_repo_checkout() {
    local path="$1" url="$2" branch="$3" allow_discard="${4:-0}" name="${5:-}"
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
    # Release tags, without --prune: that would also delete tags made here. A tag
    # that moved upstream is refused by git ("would clobber"); the local one
    # stands and verification decides on it.
    git -C "${path}" fetch origin --tags --quiet 2>/dev/null \
        || warn "  repo-sync: could not fetch all tags from ${desired} (a tag moved upstream?) — verifying with the local ones"

    # What the checkout will move to, fixed now: everything below converges on
    # this commit, so what was verified is what lands (a second fetch could
    # bring a newer, unverified tip).
    local target
    target="$(git -C "${path}" rev-parse -q --verify "refs/remotes/origin/${branch}^{commit}" 2>/dev/null || true)"
    [ -n "${target}" ] || { warn "  repo-sync: origin has no branch '${branch}'"; return 1; }
    [ -n "${name}" ] || name="$(basename "${path}")"
    local vrc=0
    repo_sync_verify_gate "${path}" "${branch}" "${target}" "${name}" "${allow_discard}" || vrc=$?
    [ "${vrc}" = "0" ] || return "${vrc}"

    # Auto-stash local changes so checkout/reset cannot be blocked. The entry is
    # transient: repo_sync_restore_stash puts it back below, whatever the sync
    # did (#572). Only an entry that no longer applies is left behind, and then
    # it is said out loud.
    local stashed=""
    if [ -n "$(git -C "${path}" status --porcelain 2>/dev/null)" ]; then
        if git -C "${path}" stash push -u -m "${REPO_SYNC_STASH_TAG} $(date +%Y%m%d-%H%M%S)" >/dev/null; then
            stashed="$(git -C "${path}" rev-parse --verify --quiet 'stash@{0}' 2>/dev/null || true)"
            warn "  repo-sync: local changes stashed for the sync — restored afterwards"
        else
            warn "  repo-sync: stash failed — checkout may not switch"
        fi
    fi

    local rc=0
    # Ensure the target branch exists locally and tracks the (possibly new) origin.
    if git -C "${path}" show-ref --verify --quiet "refs/heads/${branch}"; then
        git -C "${path}" checkout "${branch}" || { warn "  repo-sync: checkout ${branch} failed"; rc=1; }
    else
        git -C "${path}" checkout -B "${branch}" "${target}" \
            || { warn "  repo-sync: checkout --track ${branch} failed"; rc=1; }
    fi

    # Converge to the remote branch.
    if [ "${rc}" = "0" ]; then
        if [ "${remote_changed}" = "1" ]; then
            git -C "${path}" reset --hard "${target}" || { warn "  repo-sync: reset to origin/${branch} failed"; rc=1; }
        else
            git -C "${path}" merge --ff-only -q "${target}" || { warn "  repo-sync: fast-forward to origin/${branch} failed"; rc=1; }
        fi
    fi

    # Before any early return: the operator's uncommitted work goes back into the
    # tree whether the sync succeeded or failed.
    repo_sync_restore_stash "${path}" "${stashed}"

    [ "${rc}" = "0" ] || return "${rc}"

    git -C "${path}" branch --set-upstream-to="origin/${branch}" "${branch}" >/dev/null 2>&1 || true
    if [ "${REPO_SYNC_VERIFIED:-0}" = "1" ]; then
        verify_state_record "${REPO_SYNC_TRUST_DIR}" "${name}" "${target}" \
            || warn "  repo-sync: ${name}: verified, but could not record it in ${REPO_SYNC_TRUST_DIR}"
    fi
    return 0
}

# repo_sync_restore_stash <path> [stash-sha]
# Put a sync's auto-stash back (#572). The stash was a means of getting the
# checkout to move, not a place to keep the operator's work: an entry that still
# applies is restored and dropped, so the tree after a sweep looks the way the
# operator left it plus whatever upstream brought.
#
# It is re-applied only when it applies cleanly — checked with `apply --check`
# first, because a failing `stash pop` writes conflict markers into a managed
# checkout and the next sweep would then refuse it. An entry that does not apply
# stays, and is named with the command that recovers it.
#
# Always reports how many auto-stash entries the checkout still carries: 19 of
# them accumulated unmentioned on one site, which is the failure this fixes.
# repo_sync_stash_applies <path> <stash-sha>
# True when the entry's diff applies to the tree as it now stands. --include-untracked
# needs git >= 2.32; where it is not understood the tracked part is checked alone,
# and `stash pop` still refuses on its own if an untracked file is in the way.
repo_sync_stash_applies() {
    local path="$1" sha="$2" diff=""
    diff="$(git -C "${path}" stash show -p --include-untracked "${sha}" 2>/dev/null)" \
        || diff="$(git -C "${path}" stash show -p "${sha}" 2>/dev/null)" \
        || return 1
    # An empty diff is nothing to conflict with: let the pop run.
    [ -n "${diff}" ] || return 0
    printf '%s\n' "${diff}" | git -C "${path}" apply --check - 2>/dev/null
}

# repo_sync_stash_entries <path>
# One line per auto-stash entry this code made, oldest LAST (git's own order):
#   <sha>\001<stash@{n}>\001<relative age>\001<yyyy-mm-dd>\001<subject>
# Entries the operator stashed by hand carry no tag and are never listed: the
# verb built on this must not offer to drop someone else's work (#681).
repo_sync_stash_entries() {
    local path="$1"
    [ -d "${path}/.git" ] || [ -f "${path}/.git" ] || return 0
    git -C "${path}" stash list --format='%H%x01%gd%x01%cr%x01%cs%x01%gs' 2>/dev/null \
        | grep -F "${REPO_SYNC_STASH_TAG}" || true
}

# repo_sync_stash_ref <path> <sha>
# The stash@{n} that names <sha> right now. Indices shift as entries are
# dropped, so everything downstream addresses an entry by sha and resolves it
# here, at the moment it acts.
repo_sync_stash_ref() {
    local path="$1" want="$2" sha ref
    while IFS=$'\001' read -r sha ref _; do
        [ -n "${sha}" ] || continue
        case "${sha}" in "${want}"*) printf '%s' "${ref}"; return 0 ;; esac
    done < <(repo_sync_stash_entries "${path}")
    return 1
}

repo_sync_restore_stash() {
    local path="$1" sha="${2:-}" n=""
    if [ -n "${sha}" ]; then
        local top
        top="$(git -C "${path}" rev-parse --verify --quiet 'stash@{0}' 2>/dev/null || true)"
        if [ "${top}" != "${sha}" ]; then
            warn "  repo-sync: the auto-stash is no longer on top of the stash list — left in place"
        elif repo_sync_stash_applies "${path}" "${sha}"; then
            if git -C "${path}" stash pop >/dev/null 2>&1; then
                info "  repo-sync: local changes restored"
            else
                warn "  repo-sync: restoring the auto-stash failed — kept (git -C ${path} stash list)"
            fi
        else
            warn "  repo-sync: local changes no longer apply on top of the new tip — KEPT as a stash entry"
            warn "    inspect and recover with: site-manager repository stash list"
        fi
    fi
    # What is held is named, not just counted: a bare number is what let 19
    # entries sit unread for three months (#681). The oldest one's age is the
    # part that says whether this is today's sync or a years-old backlog.
    local entries oldest
    entries="$(repo_sync_stash_entries "${path}")"
    n="$(printf '%s' "${entries}" | grep -c . || true)"
    if [ -n "${n}" ] && [ "${n}" -gt 0 ] 2>/dev/null; then
        local word="entries"; [ "${n}" = "1" ] && word="entry"
        oldest="$(printf '%s\n' "${entries}" | tail -1 | cut -d$'\001' -f3)"
        warn "  repo-sync: ${n} auto-stash ${word} still held in ${path} (oldest ${oldest:-unknown})"
        warn "    list, inspect, restore or discard them with: site-manager repository stash list"
    fi
}
