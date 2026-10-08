#!/usr/bin/env bash
#
# tappaas-train.sh — the release train (ADR-028 D9).
#
# Three channels on two-week boundaries: what a site RUNS is its channel
# (unstable | staging | production); where the code SITS is a branch
# (main | staging | stable). Promotion is fast-forward only, in one direction.
#
# The PIN is the single nixpkgs revision every TAPPaaS NixOS system is built
# from — one lock, templates/flake.lock, so moving it moves the whole estate.
# The SOAK is the fortnight a revision must spend running on the staging site
# before it may be promoted to production: evidence it survives real use.
#
#   tappaas-train status [--no-fetch]      where each channel points, and what blocks a boundary
#   tappaas-train init                     verify the train is promotable; start the soak clock
#   tappaas-train boundary [--dry-run]     the boundary: promote staging→stable, main→staging
#                 [--resume] [--force-boundary]
#                 [--staging-host <host>]      verify the promotion on the staging site (phase 6)
#                 [--production-branch <b>]    promote onto <b> instead of `stable`
#                 [--staging-branch <b>]       use <b> as the staging channel — set both to
#                                              throwaway refs to rehearse a whole boundary
#                 [--guest <module>]           the guest that meets the new pin first
#                 [--to <nixos-XX.YY>]         a VERSION move: change the release branch itself
#                 [--allow-no-pin-change]      prove the pin already in the tree, without moving it
#                 [--major]                    cut the next MAJOR (3.0) instead of the next minor
#   tappaas-train fault <what>             record a staging fault; blocks the next promotion
#   tappaas-train fault --resolved <commit>  clear it — the commit must be on main
#   tappaas-train patch <staging|production> <commit> --why "<what>" [--dry-run]
#                                          an urgent fix (ADR-028 D12): fast-forward the channel
#                                          onto <commit>, tag it MAJOR.MINOR.N, record why
#   tappaas-train preview [--to <nixos-XX.YY>] [--since <vX.Y>] [--details-file <f>]
#                                          the last release (default: the newest tag) against
#                                          "if released now" (#788): per module, critical/high now
#                                          and fixed/new/unchanged since; majors. NixOS modules
#                                          evaluated, images scanned by reference — nothing built,
#                                          nothing moved; writes config/train-preview.json and the
#                                          per-module details (config/train-preview-details.json)
#                 [--no-pin-move]          "now" keeps the pin in the tree: what it ships today
#   tappaas-train preview --module <name> [--details-file <f>]
#                                          one module from the last preview, CVE by CVE: what is
#                                          NEW, FIXED and SAME, the image and packages that change
#   tappaas-train ack [--note "<why>"]     accept what the last preview reported; the next
#                                          boundary goes ahead if it finds nothing beyond it
#   tappaas-train releases                 every version, its commit, when it reached each channel
#   tappaas-train releases --render        re-render RELEASES.md from release/releases.json (after a hand edit)
#
# Versions (ADR-028 D13): each boundary cuts the next MAJOR.MINOR into staging
# as an annotated tag, and the same number reaches production one boundary
# later. The history is committed to main: release/releases.json and RELEASES.md.
#
# Release CVE preview (#788): the last release against "if released now", per module,
# found by evaluating in minutes. `preview` shows it, `ack` accepts its majors and new
# critical/high CVEs, and a boundary checks the pin it moves to right away — before
# its deep test — and stops on anything not accepted. Nothing to accept: no ack needed.
#
# One boundary is one command: move the pin, prove it here, land it on main,
# then promote. Its preflight also holds every module to the blueprint
# (ADR-027 D5) and scans for secrets (#378): a missing MUST or a finding refuses
# the boundary, and both results are recorded. Phases 1-2 take hours (a sweep that reboots nodes, then a deep
# test), so a run that stops half way is picked up with --resume rather than
# restarted. Nothing is promoted unless the deep test passed — a promotion is
# never the consolation prize for a failed test.
# Operator reference: ../RELEASE-TRAIN.md · design: docs/design/release-train-promotion.md
#
# NOT `site-manager repository release` — that verb means "release a pull HOLD"
# (#653). Two unrelated operations must not share a name in the one place an
# operator reaches under time pressure.
#
# Exit: 0 sound (or reported) · 1 the train is not promotable · 2 usage
#
# Environment (tests): TAPPAAS_CONFIG_DIR, TAPPAAS_REPO_DIR, TAPPAAS_BIN_DIR, TAPPAAS_TRAIN_NOW

set -uo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
CONFIG_DIR="${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}"
REPO_DIR="${TAPPAAS_REPO_DIR:-/home/tappaas/TAPPaaS}"
BIN_DIR="${TAPPAAS_BIN_DIR:-/home/tappaas/bin}"

# Which branch realizes which channel is the REPOSITORY's statement, not this
# script's (ADR-028 D11). Sourced from beside this script so the tabletop suite
# gets it too.
_chan_lib="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../lib/channels-lib.sh"
# shellcheck source=../lib/channels-lib.sh
[[ -r "${_chan_lib}" ]] && . "${_chan_lib}"
# What runs here against what the checkout declares (ADR-028 D12, #746).
# shellcheck source=../lib/deployed-drift.sh
[[ -r "${_chan_lib%/*}/deployed-drift.sh" ]] && . "${_chan_lib%/*}/deployed-drift.sh"
SITE_FILE="${CONFIG_DIR}/site.json"
STATE_FILE="${CONFIG_DIR}/release-train.json"
# The boundary interval (ADR-028 D2). Policy, so it is named once.
BOUNDARY_DAYS="${TAPPAAS_BOUNDARY_DAYS:-14}"

YW=$'\033[33m'; RD=$'\033[01;31m'; GN=$'\033[1;92m'; BL=$'\033[36m'; CL=$'\033[m'; BOLD=$'\033[1m'
info()  { echo -e "${GN}[Info]${CL} $*"; }
warn()  { echo -e "${YW}[Warning]${CL} $*"; }
error() { echo -e "${RD}[Error]${CL} $*" >&2; }
die()   { error "$*"; exit 2; }
debug() { [[ "${TAPPAAS_DEBUG:-0}" == 1 ]] || return 0; echo "[Debug] $*" >&2; }

# The channel → branch map. One place, because every command needs it and a
# second copy is how they come to disagree.
channel_branch() {
    case "$1" in
        unstable)   echo main ;;
        staging)    echo staging ;;
        production) echo stable ;;
        *)          return 1 ;;
    esac
}

now_epoch() { echo "${TAPPAAS_TRAIN_NOW:-$(date -u +%s)}"; }

# ssh to another site. One place, so tests can replace it wholesale and phase 6
# is exercised without a second mothership.
sat_ssh() { ${TAPPAAS_TRAIN_SSH:-ssh -o BatchMode=yes -o ConnectTimeout=15} "$@"; }

# git in the site's checkout, quietly.
g() { git -C "${REPO_DIR}" "$@" 2>/dev/null; }

# ── the facts every command needs ────────────────────────────────────
# Read once, so status and init cannot describe different worlds.
read_train() {
    [[ -d "${REPO_DIR}/.git" ]] || die "not a git checkout: ${REPO_DIR}"
    # Refresh the remote refs first. A channel's position is a fact about the
    # forge, not about when this machine last pulled: without this, `status`
    # reports the distances of whenever the sweep last ran and an operator
    # reasons about a train that has already moved. It touches no working tree
    # and no branch — only refs/remotes. --no-fetch is for tests and offline.
    if [[ "${NO_FETCH}" != "1" ]]; then
        g fetch --quiet --tags origin main staging stable || \
            warn "could not reach the forge — the positions below are this machine's last fetch"
    fi
    SITE_CHANNEL="$(jq -r '.channel // empty' "${SITE_FILE}" 2>/dev/null)"
    SITE_BRANCH="$(jq -r '.repositories[]? | select(.name=="TAPPaaS") | .branch // empty' "${SITE_FILE}" 2>/dev/null)"
    SITE_NAME="$(jq -r '.name // empty' "${SITE_FILE}" 2>/dev/null)"
    # jq fails, not defaults, when the file is absent — so default here.
    [[ -n "${SITE_NAME}" ]] || SITE_NAME="this site"
    REF_MAIN="$(g rev-parse --short origin/main)"
    REF_STAGING="$(g rev-parse --short origin/staging)"
    REF_STABLE="$(g rev-parse --short origin/stable)"
    # The estate pin (ADR-028 D1): one lock, and the mothership follows it.
    PIN_LOCK="${REPO_DIR}/src/foundation/templates/flake.lock"
    PIN_REV="$(jq -r '.nodes.nixpkgs.locked.rev // empty' "${PIN_LOCK}" 2>/dev/null)"
    PIN_EPOCH="$(jq -r '.nodes.nixpkgs.locked.lastModified // empty' "${PIN_LOCK}" 2>/dev/null)"
    PIN_AGE=""
    [[ -n "${PIN_EPOCH}" ]] && PIN_AGE=$(( ( $(now_epoch) - PIN_EPOCH ) / 86400 ))
}

# stable ⊆ staging ⊆ main — the one assertion that makes the train promotable.
# It proves every promotion is a fast-forward and that nothing was pushed
# sideways into a channel. Sets ANCESTRY_OK and ANCESTRY_WHY.
check_ancestry() {
    ANCESTRY_OK=1; ANCESTRY_WHY=""
    # An alternative production branch that does not exist yet is not a
    # divergence — it is a rehearsal target, and promote_ref creates it.
    if ! g rev-parse --verify --quiet "origin/${PROD_BRANCH}" >/dev/null; then
        [[ "${PROD_BRANCH}" == "stable" ]] && { ANCESTRY_OK=0; ANCESTRY_WHY="origin/stable does not exist"; }
    elif ! g merge-base --is-ancestor "origin/${PROD_BRANCH}" "origin/${STAGING_BRANCH}"; then
        ANCESTRY_OK=0
        ANCESTRY_WHY="${PROD_BRANCH} is not an ancestor of ${STAGING_BRANCH} — something was pushed to ${PROD_BRANCH} directly"
    elif g rev-parse --verify --quiet "origin/${STAGING_BRANCH}" >/dev/null \
         && ! g merge-base --is-ancestor "origin/${STAGING_BRANCH}" origin/main; then
        ANCESTRY_OK=0
        ANCESTRY_WHY="${STAGING_BRANCH} is not an ancestor of main — it has commits main does not"
    fi
}

# Dates in the state file are written for people (ISO 8601, UTC) and read back
# here. GNU date on the mothership; the BSD forms let the suite run on a Mac.
iso_utc() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
day_utc() { date -u -d "@$1" +%Y-%m-%d 2>/dev/null || date -u -r "$1" +%Y-%m-%d; }
epoch_of() { date -u -d "$1" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$1" +%s 2>/dev/null; }

# The soak's start, in epoch seconds. `soakStartedAt` (epoch) is the shape
# before D13; it is read until the next boundary rewrites the file.
soak_started() {
    local s; s="$(jq -r '.soakStarted // empty' "${STATE_FILE}" 2>/dev/null)"
    if [[ -n "${s}" ]]; then epoch_of "${s}"; return 0; fi
    jq -r '.soakStartedAt // empty' "${STATE_FILE}" 2>/dev/null
}

# ── versions (ADR-028 D13) ───────────────────────────────────────────
# A version is an annotated tag, vMAJOR.MINOR, on the revision a boundary cuts
# into staging. The same number reaches production one boundary later, so one
# number names one revision for its whole life: a fault found while it soaks is
# reported against it and fixed as MAJOR.MINOR.N before production ever sees
# it. Every boundary is the next minor; --major is the next major; an urgent
# fix (D12) is MAJOR.MINOR.N on the channel it reaches. Tags travel with every
# clone, so a site reads its own version from its checkout (`git describe`).
RELEASE_TAG_RE='^v([0-9]+)\.([0-9]+)(\.([0-9]+))?$'
# The history, on main: the data, and the page rendered from it.
RELEASES_FILE="release/releases.json"
RELEASES_PAGE="RELEASES.md"

release_tags() { g tag --list 'v[0-9]*' --sort=-v:refname | grep -E "${RELEASE_TAG_RE}"; }

# "2.1", "2.1.1", or "2.1+14" for a commit 14 past its last release; empty when
# nothing before it is a release.
version_of() {
    local ref="$1" t n
    t="$(g describe --tags --abbrev=0 --match 'v[0-9]*' "${ref}")" || return 0
    [[ "${t}" =~ ${RELEASE_TAG_RE} ]] || return 0
    n="$(g rev-list --count "${t}..${ref}")"
    if (( n == 0 )); then echo "${t#v}"; else echo "${t#v}+${n}"; fi
}

# The release tag exactly on <ref>, or nothing.
release_tag_at() {
    local t
    for t in $(g tag --points-at "$1" --list 'v[0-9]*'); do
        [[ "${t}" =~ ${RELEASE_TAG_RE} ]] && { echo "${t}"; return 0; }
    done
    return 0
}

# The version the next boundary cuts: the newest MAJOR.MINOR plus one minor,
# or plus one major with --major. 1.0 in a repository with no release yet.
next_cut() {
    local top; top="$(release_tags | head -1)"
    [[ "${top}" =~ ${RELEASE_TAG_RE} ]] || { echo "1.0"; return 0; }
    if [[ "${MAJOR}" == "1" ]]; then echo "$(( BASH_REMATCH[1] + 1 )).0"
    else echo "${BASH_REMATCH[1]}.$(( BASH_REMATCH[2] + 1 ))"; fi
}

# The next urgent fix on a revision whose version is $1 (2.1, 2.1.1, 2.1+3):
# MAJOR.MINOR.N, one past the highest N already tagged on that MAJOR.MINOR.
next_patch() {
    local base="${1%%+*}" n=0 t z
    base="$(cut -d. -f1-2 <<<"${base}")"
    while IFS= read -r t; do
        [[ "${t}" =~ ${RELEASE_TAG_RE} ]] || continue
        [[ "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}" == "${base}" ]] || continue
        z="${BASH_REMATCH[4]:-0}"; (( z > n )) && n="${z}"
    done < <(release_tags)
    echo "${base}.$(( n + 1 ))"
}

# Tags and the release record describe the REAL channels. A rehearsal onto
# throwaway refs moves code no site runs, so it numbers nothing.
is_rehearsal() { [[ "${STAGING_BRANCH}" != "staging" || "${PROD_BRANCH}" != "stable" ]]; }

# Put an annotated release tag on <commit> and publish it. The same tag on the
# same commit is success (a resumed boundary); on another commit it is a
# refusal — a version names one revision, and is never moved.
make_release_tag() {
    local version="$1" commit="$2" msg="$3" t="v$1" at
    at="$(g rev-parse -q --verify "refs/tags/${t}^{commit}")"
    if [[ -n "${at}" ]]; then
        [[ "${at}" == "$(g rev-parse "${commit}^{commit}")" ]] \
            || { error "${t} already names $(g rev-parse --short "${at}") — a version is never moved"; return 1; }
    else
        g tag -a "${t}" -m "${msg}" "${commit}" || { error "could not tag ${t}"; return 1; }
    fi
    g push -q origin "refs/tags/${t}" || { error "could not publish ${t}"; return 1; }
    info "  ${GN}✓${CL} ${t} → $(g rev-parse --short "${commit}")"
}

# What a release's notes column says, in one place for the page and the CLI.
JQ_NOTES='def notes: [ (if .kind == "patch" then "urgent fix on \(.channel): \(.why // "")" else empty end),
                      (if .kind == "major" then "major" else empty end),
                      (if (.supersedes // []) != [] then "supersedes \(.supersedes | join(", "))" else empty end),
                      (if (.accepted // []) != [] then "accepted: \(.accepted | join("; "))" else empty end),
                      (if .forced then "boundary forced" else empty end),
                      (.note // empty) ] | join("; ");'

render_releases() {
    jq -r "${JQ_NOTES}"'
      "# TAPPaaS releases",
      "",
      "Every version, the revision it names, and when it reached each channel (ADR-028 D13).",
      "A boundary cuts the next version into **staging**; the same version reaches **production**",
      "at the boundary after. To run one: `git checkout v<version>`.",
      "",
      "Generated by `tappaas-train` from [`release/releases.json`](release/releases.json) — edit that, not this page.",
      "",
      "| Version | Commit | Staging | Production | Notes |",
      "|---|---|---|---|---|",
      (.releases[] | "| \(.version) | \(if (.commit // "") == "" then "`v\(.version)`" else "`\(.commit)`" end) | \(.staging // "—") | \(.production // "—") | \(notes) |")
    ' "$1"
}

# Cut ROADMAP.md for the version a boundary cuts (release/roadmap-cut.py, run from
# the checkout being released, so the script always matches the file it edits): the
# ✅ rows leave the waves for a `## Release <version>` section, `## Next release`
# becomes its summary, the promoted release gets its production date. A repository
# without a ROADMAP.md is left alone.
#   $1  the version cut   $2  the version that reached production, or ""
roadmap_cut() {
    local v="$1" p="$2" script="${REPO_DIR}/release/roadmap-cut.py"
    [[ -f "${REPO_DIR}/ROADMAP.md" ]] || { info "  no ROADMAP.md in this repository — nothing to cut"; return 0; }
    if [[ ! -f "${script}" ]]; then
        warn "  ROADMAP.md is not cut: this checkout has no release/roadmap-cut.py"
        return 0
    fi
    local out rc
    out="$(python3 "${script}" --file "${REPO_DIR}/ROADMAP.md" --version "${v}" \
        --date "$(day_utc "$(now_epoch)")" ${p:+--promoted "${p}"} 2>&1)"; rc=$?
    [[ -n "${out}" ]] && sed 's/^/  /' <<< "${out}"
    if (( rc != 0 )); then
        error "ROADMAP.md could not be cut for ${v} — nothing was committed"
        g checkout -q -- ROADMAP.md 2>/dev/null
        return 1
    fi
    g add ROADMAP.md
}

# Commit the history to main: release/releases.json, and RELEASES.md rendered
# from it. Made AFTER the channels moved, so it records what happened rather
# than what was meant. Idempotent — the first record of a version stands — so a
# resumed run, even days later, cannot record twice:
#   $1  the new release entry (JSON), or "null"
#   $2  the version that has just reached production, or ""
#   $3  the commit subject
#   $4  the commit production now holds (for a version the record lacks)
#   $5  the version a boundary cuts: ROADMAP.md is cut for it in the same commit
#       (release/roadmap-cut.py); "" for an urgent fix, which cuts no roadmap
record_release() {
    local entry="$1" promoted="$2" subject="$3" pcommit="${4:-}" cutv="${5:-}" f="${REPO_DIR}/${RELEASES_FILE}" tmp
    g checkout -q main && g merge -q --ff-only origin/main \
        || { error "main is not at origin/main — the release record was not written"; return 1; }
    mkdir -p "$(dirname "${f}")"
    [[ -f "${f}" ]] || printf '{"releases":[]}\n' > "${f}"
    tmp="${f}.tmp.$$"
    jq --argjson e "${entry}" --arg p "${promoted}" --arg pc "${pcommit}" --arg today "$(day_utc "$(now_epoch)")" '
        (if $e == null or any((.releases // [])[]; .version == $e.version) then . else .releases = ([$e] + (.releases // [])) end)
        | (if $p == "" or any(.releases[]; .version == $p) then . else .releases += [{version: $p, commit: $pc, staging: null, production: null}] end)
        | (if $p == "" then . else .releases |= map(if .version == $p and .production == null then .production = $today else . end) end)
        | (if $p == "" or $pc == "" then . else .releases |= map(if .version == $p and (.commit // "") == "" then .commit = $pc else . end) end)
        | .releases |= (sort_by(.version | split(".") | map(tonumber)) | reverse)
      ' "${f}" > "${tmp}" && mv -f "${tmp}" "${f}" \
        || { rm -f "${tmp}"; error "could not update ${RELEASES_FILE}"; return 1; }
    render_releases "${f}" > "${REPO_DIR}/${RELEASES_PAGE}" \
        || { error "could not render ${RELEASES_PAGE}"; return 1; }
    g add "${RELEASES_FILE}" "${RELEASES_PAGE}"
    if [[ -n "${cutv}" ]]; then
        roadmap_cut "${cutv}" "${promoted}" || { g checkout -q -- "${RELEASES_FILE}" "${RELEASES_PAGE}" 2>/dev/null; g reset -q; return 1; }
    fi
    if g diff --cached --quiet; then info "  the release record already says this"; return 0; fi
    g commit -q -m "${subject}" || { error "could not commit the release record"; return 1; }
    if ! g push -q origin main; then
        # main moved under us: drop the local commit, so a resume starts clean.
        g fetch --quiet origin main; g reset -q --hard origin/main
        error "could not publish the release record (main moved?) — re-run with --resume"
        return 1
    fi
    g fetch --quiet origin main
    info "  ${GN}✓${CL} recorded on main: ${subject}"
}

# Where each channel is, by version, for the state file. $1/$2: the date the
# staging/production channel last moved ("" keeps what the file says).
channels_state() {
    local s_since="$1" p_since="$2"
    jq -n --arg mc "$(g rev-parse --short origin/main)" --arg mv "$(version_of origin/main)" \
          --arg sb "${STAGING_BRANCH}" --arg sc "$(g rev-parse --short "origin/${STAGING_BRANCH}" 2>/dev/null)" \
          --arg sv "$(version_of "origin/${STAGING_BRANCH}")" --arg ss "${s_since}" \
          --arg pb "${PROD_BRANCH}" --arg pc "$(g rev-parse --short "origin/${PROD_BRANCH}" 2>/dev/null)" \
          --arg pv "$(version_of "origin/${PROD_BRANCH}")" --arg ps "${p_since}" \
          --slurpfile old <( [[ -f "${STATE_FILE}" ]] && cat "${STATE_FILE}" || echo '{}' ) '
        def since($new; $ch): if $new != "" then $new else (($old[0].channels[$ch] | objects | .since) // null) end;
        def v($x): if $x == "" then null else $x end;
        { unstable:   {branch: "main", commit: $mc, version: v($mv)},
          staging:    {branch: $sb, commit: $sc, version: v($sv), since: since($ss; "staging")},
          production: {branch: $pb, commit: $pc, version: v($pv), since: since($ps; "production")} }'
}

# ── status ───────────────────────────────────────────────────────────
CHAN_UNDECLARED=0
CHAN_MISMATCH=0
CHAN_NOBRANCH=0

cmd_status() {
    read_train
    check_ancestry

    echo
    info "${BOLD}Release train — ${SITE_NAME}${CL}"
    printf '  %-12s %-9s %-10s %-10s %s\n' CHANNEL BRANCH COMMIT VERSION "DISTANCE"
    printf '  %-12s %-9s %-10s %-10s %s\n' unstable   main    "${REF_MAIN}"    "$(version_of origin/main)" "—"
    printf '  %-12s %-9s %-10s %-10s %s\n' staging    staging "${REF_STAGING}" "$(version_of origin/staging)" \
        "$(g rev-list --count origin/staging..origin/main) behind main"
    printf '  %-12s %-9s %-10s %-10s %s\n' production stable  "${REF_STABLE}" "$(version_of origin/stable)" \
        "$(g rev-list --count origin/stable..origin/staging) behind staging"
    echo
    # D12: a channel carrying an urgent fix says so until the next boundary.
    local _x
    while IFS= read -r _x; do
        [[ -n "${_x}" ]] && warn "  carrying an urgent fix: ${_x}"
    done < <(jq -r '(.expedited // [])[] | "\(.version) on \(.channel) (\(.date)): \(.why)"' "${STATE_FILE}" 2>/dev/null)

    if [[ -n "${SITE_CHANNEL}" ]]; then
        local want; want="$(channel_branch "${SITE_CHANNEL}")"
        if [[ "${SITE_BRANCH}" == "${want}" ]]; then
            info "  this site runs ${BL}${SITE_CHANNEL}${CL} on ${BL}${SITE_BRANCH}${CL}"
        else
            warn "  this site says channel '${SITE_CHANNEL}' but tracks '${SITE_BRANCH}' (expected '${want}')"
        fi
    else
        warn "  this site declares no channel — site-manager site modify --channel <c>"
    fi
    # D12: a site patched in place runs code its channel does not declare, and
    # the next refresh reverts it silently. Say so while it is true.
    if declare -f deployed_drift >/dev/null 2>&1; then
        local _d
        while IFS= read -r _d; do [[ -n "${_d}" ]] && warn "  ${_d}"; done \
            < <(deployed_drift "${REPO_DIR}" "${BIN_DIR}" "${SITE_BRANCH}")
    fi

    # Every registered repository, not just this one (ADR-028 D11). A site on
    # `production` whose Community checkout sits on somebody's `main` is not a
    # production site, and before D11 nothing could say so.
    if declare -f site_repos >/dev/null 2>&1; then
        echo
        info "${BOLD}Repositories this site tracks${CL}"
        printf '  %-14s %-18s %-11s %s\n' REPOSITORY BRANCH REALIZES NOTE
        local _rn _rb _rp _real _note
        while IFS=$'\t' read -r _rn _rb _rp; do
            [[ -n "${_rn}" ]] || continue
            _note=""
            if ! channels_declared "${_rp}"; then
                _real="?"
                _note="no channels.json — every branch reads as unstable"
                CHAN_UNDECLARED=$((CHAN_UNDECLARED + 1))
            else
                _real="$(branch_channel "${_rp}" "${_rb}")"
                if [[ -n "${SITE_CHANNEL}" && "${_real}" != "${SITE_CHANNEL}" ]]; then
                    # Two different problems, and only one is fixable by moving
                    # a branch. A repository that declares NO branch for this
                    # channel cannot realize it at all — switching branches
                    # inside it will never help, so say that instead of
                    # implying the operator picked the wrong one.
                    if [[ -z "$(channel_branches "${_rp}" "${SITE_CHANNEL}")" ]]; then
                        _note="declares NO branch for '${SITE_CHANNEL}'"
                        CHAN_NOBRANCH=$((CHAN_NOBRANCH + 1))
                    else
                        _note="site claims '${SITE_CHANNEL}' — expected $(channel_branches "${_rp}" "${SITE_CHANNEL}" | head -1)"
                        CHAN_MISMATCH=$((CHAN_MISMATCH + 1))
                    fi
                fi
            fi
            printf '  %-14s %-18s %-11s %s\n' "${_rn}" "${_rb}" "${_real}" "${_note}"
        done < <(site_repos "${CONFIG_DIR}/site.json")
        (( CHAN_UNDECLARED == 0 )) || warn "  ${CHAN_UNDECLARED} repository/repositories declare no channels.json (ADR-028 D11)"
        (( CHAN_MISMATCH == 0 )) || warn "  ${CHAN_MISMATCH} repository/repositories are not on the branch this site's channel names"
        # The one an operator cannot resolve by switching a branch.
        if (( CHAN_NOBRANCH > 0 )); then
            warn "  ${CHAN_NOBRANCH} repository/repositories have NO branch for '${SITE_CHANNEL}' —"
            warn "    this site cannot honestly claim that channel for them until one exists."
        fi
    fi

    [[ -n "${PIN_REV}" ]] && info "  estate pin ${BL}${PIN_REV:0:12}${CL}, ${PIN_AGE} days old"

    # What would stop a boundary. Reported, never acted on: status changes
    # nothing, which is what makes it safe to run when something is wrong.
    local blocks=0
    echo
    if (( ANCESTRY_OK )); then
        info "  ${GN}✓${CL} stable ⊆ staging ⊆ main — every promotion is a fast-forward"
    else
        error "  ✗ ${ANCESTRY_WHY}"; blocks=$((blocks+1))
    fi

    blueprint_check
    if [[ "${BP_OK}" == "yes" ]]; then
        info "  ${GN}✓${CL} $(blueprint_line)"
    else
        error "  ✗ $(blueprint_line)"
        local w; for w in ${BP_WHY+"${BP_WHY[@]}"}; do error "      ${w}"; done
        error "      see: ${BIN_DIR}/module-manager validate --blueprint --repo ${REPO_DIR}"
        blocks=$((blocks+1))
    fi

    secrets_check
    if [[ "${SS_OK}" == "yes" ]]; then
        info "  ${GN}✓${CL} $(secrets_line)"
    else
        error "  ✗ $(secrets_line)"
        local sw; for sw in ${SS_WHY+"${SS_WHY[@]}"}; do error "      ${sw}"; done
        error "      a false positive goes in ${REPO_DIR}/.gitleaks.toml; a real one is rotated, then removed"
        blocks=$((blocks+1))
    fi

    # Container image pins (#750): reported, never a block.
    pins_check
    pins_report

    local fault; fault="$(jq -r '.fault.what // empty' "${STATE_FILE}" 2>/dev/null)"
    if [[ -n "${fault}" ]]; then
        error "  ✗ a staging fault blocks promotion: ${fault}"
        error "      resolve it on main, then: ${SCRIPT_NAME} fault --resolved <commit>"
        blocks=$((blocks+1))
    fi

    local started; started="$(soak_started)"
    if [[ -z "${started}" ]]; then
        warn "  the soak clock has not been started — run: ${SCRIPT_NAME} init"
        blocks=$((blocks+1))
    else
        local days_in=$(( ( $(now_epoch) - started ) / 86400 ))
        if (( days_in >= BOUNDARY_DAYS )); then
            info "  ${GN}✓${CL} soak complete: ${days_in} days, boundary is due"
        else
            info "  soak in progress: ${days_in} of ${BOUNDARY_DAYS} days"
            blocks=$((blocks+1))
        fi
        local _soaking; _soaking="$(version_of origin/staging)"
        info "  next boundary $(day_utc $(( started + BOUNDARY_DAYS * 86400 ))): cuts $(next_cut)${_soaking:+, ${_soaking} reaches production}"
    fi

    echo
    if (( blocks == 0 )); then
        info "${GN}A boundary may run.${CL}"
    else
        info "${YW}Not promotable yet${CL} — ${blocks} thing(s) above."
    fi
    return 0
}

# ── init ─────────────────────────────────────────────────────────────
# Does NOT create the channel refs: they exist (stable since 2026-09-18,
# staging since 2026-09-23), and a command that creates a channel on demand is
# how a typo becomes a release. It verifies them, and starts the soak clock —
# the one thing the first boundary genuinely lacks.
cmd_init() {
    read_train
    local missing=0
    for r in main staging stable; do
        if g rev-parse --verify --quiet "origin/${r}" >/dev/null; then
            info "  ${GN}✓${CL} origin/${r} exists"
        else
            error "  ✗ origin/${r} does not exist — create it from the channel above before using the train"
            missing=$((missing+1))
        fi
    done
    (( missing == 0 )) || { error "The train needs all three refs."; return 1; }

    check_ancestry
    if (( ! ANCESTRY_OK )); then
        error "  ✗ ${ANCESTRY_WHY}"
        error "The train is fast-forward only; a human must reconcile this before a boundary runs."
        return 1
    fi
    info "  ${GN}✓${CL} stable ⊆ staging ⊆ main"

    local started; started="$(soak_started)"
    if [[ -n "${started}" ]]; then
        info "  soak clock already running since $(day_utc "${started}")"
        return 0
    fi
    local now; now="$(now_epoch)"
    local tmp="${STATE_FILE}.tmp.$$"
    jq -n --arg started "$(iso_utc "${now}")" --arg next "$(day_utc $(( now + BOUNDARY_DAYS * 86400 )))" \
          --argjson channels "$(channels_state "" "")" --arg pin "${PIN_REV}" '{
            soakStarted: $started,
            nextBoundary: $next,
            channels: $channels,
            pin: $pin,
            fault: null
          }' > "${tmp}" && mv -f "${tmp}" "${STATE_FILE}" \
        || { rm -f "${tmp}"; error "could not write ${STATE_FILE}"; return 1; }
    info "  ${GN}✓${CL} soak clock started — a boundary becomes due in ${BOUNDARY_DAYS} days"
    return 0
}

# ── the module blueprint (ADR-027 D5, #674) ──────────────────────────
# Every module in this repository is checked against what a module is made of,
# on the code the boundary is about to promote, once a fortnight — here rather
# than on every push. A missing MUST is BROKEN: a release does not go out with
# a module that is not a whole module. Warnings (a missing test) are reported
# and never block. Community is not checked: this train promotes TAPPaaS only.
#
# Also checked: every service README's generated field section matches its
# fields.json (ADR-027 D3), and every stack README's and INSTALL.md's module
# list matches the catalogue (#421) — a stale one is BROKEN too, since regenerating is one command. Sets BP_OK (yes|no|unchecked), BP_ERRORS, BP_WARNINGS,
# BP_READMES (ok|stale|unchecked), BP_COMMIT and BP_WHY (what to fix).
BP_OK=""; BP_ERRORS=0; BP_WARNINGS=0; BP_READMES=""; BP_COMMIT=""; BP_WHY=()
blueprint_check() {
    BP_OK=""; BP_ERRORS=0; BP_WARNINGS=0; BP_READMES="unchecked"; BP_WHY=()
    BP_COMMIT="$(g rev-parse --short=12 HEAD 2>/dev/null || true)"
    local mm="${BIN_DIR}/module-manager" out
    if [[ ! -x "${mm}" ]]; then
        BP_OK="unchecked"; BP_WHY+=("module-manager not found at ${mm}")
        return 0
    fi
    out="$("${mm}" validate --blueprint --repo "${REPO_DIR}" --json 2>/dev/null || true)"
    if ! jq -e '(.errors | type) == "number"' >/dev/null 2>&1 <<<"${out}"; then
        BP_OK="unchecked"; BP_WHY+=("module-manager validate --blueprint gave no report")
        return 0
    fi
    BP_ERRORS="$(jq -r '.errors' <<<"${out}")"
    BP_WARNINGS="$(jq -r '.warnings // 0' <<<"${out}")"
    local line
    while IFS= read -r line; do
        [[ -n "${line}" ]] && BP_WHY+=("${line}")
    done < <(jq -r '[.findings[]? | select(.severity == "error") | "\(.module): \(.path)"] | .[:8][]' <<<"${out}")
    (( BP_ERRORS <= 8 )) || BP_WHY+=("… and $(( BP_ERRORS - 8 )) more")
    # The generator composes from THIS tree only (no site config), so another
    # repository's READMEs cannot block a TAPPaaS release.
    local gen="${REPO_DIR}/src/foundation/tappaas-cicd/scripts/gen-service-fields-doc.py"
    if [[ -f "${gen}" ]]; then
        if CONFIG_DIR=/nonexistent python3 "${gen}" --check >/dev/null 2>&1; then
            BP_READMES="ok"
        else
            BP_READMES="stale"
            BP_WHY+=("service README field sections are out of date — run: CONFIG_DIR=/nonexistent python3 ${gen}")
        fi
    fi
    # Each stack README's and INSTALL.md's module list (#421) is generated from the catalogue too.
    local sgen="${REPO_DIR}/src/foundation/tappaas-cicd/scripts/gen-stack-readme.py"
    if [[ -f "${sgen}" ]]; then
        if python3 "${sgen}" --check --repo "${REPO_DIR}" >/dev/null 2>&1; then
            [[ "${BP_READMES}" == "stale" ]] || BP_READMES="ok"
        else
            BP_READMES="stale"
            BP_WHY+=("stack README/INSTALL.md module lists are out of date — run: python3 ${sgen}")
        fi
    fi
    if (( BP_ERRORS == 0 )) && [[ "${BP_READMES}" != "stale" ]]; then BP_OK="yes"; else BP_OK="no"; fi
    return 0
}

# One line for status and preflight alike.
blueprint_line() {
    case "${BP_OK}" in
        yes)       printf 'module blueprint met at %s (%s warning(s))' "${BP_COMMIT}" "${BP_WARNINGS}" ;;
        no)        printf 'module blueprint NOT met at %s: %s missing MUST(s)%s' "${BP_COMMIT}" "${BP_ERRORS}" \
                       "$([[ "${BP_READMES}" == "stale" ]] && printf ', generated READMEs stale')" ;;
        *)         printf 'module blueprint could not be checked' ;;
    esac
}

# The boundary keeps what it found: which commit met the blueprint, per release.
record_blueprint() {
    local tmp="${STATE_FILE}.tmp.$$"
    [[ -f "${STATE_FILE}" ]] || return 0
    jq --arg c "${BP_COMMIT}" --arg ok "${BP_OK}" --argjson e "${BP_ERRORS}" --argjson w "${BP_WARNINGS}" \
       --arg r "${BP_READMES}" --arg at "$(iso_utc "$(now_epoch)")" \
       '.blueprint = {commit: $c, checkedAt: $at, ok: ($ok == "yes"), result: $ok, errors: $e, warnings: $w, readmes: $r}' \
       "${STATE_FILE}" > "${tmp}" && mv -f "${tmp}" "${STATE_FILE}" || rm -f "${tmp}"
}

# ── no secret in what is released (#378) ─────────────────────────────
# gitleaks, once a fortnight on what the boundary promotes — here rather than
# on every push (operator, 2026-10-03: no daily scans): the commits since the
# last release and the tree as it stands. Findings are BROKEN — a release does
# not go out with a credential in it — and so is a scan that could not run.
# The repository's own .gitleaks.toml (the default rules + the false positives
# it allowlists) is what decides. Values are redacted: the report names the
# file, line and rule, never the secret. Sets SS_OK (yes|no|unchecked),
# SS_FINDINGS, SS_COMMIT, SS_RANGE and SS_WHY.
SS_OK=""; SS_FINDINGS=0; SS_COMMIT=""; SS_RANGE=""; SS_WHY=()
secrets_check() {
    SS_OK=""; SS_FINDINGS=0; SS_WHY=(); SS_RANGE=""
    SS_COMMIT="$(g rev-parse --short=12 HEAD 2>/dev/null || true)"
    # TAPPAAS_GITLEAKS names the binary (tests); otherwise BIN_DIR, then PATH.
    local gl="${TAPPAAS_GITLEAKS:-}"
    if [[ -z "${gl}" ]]; then
        gl="${BIN_DIR}/gitleaks"
        [[ -x "${gl}" ]] || gl="$(command -v gitleaks 2>/dev/null || true)"
    fi
    if [[ -z "${gl}" || ! -x "${gl}" ]]; then
        SS_OK="unchecked"; SS_WHY+=("gitleaks is not installed (tappaas-cicd.nix systemPackages)")
        return 0
    fi
    local prev rep_git rep_dir n_git n_dir cfg=()
    [[ -f "${REPO_DIR}/.gitleaks.toml" ]] && cfg=(--config "${REPO_DIR}/.gitleaks.toml")
    prev="$(release_tags | head -1)"
    rep_git="$(mktemp)"; rep_dir="$(mktemp)"
    if [[ -n "${prev}" ]]; then
        SS_RANGE="${prev}..${SS_COMMIT}"
        "${gl}" git "${REPO_DIR}" ${cfg[@]+"${cfg[@]}"} --log-opts="${prev}..HEAD" --redact --no-banner \
            --report-format json --report-path "${rep_git}" >/dev/null 2>&1
    else
        SS_RANGE="tree only (no release yet)"; echo '[]' > "${rep_git}"
    fi
    "${gl}" dir "${REPO_DIR}" ${cfg[@]+"${cfg[@]}"} --redact --no-banner --report-format json --report-path "${rep_dir}" >/dev/null 2>&1
    if ! n_git="$(jq -e 'length' "${rep_git}" 2>/dev/null)" || ! n_dir="$(jq -e 'length' "${rep_dir}" 2>/dev/null)"; then
        SS_OK="unchecked"; SS_WHY+=("gitleaks gave no report")
        rm -f "${rep_git}" "${rep_dir}"; return 0
    fi
    local line
    while IFS= read -r line; do
        [[ -n "${line}" ]] && SS_WHY+=("${line}")
    done < <(jq -rs --arg r "${REPO_DIR}/" \
        'add | map("\(.File | ltrimstr($r)):\(.StartLine) [\(.RuleID)]\(if .Commit != "" then " in " + .Commit[0:8] else "" end)")
         | unique | .[:8][]' "${rep_git}" "${rep_dir}" 2>/dev/null)
    SS_FINDINGS=$(( n_git + n_dir ))
    (( SS_FINDINGS <= 8 )) || SS_WHY+=("… $(( SS_FINDINGS )) finding(s) in all")
    rm -f "${rep_git}" "${rep_dir}"
    if (( SS_FINDINGS == 0 )); then SS_OK="yes"; else SS_OK="no"; fi
    return 0
}

secrets_line() {
    case "${SS_OK}" in
        yes) printf 'no secret found at %s (%s)' "${SS_COMMIT}" "${SS_RANGE}" ;;
        no)  printf 'SECRETS found at %s: %s finding(s) (%s)' "${SS_COMMIT}" "${SS_FINDINGS}" "${SS_RANGE}" ;;
        *)   printf 'the secret scan could not run' ;;
    esac
}

record_secrets() {
    local tmp="${STATE_FILE}.tmp.$$"
    [[ -f "${STATE_FILE}" ]] || return 0
    jq --arg c "${SS_COMMIT}" --arg ok "${SS_OK}" --argjson n "${SS_FINDINGS}" --arg r "${SS_RANGE}" \
       --arg at "$(iso_utc "$(now_epoch)")" \
       '.secrets = {commit: $c, checkedAt: $at, ok: ($ok == "yes"), result: $ok, findings: $n, range: $r}' \
       "${STATE_FILE}" > "${tmp}" && mv -f "${tmp}" "${STATE_FILE}" || rm -f "${tmp}"
}

# ── container image pins (#750, ADR-028 D4) ──────────────────────────
# Each pin in src/image-pins.json: its age and how far upstream is ahead, at
# every boundary — the cadence a container pin never had. A pin older than the
# tripwire (45 days, as D4) with a newer upstream is STALE: reported, recorded,
# and NEVER a refusal — moving a pin is its maintainer's reviewed change, and a
# stale pin is a release decision (D4). Sets IP_JSON (the report), IP_STALE,
# IP_OK (yes|unchecked).
IP_JSON=""; IP_STALE=0; IP_OK=""
pins_check() {
    IP_JSON=""; IP_STALE=0; IP_OK="unchecked"
    local tool="${TAPPAAS_IMAGE_PINS:-${REPO_DIR}/src/foundation/tappaas-cicd/scripts/image-pins.py}"
    [[ -f "${REPO_DIR}/src/image-pins.json" && -e "${tool}" ]] || return 0
    IP_JSON="$(python3 "${tool}" --repo "${REPO_DIR}" --json 2>/dev/null || true)"
    jq -e '.pins | type == "array"' >/dev/null 2>&1 <<<"${IP_JSON}" || { IP_JSON=""; return 0; }
    IP_STALE="$(jq -r '.stale // 0' <<<"${IP_JSON}")"
    IP_OK="yes"
}

# One line per pin, for status and the boundary alike.
pins_report() {
    if [[ "${IP_OK}" != "yes" ]]; then
        warn "  ⧗ container image pins could not be checked (src/image-pins.json, scripts/image-pins.py)"
        return 0
    fi
    local line
    while IFS=$'\t' read -r st line; do
        [[ -n "${line}" ]] || continue
        case "${st}" in
            stale) warn "  ⧗ ${line}" ;;
            *)     info "  ${GN}✓${CL} ${line}" ;;
        esac
    done < <(jq -r '.pins[] |
        [.status, (
          if .status == "digest" then "image \(.module): \(.image) by digest, \(.ageDays // "?")d old (age only)"
          elif .status == "unreadable" then "image \(.module): pin not found in \(.file)"
          elif .status == "unknown" then "image \(.module): \(.image):\(.pinned), \(.ageDays // "?")d old — upstream not checked"
          elif (.newer // 0) == 0 then "image \(.module): \(.image):\(.pinned), \(.ageDays)d old — current"
          else "image \(.module): \(.image):\(.pinned), \(.ageDays)d old — \(.newer) newer, latest \(.latest)\(if .status == "stale" then " — STALE (tripwire 45d; \(.maintainer))" else "" end)"
          end) + (if ((.mismatch // []) | length) > 0 then " — a copy differs: \(.mismatch | join("; "))" else "" end)] | @tsv' <<<"${IP_JSON}")
    local n; n="$(jq -r '.unlisted | length' <<<"${IP_JSON}")"
    (( n == 0 )) || info "  · ${n} image(s) in the tree not yet in src/image-pins.json: $(jq -r '[.unlisted[].image] | join(", ")' <<<"${IP_JSON}")"
}

pins_line() {
    case "${IP_OK}" in
        yes) printf '%s pin(s), %s stale' "$(jq -r '.pins | length' <<<"${IP_JSON}")" "${IP_STALE}" ;;
        *)   printf 'not checked' ;;
    esac
}

record_pins() {
    local tmp="${STATE_FILE}.tmp.$$"
    [[ -f "${STATE_FILE}" && "${IP_OK}" == "yes" ]] || return 0
    jq --argjson r "${IP_JSON}" --arg at "$(iso_utc "$(now_epoch)")" \
       '.imagePins = {checkedAt: $at, stale: $r.stale, pins: [$r.pins[] | {module, image, pinned, ageDays, latest, newer, status}], unlisted: [$r.unlisted[].image]}' \
       "${STATE_FILE}" > "${tmp}" && mv -f "${tmp}" "${STATE_FILE}" || rm -f "${tmp}"
}

# ── preflight (design: phase 0) ──────────────────────────────────────
# Every one of these is a refusal, not a warning: a release script that warns
# and proceeds is one nobody reads the output of.
#
# Two kinds of "no", and they are not the same (that distinction is why a
# soak-in-progress must not read like a diverged channel):
#   WAIT   — correct today, resolves itself with time. Only --force-boundary.
#   BROKEN — a human must look. --force-boundary does NOT lift these.
PF_WAIT=(); PF_BROKEN=()
preflight() {
    read_train
    check_ancestry
    PF_WAIT=(); PF_BROKEN=()

    # This site must be the unstable one: a production site promoting its own
    # untested code is the failure the train exists to prevent.
    [[ "${SITE_CHANNEL}" == "unstable" ]] \
        || PF_BROKEN+=("this site's channel is '${SITE_CHANNEL:-unset}', not 'unstable' — a boundary is driven from where development is proven")

    # A tree nobody can reproduce must not become a release.
    [[ -z "$(g status --porcelain)" ]] || PF_BROKEN+=("the checkout has uncommitted changes")
    [[ "$(g rev-parse HEAD)" == "$(g rev-parse origin/main)" ]] \
        || PF_BROKEN+=("the checkout is not at origin/main — pull or push before promoting")

    # Find out about the credential now, not after the pin has moved.
    g push --dry-run origin "origin/main:refs/heads/main" >/dev/null 2>&1 \
        || PF_BROKEN+=("cannot push to origin — the boundary would stop halfway")

    (( ANCESTRY_OK )) || PF_BROKEN+=("${ANCESTRY_WHY}")

    # A sweep mid-flight is reading the branch this is about to move.
    local sweep; sweep="$(systemctl show -p ActiveState --value update-tappaas.service 2>/dev/null)"
    case "${sweep}" in active|activating|reloading|deactivating)
        PF_WAIT+=("a sweep is running here (${sweep}) — it is reading the branch this would move") ;;
    esac

    # The design's "no sweep active HERE or on the staging site": a sweep there
    # is reading the branch this is about to move under it. Only checkable when
    # the operator has named the host — there is no cross-site registry.
    if [[ -n "${STAGING_HOST}" ]]; then
        local rsweep
        rsweep="$(sat_ssh "${STAGING_HOST}" 'systemctl show -p ActiveState --value update-tappaas.service' 2>/dev/null)"
        if [[ -z "${rsweep}" ]]; then
            PF_BROKEN+=("cannot reach the staging site '${STAGING_HOST}' — phase 6 could not verify the promotion")
        else
            case "${rsweep}" in active|activating|reloading|deactivating)
                PF_WAIT+=("a sweep is running on the staging site (${rsweep})") ;;
            esac
        fi
    fi

    # Never promote on top of an estate that is already failing: the new pin
    # would be blamed for a failure that predates it.
    local last="${CONFIG_DIR}/last-update-result.json"
    if [[ -r "${last}" ]] && [[ "$(jq -r '.ok // true' "${last}" 2>/dev/null)" != "true" ]]; then
        PF_BROKEN+=("this site's last sweep failed ($(jq -r '(.failed_modules // []) | join(", ")' "${last}" 2>/dev/null)) — fix that first")
    fi

    local fault; fault="$(jq -r '.fault.what // empty' "${STATE_FILE}" 2>/dev/null)"
    [[ -z "${fault}" ]] || PF_BROKEN+=("an unresolved staging fault blocks promotion: ${fault}")

    # A release does not go out with a module that is not a whole module.
    blueprint_check
    if [[ "${BP_OK}" != "yes" ]]; then
        local w; PF_BROKEN+=("$(blueprint_line) — module-manager validate --blueprint --repo ${REPO_DIR}")
        for w in ${BP_WHY+"${BP_WHY[@]}"}; do PF_BROKEN+=("    ${w}"); done
    fi

    # Nor with a credential in it (#378).
    secrets_check
    if [[ "${SS_OK}" != "yes" ]]; then
        local sw; PF_BROKEN+=("$(secrets_line) — false positive: .gitleaks.toml; real: rotate, then remove")
        for sw in ${SS_WHY+"${SS_WHY[@]}"}; do PF_BROKEN+=("    ${sw}"); done
    fi

    local started; started="$(soak_started)"
    if [[ -z "${started}" ]]; then
        PF_BROKEN+=("the soak clock has not been started — run '${SCRIPT_NAME} init'")
    else
        local days_in=$(( ( $(now_epoch) - started ) / 86400 ))
        (( days_in >= BOUNDARY_DAYS )) \
            || PF_WAIT+=("the soak is ${days_in} of ${BOUNDARY_DAYS} days — promoting now makes staging a formality")
    fi
    return 0
}

report_preflight() {
    local b w
    for b in ${PF_BROKEN+"${PF_BROKEN[@]}"}; do error "  ✗ ${b}"; done
    for w in ${PF_WAIT+"${PF_WAIT[@]}"};   do warn  "  ⧗ ${w}"; done
    (( ${#PF_BROKEN[@]} == 0 && ${#PF_WAIT[@]} == 0 )) && info "  ${GN}✓${CL} preflight clear"
    return 0
}

# ── boundary (design: phases 1-6) ────────────────────────────────────
# Recorded after every phase, so a boundary that fails halfway can be resumed
# rather than restarted: phases 3-5 are pushes, and re-running a push that
# already happened is how `main` and `staging` come to disagree about what was
# promoted.
phase_done() {
    local ph="$1" tmp="${STATE_FILE}.tmp.$$"
    jq --arg p "${ph}" '.boundary.phasesDone = ((.boundary.phasesDone // []) + [$p] | unique)' \
       "${STATE_FILE}" > "${tmp}" && mv -f "${tmp}" "${STATE_FILE}" || rm -f "${tmp}"
}
phase_pending() {   # 1 = still to do
    local ph="$1"
    [[ "${RESUME}" == "1" ]] || return 0
    jq -e --arg p "${ph}" '((.boundary.phasesDone // []) | index($p)) != null' \
        "${STATE_FILE}" >/dev/null 2>&1 && return 1 || return 0
}

# Fast-forward one channel ref onto another, on the forge. Refuses anything
# else: a channel that would need a merge is a channel someone pushed to.
promote_ref() {
    local from="$1" to="$2"
    # A named alternative may not exist yet: creating it is the point of
    # rehearsing a promotion. `stable` is never created here — a production
    # channel that appears because of a typo is the failure this train prevents.
    if ! g rev-parse --verify --quiet "origin/${to}" >/dev/null; then
        if [[ "${to}" == "stable" ]]; then
            error "origin/stable does not exist — create the production channel deliberately, not from a promotion"
            return 1
        fi
        warn "  origin/${to} does not exist — creating it at ${from} (rehearsal target)"
        [[ "${DRY_RUN}" == "1" ]] && { info "    (dry run: not pushed)"; return 0; }
        g push origin "origin/${from}:refs/heads/${to}" >/dev/null 2>&1 \
            || { error "could not create ${to}"; return 1; }
        g fetch --quiet origin "${to}"; return 0
    fi
    if ! g merge-base --is-ancestor "origin/${to}" "origin/${from}"; then
        error "origin/${to} is not an ancestor of origin/${from} — refusing a non-fast-forward promotion"
        return 1
    fi
    if [[ "$(g rev-parse "origin/${from}")" == "$(g rev-parse "origin/${to}")" ]]; then
        info "  ${to} already matches ${from} — nothing to promote"
        return 0
    fi
    info "  promoting ${from} → ${to} ($(g rev-list --count "origin/${to}..origin/${from}") commits)"
    [[ "${DRY_RUN}" == "1" ]] && { info "    (dry run: not pushed)"; return 0; }
    g push origin "origin/${from}:refs/heads/${to}" >/dev/null 2>&1 \
        || { error "push ${from} → ${to} failed"; return 1; }
    g fetch --quiet origin "${to}"
    return 0
}

# ── phase 1: branch, and move the estate pin ─────────────────────────
# One lock decides the estate (ADR-028 D1), so this is one command. The branch
# exists so the move is reviewable and revertible before it reaches main.
# Phase 1 leaves the checkout as it found it when it gives up. Preflight has
# already refused a dirty tree (PF_BROKEN), so these two files are ours alone —
# and a half-moved pin left behind would make the NEXT run's preflight refuse.
abandon_phase_branch() {
    # One at a time: a pathspec that matches nothing makes `git checkout --`
    # restore nothing at all, which is the opposite of what this is for.
    local f
    for f in src/foundation/templates/flake.nix \
             src/foundation/templates/flake.lock \
             src/foundation/tappaas-cicd/flake.lock; do
        [[ -e "${REPO_DIR}/${f}" ]] && g checkout -q -- "${f}"
    done
    g checkout -q main
    g branch -D "${1}" >/dev/null 2>&1
    return 1
}

do_phase_branch() {
    local br; br="pin/$(date -u +%Y-w%V)"
    info "${BOLD}Phase 1: ${br} — refresh the estate pin${CL}"
    local before; before="$(jq -r '.nodes.nixpkgs.locked.rev // empty' "${PIN_LOCK}")"
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "  (dry run) would branch ${br} and update ${PIN_LOCK##*/}"
        return 0
    fi

    g rev-parse --verify --quiet "${br}" >/dev/null && g branch -D "${br}" >/dev/null 2>&1
    g checkout -q -b "${br}" origin/main || { error "could not branch ${br}"; return 1; }

    # A version move edits the REF; a patch refresh only re-resolves it. Both
    # then update the lock, which is why they are one rhythm and not two.
    # Only templates/flake.nix carries a ref — the mothership follows it (D1).
    local nixfile="${REPO_DIR}/src/foundation/templates/flake.nix"
    if [[ -n "${TO_BRANCH}" ]]; then
        local from_ref
        from_ref="$(sed -n 's|.*github:NixOS/nixpkgs/\([^"]*\)".*|\1|p' "${nixfile}" | head -1)"
        # Without a ref to replace, the substitution below would corrupt the
        # file rather than fail, so read it as "I do not understand this flake".
        [[ -n "${from_ref}" ]] \
            || { error "no github:NixOS/nixpkgs/<ref> found in ${nixfile#"${REPO_DIR}/"}"
                 abandon_phase_branch "${br}"; return 1; }
        if [[ "${from_ref}" == "${TO_BRANCH}" ]]; then
            info "  already tracking ${TO_BRANCH}"
        else
            info "  version move: ${from_ref} → ${TO_BRANCH}"
            sed -i.bak "s|github:NixOS/nixpkgs/${from_ref}|github:NixOS/nixpkgs/${TO_BRANCH}|" "${nixfile}" \
                && rm -f "${nixfile}.bak" \
                || { error "could not rewrite ${nixfile##*/}"; abandon_phase_branch "${br}"; return 1; }
        fi
    fi

    ( cd "${REPO_DIR}/src/foundation/templates" \
      && nix flake update --extra-experimental-features "nix-command flakes" ) >/dev/null 2>&1 \
        || { error "nix flake update failed"; abandon_phase_branch "${br}"; return 1; }
    # D1 says one pin, but `follows` only decides where the mothership LOOKS —
    # its own lock keeps a copy of the node until it is re-locked (measured on
    # hrossen 2026-09-23: templates moved to 26.05 and the mothership's flake
    # still resolved the old revision). Two locks that disagree is the split
    # pin #709 is about, so both move here or neither does.
    local cicd_dir="${REPO_DIR}/src/foundation/tappaas-cicd"
    if [[ -f "${cicd_dir}/flake.lock" ]]; then
        ( cd "${cicd_dir}" \
          && nix flake update --extra-experimental-features "nix-command flakes" ) >/dev/null 2>&1 \
            || { error "the mothership lock could not follow the new pin"; abandon_phase_branch "${br}"; return 1; }
    fi

    local after; after="$(jq -r '.nodes.nixpkgs.locked.rev // empty' "${PIN_LOCK}")"
    if [[ -f "${cicd_dir}/flake.lock" ]]; then
        local cicd_rev
        cicd_rev="$(jq -r '.nodes.nixpkgs.locked.rev // empty' "${cicd_dir}/flake.lock")"
        # Each update resolves the ref on its own, so a branch tip that moved
        # between the two would leave the mothership on a different revision
        # from every guest — silently, which is the whole danger.
        [[ "${cicd_rev}" == "${after}" ]] || {
            error "the two locks disagree: guests ${after:0:12}, mothership ${cicd_rev:0:12}"
            abandon_phase_branch "${br}"; return 1; }
    fi
    if [[ "${before}" == "${after}" ]]; then
        # A frozen branch, or one already current. Not an error — but an empty
        # commit would make the record claim a move that did not happen.
        warn "  the pin did not move (${before:0:12}) — the branch is likely frozen or already current"
        if [[ "${ALLOW_NO_PIN_CHANGE}" != "1" ]]; then
            info "  a frozen branch cannot refresh. Move the release instead: --to <nixos-XX.YY>"
            info "  or prove what is already pinned: --allow-no-pin-change"
            abandon_phase_branch "${br}"
            return 1
        fi
        # The boundary's value here is the PROOF, not the move: the pin was
        # landed by other means and this run exists to put it through the guest,
        # the sweep and the deep test. There is nothing to branch, so the site
        # proves `main` itself and phase 3 becomes a no-op.
        info "  --allow-no-pin-change: proving what is already pinned, on main"
        abandon_phase_branch "${br}" || true
        local tmp0="${STATE_FILE}.tmp.$$"
        jq --arg p "${before}" \
           '.boundary = ((.boundary // {}) + {branch: "main", pinFrom: $p, pinTo: $p, noPinChange: true})' \
           "${STATE_FILE}" > "${tmp0}" && mv -f "${tmp0}" "${STATE_FILE}" || rm -f "${tmp0}"
        return 0
    fi
    info "  pin ${before:0:12} → ${after:0:12}"
    pin_gate "${REPO_DIR}/src/foundation/templates" "${before}" || { abandon_phase_branch "${br}"; return 1; }
    # One pathspec that matches nothing makes `git add` stage NOTHING, and the
    # commit below then fails with the pin already rewritten on disk — so each
    # path is offered on its own.
    local f
    for f in src/foundation/templates/flake.nix \
             src/foundation/templates/flake.lock \
             src/foundation/tappaas-cicd/flake.lock; do
        [[ -e "${REPO_DIR}/${f}" ]] && g add "${f}"
    done
    local msg="chore(pin): estate nixpkgs ${before:0:12} -> ${after:0:12}"
    [[ -n "${TO_BRANCH}" ]] && msg="chore(pin): estate nixpkgs moves to ${TO_BRANCH}"
    g commit -q -m "${msg}" \
        || { error "could not commit the pin"; abandon_phase_branch "${br}"; return 1; }
    # The site can only TRACK a branch the forge has — repo-sync reconciles
    # against origin, not against whatever happens to be on this disk.
    #
    # --force-with-lease, because this ref is the train's own scratch: it is cut
    # from origin/main afresh every run, so a boundary retried in the SAME week
    # (a blocked one, fixed and re-run) carries a different commit under the
    # same name and a plain push is refused as non-fast-forward. The lease still
    # refuses if the ref moved to something this run has not seen.
    g push -q --force-with-lease origin "${br}" \
        || { error "could not publish ${br}"; abandon_phase_branch "${br}"; return 1; }

    local tmp="${STATE_FILE}.tmp.$$"
    jq --arg b "${br}" --arg f "${before}" --arg t "${after}" \
       '.boundary = ((.boundary // {}) + {branch: $b, pinFrom: $f, pinTo: $t})' \
       "${STATE_FILE}" > "${tmp}" && mv -f "${tmp}" "${STATE_FILE}" || rm -f "${tmp}"
    return 0
}

# ── phase 2: prove it HERE, guest first ──────────────────────────────
# The order is the point (ADR-028 D9): a guest that fails the new pin is
# snapshot-rolled back by update-module.sh, and the control plane stays able to
# investigate. The mothership meets the revision only after a guest has.
# The site's own declaration of this checkout. `site.json` is what the sweep
# reconciles the working tree to, so moving the checkout without moving this is
# how the pin was silently reverted mid-boundary (measured 2026-09-23).
tracked_repo() {
    local f="${CONFIG_DIR}/site.json"
    jq -r --arg p "${REPO_DIR}" \
       '(.repositories // []) | map(select(.path == $p)) | .[0].name // empty' "${f}" 2>/dev/null
}

# Point the site's declaration at <branch>, so the sweep's repo-sync keeps the
# checkout there instead of resetting it back to `main` half way through.
declare_branch() {
    local repo="$1" branch="$2"
    [[ -n "${repo}" ]] || { error "no repository in site.json has path ${REPO_DIR}"; return 1; }
    site-manager repository modify "${repo}" --branch "${branch}" >/dev/null 2>&1 \
        || { error "could not point ${repo} at ${branch}"; return 1; }
    local on; on="$(g rev-parse --abbrev-ref HEAD)"
    [[ "${on}" == "${branch}" ]] || { error "declared ${branch} but the checkout is on ${on}"; return 1; }
    return 0
}

pick_guest() {
    [[ -n "${GUEST}" ]] && { echo "${GUEST}"; return 0; }
    local f n
    for f in "${CONFIG_DIR}"/*.json; do
        jq -e '(.dependsOn // []) | index("templates:nixos")' "${f}" >/dev/null 2>&1 || continue
        n="$(basename "${f}" .json)"; echo "${n}"; return 0
    done
    return 1
}

do_phase_prove() {
    local br; br="$(jq -r '.boundary.branch // empty' "${STATE_FILE}")"
    info "${BOLD}Phase 2: prove the pin here${CL}"
    local guest; guest="$(pick_guest)" \
        || { error "no NixOS guest found to try first — name one with --guest"; return 1; }
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "  (dry run) would track ${br:-the pin branch}, update ${guest} first, then sweep, then test --deep"
        return 0
    fi

    # THE SITE MUST TRACK THE PIN BRANCH BEFORE ANYTHING SWEEPS.
    # The sweep refreshes the control plane, and that reconciles the checkout to
    # the branch site.json declares — so a checkout merely parked on the pin
    # branch is reset back to `main` mid-phase, and everything after that point
    # builds against the OLD revision while reporting success. Observed on
    # hrossen 2026-09-23: only the guest-first step ran on the new pin; the
    # whole sweep behind it silently did not.
    local repo; repo="$(tracked_repo)"
    [[ -n "${br}" ]] || { error "no branch recorded — re-run without --resume"; return 1; }
    info "  the site now tracks ${br} (the sweep would otherwise reset it to main)"
    declare_branch "${repo}" "${br}" || return 1

    # From here every exit restores the declaration: a site left tracking a pin
    # branch would take its next scheduled sweep from a branch nobody maintains.
    _prove_fail() { warn "  restoring the site to main"; declare_branch "${repo}" main || true; return 1; }

    info "  ${guest} meets the new pin first (a failure there rolls that guest back, not the estate)"
    if ! "${BIN_DIR}/update-module.sh" "${guest}"; then
        error "${guest} failed on the new pin — the estate is untouched and the branch is intact."
        error "  Fix it, then: ${SCRIPT_NAME} boundary --resume"
        _prove_fail; return 1
    fi
    info "  the guest is good; now the whole site"
    site-manager update || { error "the sweep failed on the new pin"; _prove_fail; return 1; }

    # The sweep is the thing that could have moved it back. Say so if it did,
    # rather than testing the old revision and calling it proof.
    local on; on="$(g rev-parse --abbrev-ref HEAD)"
    [[ "${on}" == "${br}" ]] \
        || { error "the sweep left the checkout on ${on}, not ${br} — nothing after the guest was proved"
             _prove_fail; return 1; }

    info "  deep test — nothing is promoted unless this passes"
    site-manager test --deep || { error "the deep test failed on the new pin"; _prove_fail; return 1; }
    return 0
}

# ── phase 3: land it on main ─────────────────────────────────────────
do_phase_main() {
    local br; br="$(jq -r '.boundary.branch // empty' "${STATE_FILE}")"
    [[ -n "${br}" ]] || { error "no branch recorded — re-run without --resume"; return 1; }
    if [[ "${br}" == "main" ]]; then
        # --allow-no-pin-change: nothing was branched, so there is nothing to
        # land. main is already what was proved.
        info "${BOLD}Phase 3: nothing to land — main is what was proved${CL}"
        return 0
    fi
    info "${BOLD}Phase 3: land ${br} on main${CL}"
    [[ "${DRY_RUN}" == "1" ]] && { info "  (dry run) would fast-forward main to ${br} and publish it"; return 0; }
    g checkout -q main || return 1
    g merge --ff-only "${br}" >/dev/null 2>&1 || { error "main could not fast-forward to ${br}"; return 1; }
    g push origin main >/dev/null 2>&1 || { error "could not publish main"; return 1; }
    g fetch --quiet origin main
    info "  main is now $(g rev-parse --short origin/main)"

    # Back to the channel this site runs. Until this happens its nightly sweep
    # would pull from a pin branch nobody maintains.
    declare_branch "$(tracked_repo)" main || return 1
    # The commit is an ancestor of main now, so the branch holds nothing that
    # main does not. Left behind, one accumulates every fortnight.
    g push -q origin --delete "${br}" >/dev/null 2>&1
    g branch -D "${br}" >/dev/null 2>&1
    return 0
}

# ── phases 5a/5b: number the cut, and record it ─────────────────────
tag_message() {   # $1 = version, $2 = forced (1/0)
    local prev; prev="$(release_tags | grep -vx "v$1" | head -1)"
    printf 'TAPPaaS %s\n\n' "$1"
    printf 'Cut into staging %s; reaches production at the next boundary (due %s).\n' \
        "$(day_utc "$(now_epoch)")" "$(day_utc $(( $(now_epoch) + BOUNDARY_DAYS * 86400 )))"
    printf 'Boundary:   %s\n' "$([[ "$2" == "1" ]] && echo "forced (--force-boundary)" || echo "on schedule")"
    printf 'Estate pin: nixpkgs %s\n' "$(jq -r '.nodes.nixpkgs.locked.rev // "?"' "${PIN_LOCK}" 2>/dev/null | cut -c1-12)"
    printf 'Blueprint:  %s\n' "$(blueprint_line)"
    printf 'Secrets:    %s\n' "$(secrets_line)"
    printf 'Images:     %s\n' "$(pins_line)"
    [[ -n "${prev}" ]] && printf 'Previous:   %s\n' "${prev}"
    return 0
}

do_phase_tag() {   # $1 = the version this boundary cuts, $2 = forced
    local cut="$1" tip="origin/${STAGING_BRANCH}" have
    if is_rehearsal; then
        info "  rehearsal: ${STAGING_BRANCH} would be cut as ${cut} — no version is tagged"
        return 0
    fi
    have="$(release_tag_at "${tip}")"
    # Staging did not move (it already held main), so there is no new
    # revision to number.
    if [[ -n "${have}" && "${have}" != "v${cut}" ]]; then
        info "  staging is still ${have#v} — no new revision, no new version"
        return 0
    fi
    make_release_tag "${cut}" "${tip}" "$(tag_message "${cut}" "$2")"
}

# Runs BEFORE main is promoted to staging (operator, 2026-10-07): the record and
# the ROADMAP.md cut are committed to main first, so the revision cut into staging —
# and its tag — already says what it is. The new version's commit is the record
# commit itself, which cannot name its own hash: it is left empty (RELEASES.md shows
# the tag) and filled in when the version reaches production. A resumed run that
# finds staging already tagged records the tagged commit, as before.
do_phase_record() {   # $1 = the version this boundary cuts, $2 = forced, $3 = kind
    local cut="$1" entry="null" promoted subject=() commit=""
    if is_rehearsal; then info "  rehearsal: nothing is added to the release record"; return 0; fi
    if [[ "$(release_tag_at "origin/${STAGING_BRANCH}")" == "v${cut}" ]]; then
        commit="$(g rev-parse --short=12 "origin/${STAGING_BRANCH}")"
    elif g rev-parse --verify --quiet "origin/${STAGING_BRANCH}" >/dev/null \
         && g merge-base --is-ancestor origin/main "origin/${STAGING_BRANCH}"; then
        cut=""          # staging already holds main: nothing new is cut
    fi
    # The urgent fixes the channels carried (D12) are part of what is promoted
    # now: the boundary says so, and its record names them.
    local sup
    sup="$(jq -c '[(.expedited // [])[].version]' "${STATE_FILE}" 2>/dev/null || echo '[]')"
    [[ "${sup}" == "[]" || -z "${sup}" ]] || info "  this boundary supersedes the urgent fixes $(jq -r 'join(", ")' <<<"${sup}")"
    if [[ -n "${cut}" ]]; then
        entry="$(jq -n --arg v "${cut}" --arg c "${commit}" \
            --arg d "$(day_utc "$(now_epoch)")" --arg k "$3" --argjson f "$([[ "$2" == "1" ]] && echo true || echo false)" \
            --arg p "$(jq -r '.nodes.nixpkgs.locked.rev // ""' "${PIN_LOCK}" 2>/dev/null | cut -c1-12)" \
            --argjson s "${sup:-[]}" \
            --argjson acc "$(jq -c '.boundary.accepted // []' "${STATE_FILE}" 2>/dev/null || echo '[]')" \
            '{version: $v, commit: $c, staging: $d, production: null, kind: $k, forced: $f, pin: $p}
             + (if ($s | length) > 0 then {supersedes: $s} else {} end)
             + (if ($acc | length) > 0 then {accepted: $acc} else {} end)')"
        subject+=("${cut} to staging")
    fi
    # Production holds a release only when the revision it took was one; the
    # first boundary promotes what staging held before versions existed.
    promoted="$(version_of "origin/${PROD_BRANCH}")"
    [[ "${promoted}" == *+* ]] && promoted=""
    [[ -n "${promoted}" ]] && subject+=("${promoted} to production")
    (( ${#subject[@]} > 0 )) || { info "  nothing new to record"; return 0; }
    local joined="${subject[0]}"
    (( ${#subject[@]} > 1 )) && joined+=", ${subject[1]}"
    record_release "${entry}" "${promoted}" "chore(release): ${joined}" "$(g rev-parse --short=12 "origin/${PROD_BRANCH}")" "${cut}"
}

cmd_boundary() {
    preflight
    echo
    info "${BOLD}Boundary preflight${CL}"
    report_preflight
    # Kept whatever the verdict, so the record says which commit met — or did
    # not meet — the blueprint at each boundary. A dry run records nothing.
    pins_check
    info "${BOLD}Container image pins${CL} (ADR-028 D4 — reported, never a refusal)"
    pins_report
    [[ "${DRY_RUN}" == "1" ]] || { record_blueprint; record_secrets; record_pins; }
    local forced="${FORCE_BOUNDARY}"
    if (( ${#PF_BROKEN[@]} > 0 )); then
        error "Refusing: the train is not sound. --force-boundary does not lift these."
        return 1
    fi
    if (( ${#PF_WAIT[@]} > 0 )); then
        if [[ "${forced}" != "1" ]]; then
            error "Refusing: not due yet. Re-run with --force-boundary if that is what you mean."
            return 1
        fi
        warn "  --force-boundary given: proceeding despite the above, and recording that."
    fi

    echo
    info "${BOLD}Plan${CL}"
    if [[ -n "${TO_BRANCH}" ]]; then
        info "  1  branch pin/$(date -u +%Y-w%V), move the release to ${TO_BRANCH} (a VERSION move)"
    else
        info "  1  branch pin/$(date -u +%Y-w%V), refresh the estate pin"
    fi
    preview_plan
    info "  2  prove it here: $(pick_guest 2>/dev/null || echo "a guest") first, then the sweep, then --deep"
    info "  3  land on main (hours: the sweep reboots nodes, the deep test builds guests)"
    # The version is decided once, here, and kept: a resumed run tags what the
    # plan said, not whatever is "next" by the time it gets there.
    local cut kind
    cut="$(jq -r '.boundary.cut // empty' "${STATE_FILE}" 2>/dev/null)"
    kind="$(jq -r '.boundary.kind // empty' "${STATE_FILE}" 2>/dev/null)"
    [[ -n "${cut}" ]] || cut="$(next_cut)"
    [[ -n "${kind}" ]] || kind="$([[ "${MAJOR}" == "1" ]] && echo major || echo minor)"
    local soaked; soaked="$(version_of "origin/${STAGING_BRANCH}")"
    info "  4  promote ${STAGING_BRANCH} → ${PROD_BRANCH}   ($(g rev-list --count "origin/${PROD_BRANCH}..origin/staging" 2>/dev/null || echo "?") commits reach production${soaked:+: ${soaked}})"
    if is_rehearsal; then
        info "  5  promote main → ${STAGING_BRANCH}   (a rehearsal: no version is cut or recorded)"
    else
        info "  5  record the release and cut ROADMAP.md on main, then promote main → ${STAGING_BRANCH} and tag it ${BL}v${cut}${CL}$([[ "${kind}" == major ]] && echo " (a MAJOR)")"
        if [[ "${DRY_RUN}" == "1" && -f "${REPO_DIR}/ROADMAP.md" && -f "${REPO_DIR}/release/roadmap-cut.py" ]]; then
            python3 "${REPO_DIR}/release/roadmap-cut.py" --check --file "${REPO_DIR}/ROADMAP.md" --version "${cut}" \
                --date "$(day_utc "$(now_epoch)")" ${soaked:+--promoted "${soaked}"} 2>&1 | sed 's/^roadmap-cut: /       ROADMAP.md: /'
        fi
    fi
    info "  6  verify the staging site"
    if [[ "${DRY_RUN}" == "1" ]]; then
        echo; info "Dry run: nothing was changed."
        return 0
    fi
    local tmpc="${STATE_FILE}.tmp.$$"
    jq --arg c "${cut}" --arg k "${kind}" '.boundary = ((.boundary // {}) + {cut: $c, kind: $k})' \
       "${STATE_FILE}" > "${tmpc}" && mv -f "${tmpc}" "${STATE_FILE}" || rm -f "${tmpc}"

    # Phases 1-3: move the pin, prove it HERE, land it. Each is recorded, so a
    # run that fails half way is resumed rather than restarted — re-running a
    # push that already happened is how main and staging come to disagree.
    phase_pending "branch" && { do_phase_branch || return 1; phase_done "branch"; }
    phase_pending "prove"  && { do_phase_prove  || return 1; phase_done "prove";  }
    phase_pending "main"   && { do_phase_main   || return 1; phase_done "main";   }

    # Nothing is promoted unless the deep test passed. If it failed, the branch
    # is intact, the estate is untouched, and the operator fixes it or promotes
    # by hand — a promotion is never the consolation prize for a failed test.
    echo
    info "${BOLD}Promoting${CL}"
    if phase_pending "production"; then
        if g rev-parse --verify --quiet "origin/${STAGING_BRANCH}" >/dev/null; then
            promote_ref "${STAGING_BRANCH}" "${PROD_BRANCH}" || return 1
        else
            # Nothing has soaked on a ref that does not exist yet, so there is
            # nothing to give production. The staging promotion below creates it.
            warn "  origin/${STAGING_BRANCH} does not exist — nothing has soaked, so no production push"
        fi
        phase_done "production"
    fi
    # The record and the ROADMAP.md cut go onto main FIRST, so what reaches staging
    # — and its tag — already carries them; nobody edits either mid-boundary.
    phase_pending "record"  && { do_phase_record "${cut}" "${forced}" "${kind}" || return 1; phase_done "record"; }
    phase_pending "staging" && { promote_ref main "${STAGING_BRANCH}" || return 1; phase_done "staging"; }
    phase_pending "tag"     && { do_phase_tag "${cut}" "${forced}" || return 1; phase_done "tag"; }

    # The clock restarts from the promotion, not from when someone remembered.
    # Written for people: dates, and each channel's version. The urgent fixes a
    # channel carried (D12) are now part of what was promoted, so they go.
    local now today tmp="${STATE_FILE}.tmp.$$"
    now="$(now_epoch)"; today="$(day_utc "${now}")"
    jq --arg started "$(iso_utc "${now}")" --arg today "${today}" \
       --arg next "$(day_utc $(( now + BOUNDARY_DAYS * 86400 )))" \
       --argjson channels "$(channels_state "${today}" "${today}")" --arg forced "${forced}" \
       --arg cut "$(is_rehearsal || [[ "$(release_tag_at "origin/${STAGING_BRANCH}")" != "v${cut}" ]] || echo "${cut}")" \
       --arg pin "$(jq -r '.nodes.nixpkgs.locked.rev // empty' "${PIN_LOCK}" 2>/dev/null)" '
        del(.soakStartedAt)
        | .soakStarted = $started
        | .nextBoundary = $next
        | .channels = $channels
        | .lastBoundary = {date: $today, forced: ($forced == "1"), cut: (if $cut == "" then null else $cut end)}
        | .pin = $pin
        | del(.expedited)
        | del(.ack)
        | .boundary = null' "${STATE_FILE}" > "${tmp}" && mv -f "${tmp}" "${STATE_FILE}" || rm -f "${tmp}"

    echo
    info "${GN}Boundary complete.${CL} The next one is due $(day_utc $(( now + BOUNDARY_DAYS * 86400 )))."

    # Phase 6 — the staging site is the only thing that can find what this just
    # promoted, so a boundary that skips it has moved code and learned nothing.
    if [[ -z "${STAGING_HOST}" ]]; then
        warn "  Phase 6 SKIPPED: no --staging-host given, and this site holds no record of where staging runs."
        warn "    Verify it by hand, then record anything it finds: ${SCRIPT_NAME} fault <what>"
        return 0
    fi
    info "${BOLD}Phase 6: verifying the staging site (${STAGING_HOST})${CL}"
    local rchan
    rchan="$(sat_ssh "${STAGING_HOST}" 'jq -r ".channel // empty" ~/config/site.json' 2>/dev/null)"
    if [[ "${rchan}" != "staging" ]]; then
        warn "  ${STAGING_HOST} declares channel '${rchan:-unset}', not 'staging' — verifying it anyway, but it is not the audience this promoted for"
    fi
    info "  pulling the new staging there…"
    sat_ssh "${STAGING_HOST}" 'git -C ~/TAPPaaS pull --ff-only --quiet origin staging' >/dev/null 2>&1 \
        || warn "  could not fast-forward its checkout — it may be mid-update, or have local commits"
    info "  running its update (this is the soak beginning, and it takes a while)…"
    if sat_ssh "${STAGING_HOST}" 'site-manager update' 2>&1 | tail -5; then
        local rok
        rok="$(sat_ssh "${STAGING_HOST}" 'jq -r ".ok // false" ~/config/last-update-result.json' 2>/dev/null)"
        if [[ "${rok}" == "true" ]]; then
            info "  ${GN}✓${CL} the staging site updated cleanly onto the new revision"
        else
            warn "  the staging site's update reported a failure."
            warn "    That is staging doing its job. Record it, and production stays where it is:"
            warn "      ${SCRIPT_NAME} fault <what went wrong>"
        fi
    else
        warn "  could not run the update on ${STAGING_HOST} — verify by hand"
    fi
    return 0
}

# ── fault ────────────────────────────────────────────────────────────
# ADR-028 D9: a fault found in staging blocks promotion until it is resolved,
# and the resolution must be ON MAIN. Nothing rewinds — patch forward.
cmd_fault() {
    read_train
    if [[ "${1:-}" == "--resolved" ]]; then
        local commit="${2:-}"
        [[ -n "${commit}" ]] || die "fault --resolved needs the commit that fixes it"
        [[ -f "${STATE_FILE}" ]] || die "no train state — nothing is recorded as faulty"
        [[ -n "$(jq -r '.fault.what // empty' "${STATE_FILE}" 2>/dev/null)" ]] \
            || die "no fault is recorded"
        # "Resolved" means the fix is an ancestor of main — a checkable fact,
        # not an intention. A hotfix left only on staging would be undone by the
        # very next boundary, which promotes main INTO staging.
        g rev-parse --verify --quiet "${commit}^{commit}" >/dev/null \
            || die "unknown commit: ${commit}"
        if ! on_main "${commit}"; then
            error "${commit} is not on main."
            error "  A fix that lives only on staging is reintroduced by the next boundary,"
            error "  which promotes main into staging. Land it on main first."
            return 1
        fi
        local tmp="${STATE_FILE}.tmp.$$"
        jq --arg c "${commit}" --arg now "$(iso_utc "$(now_epoch)")" \
           '.fault = null | .lastFaultResolved = {commit: $c, at: $now}' \
           "${STATE_FILE}" > "${tmp}" && mv -f "${tmp}" "${STATE_FILE}" \
            || { rm -f "${tmp}"; die "could not update ${STATE_FILE}"; }
        info "  ${GN}✓${CL} fault cleared — ${commit:0:12} is on main. Promotion is unblocked."
        return 0
    fi

    local what="$*"
    [[ -n "${what}" ]] || die "usage: ${SCRIPT_NAME} fault <what went wrong> | fault --resolved <commit>"
    [[ -f "${STATE_FILE}" ]] || die "no train state — run '${SCRIPT_NAME} init' first"
    local tmp="${STATE_FILE}.tmp.$$"
    jq --arg w "${what}" --arg now "$(iso_utc "$(now_epoch)")" \
       '.fault = {what: $w, at: $now}' "${STATE_FILE}" > "${tmp}" \
        && mv -f "${tmp}" "${STATE_FILE}" || { rm -f "${tmp}"; die "could not update ${STATE_FILE}"; }
    warn "  Fault recorded. Promotion to production is BLOCKED until it is resolved on main."
    info "  Staging keeps the revision; production keeps what it has (ADR-028 D9)."
    info "  When the fix is on main: ${SCRIPT_NAME} fault --resolved <commit>"
    return 0
}

# The fix is on main: D9's "resolved" and D12's "may move" are the same fact —
# a fix only on a channel is undone by the next boundary, which promotes main.
on_main() { g merge-base --is-ancestor "$1" origin/main; }

# A D12 reason names its case first, so the bar can be audited from the record.
D12_CLAUSES="data safety:|security:|service down:"
d12_clause_ok() { [[ "$1" =~ ^(data\ safety|security|service\ down):\ *[^\ ] ]]; }

# ── patch (ADR-028 D12) ──────────────────────────────────────────────
# An urgent fix reaches a channel before its boundary. The fix was authored on
# a branch off the channel's own tip and merged into main; this moves the
# channel onto it, numbers it MAJOR.MINOR.N and records why — the reason in
# the state file BEFORE the move, as D12 asks, and on main after it.
cmd_patch() {
    read_train
    local channel="${1:-}" commit="${2:-}" branch full
    case "${channel}" in
        staging)    branch="${STAGING_BRANCH}" ;;
        production) branch="${PROD_BRANCH}" ;;
        *) die "usage: ${SCRIPT_NAME} patch <staging|production> <commit> --why \"<what>\"" ;;
    esac
    [[ -n "${commit}" ]] || die "patch needs the commit that carries the fix"
    [[ -n "${WHY}" ]] || die "patch needs --why: which D12 case (data safety, a security CVE, a service down) and what"
    d12_clause_ok "${WHY}" || die "--why must start with the D12 case it invokes — ${D12_CLAUSES//|/ or } — then what: \"service down: grafana crash-loops on /etc/secrets\". Not urgent otherwise (ADR-028 D12)."
    full="$(g rev-parse --verify --quiet "${commit}^{commit}")" || die "unknown commit: ${commit}"
    [[ -z "$(g status --porcelain)" ]] || { error "the checkout has uncommitted changes"; return 1; }

    # Forward only: the channel's tip must be behind the fix (D9 never rewinds).
    if [[ "$(g rev-parse "origin/${branch}")" == "${full}" ]]; then
        error "${branch} is already at ${commit}"; return 1
    fi
    if ! g merge-base --is-ancestor "origin/${branch}" "${full}"; then
        error "${commit} does not build on ${branch}'s tip — author the fix on a branch off ${branch} (ADR-028 D12)"
        return 1
    fi
    # On main, or the next boundary reintroduces the fault.
    if ! on_main "${full}"; then
        error "${commit} is not on main. Merge the fix branch into main first —"
        error "  a fix that lives only on a channel is undone by the next boundary."
        return 1
    fi
    # stable ⊆ staging: production may not get ahead of staging.
    if [[ "${channel}" == "production" ]] && ! g merge-base --is-ancestor "${full}" "origin/${STAGING_BRANCH}"; then
        error "${commit} is not on ${STAGING_BRANCH}: production would get ahead of staging."
        error "  Patch staging first (a branch off its tip that merges the fix, landed on main), then production."
        return 1
    fi

    local now version count
    now="$(now_epoch)"
    count="$(g rev-list --count "origin/${branch}..${full}")"
    version="$(next_patch "$(version_of "origin/${branch}")")"
    [[ "${version}" != .* ]] || { error "${branch} has no release before it to patch"; return 1; }
    info "${BOLD}Urgent fix → ${channel} (${branch})${CL}"
    info "  ${branch} $(g rev-parse --short "origin/${branch}") → $(g rev-parse --short "${full}"), ${count} commit(s):"
    g log --format='      %h %s' "origin/${branch}..${full}"
    # D12 moves a channel by the fix and no more. Not refused — the operator
    # decides — but a long list is the soak being skipped, so it is said.
    (( count <= 3 )) || warn "  ${count} commits: D12 moves a channel by the fix alone — check this is not unsoaked work riding along"
    if is_rehearsal; then info "  rehearsal: no version is tagged or recorded"
    else info "  version ${BL}${version}${CL} — why: ${WHY}"; fi
    if [[ "${DRY_RUN}" == "1" ]]; then echo; info "Dry run: nothing was changed."; return 0; fi

    # Recorded before the move (D12), so a move that fails half way is on file.
    local tmp="${STATE_FILE}.tmp.$$"
    [[ -f "${STATE_FILE}" ]] || echo '{}' > "${STATE_FILE}"
    jq --arg c "${channel}" --arg v "${version}" --arg k "$(g rev-parse --short=12 "${full}")" \
       --arg w "${WHY}" --arg d "$(day_utc "${now}")" \
       '.expedited = ((.expedited // []) + [{channel: $c, version: $v, commit: $k, why: $w, date: $d}])' \
       "${STATE_FILE}" > "${tmp}" && mv -f "${tmp}" "${STATE_FILE}" || { rm -f "${tmp}"; error "could not write ${STATE_FILE}"; return 1; }

    g push -q origin "${full}:refs/heads/${branch}" || { error "could not move ${branch}"; return 1; }
    g fetch --quiet origin "${branch}"
    info "  ${GN}✓${CL} ${branch} is at $(g rev-parse --short "origin/${branch}")"
    is_rehearsal && return 0

    make_release_tag "${version}" "${full}" "$(printf 'TAPPaaS %s — urgent fix on %s\n\n%s\n\nADR-028 D12. Moved %s, %s commit(s) on %s.\n' \
        "${version}" "${channel}" "${WHY}" "$(day_utc "${now}")" "${count}" "$(version_of "${full}^" | cut -d+ -f1)")" || return 1
    local entry
    entry="$(jq -n --arg v "${version}" --arg c "$(g rev-parse --short=12 "${full}")" --arg d "$(day_utc "${now}")" \
        --arg ch "${channel}" --arg w "${WHY}" \
        '{version: $v, commit: $c, staging: (if $ch == "staging" then $d else null end),
          production: (if $ch == "production" then $d else null end), kind: "patch", channel: $ch, why: $w}')"
    record_release "${entry}" "" "chore(release): ${version}, an urgent fix on ${channel}" || return 1
    jq --argjson ch "$(channels_state "$([[ ${channel} == staging ]] && day_utc "${now}")" "$([[ ${channel} == production ]] && day_utc "${now}")")" \
       '.channels = $ch' "${STATE_FILE}" > "${tmp}" && mv -f "${tmp}" "${STATE_FILE}" || rm -f "${tmp}"
    return 0
}

# ── preview / ack (#788) ─────────────────────────────────────────────
# What a pin move brings is found in minutes by EVALUATING the guests against
# the next pin — not after the hours a boundary spends proving it and rolling
# it back. A major version change, or a critical/high CVE the move introduces,
# needs an operator's word; `ack` gives it ahead of time, and the boundary
# checks the pin it takes against that word before its deep test.
PREVIEW_FILE="${CONFIG_DIR}/train-preview.json"
# Per module: each side's CVEs, images and changed packages (`preview --module`).
DETAILS_FILE="${CONFIG_DIR}/train-preview-details.json"
TRAIN_SCRIPTS="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# pin_findings <dir holding the candidate flake.lock> <from rev> <out json> [<details json>]
# The last release against "if released now" (#788): the release's tree, its
# nixpkgs pin and its image pins on one side; this tree, the candidate pin and
# its image pins on the other — every NixOS module evaluated (nothing built),
# every pinned image scanned by reference, all with today's CVE database.
# rc 1, with the reason on stderr, when it cannot judge: no release tag, no
# security scan to compare with, or a pin that cannot be fetched.
# TAPPAAS_PIN_FINDINGS (tests): a command run as `cmd <dir> <from> <out>`.
pin_findings() {
    local dir="$1" from="$2" out="$3" sbom="${CONFIG_DIR}/sbom" work tag base_src now_src side tree src ok rel drv
    if [[ -n "${TAPPAAS_PIN_FINDINGS:-}" ]]; then
        bash -c "${TAPPAAS_PIN_FINDINGS}" _ "${dir}" "${from}" "${out}" "${4:-}"; return
    fi
    [[ -s "${sbom}/site.cdx.json" && -s "${sbom}/cve-status.json" ]] \
        || { echo "no security scan to compare with — run: health-manager scan security" >&2; return 1; }
    tag="${SINCE_TAG:-$(g tag -l 'v[0-9]*' --sort=-v:refname | head -1)}"
    [[ -n "${tag}" ]] && g rev-parse --verify --quiet "${tag}^{commit}" >/dev/null \
        || { echo "no release to compare with${SINCE_TAG:+ (${SINCE_TAG} unknown)}" >&2; return 1; }
    work="$(mktemp -d)"; mkdir -p "${work}/release" "${work}/base" "${work}/now"
    g archive "${tag}" src | tar -x -C "${work}/release" \
        || { rm -rf "${work}"; echo "could not unpack ${tag}" >&2; return 1; }
    fetch_pin() { nix eval --impure --raw --expr \
        "(builtins.fetchTree (builtins.fromJSON (builtins.readFile $1)).nodes.nixpkgs.locked).outPath" 2>/dev/null; }
    base_src="$(fetch_pin "${work}/release/src/foundation/templates/flake.lock")" \
        || { rm -rf "${work}"; echo "the pin of ${tag} could not be fetched" >&2; return 1; }
    now_src="$(fetch_pin "${dir}/flake.lock")" \
        || { rm -rf "${work}"; echo "the candidate pin could not be fetched" >&2; return 1; }
    local mode files=()
    for side in base now; do
        # A past release is evaluated as it was built: before #324 its modules
        # carried their own copy of the baseline, so adding today's would clash.
        if [[ "${side}" == base ]]; then tree="${work}/release/src"; src="${base_src}"; mode="--as-is"
        else tree="${REPO_DIR}/src"; src="${now_src}"; mode=""; fi
        # The modules TAPPaaS ships: every NixOS system in the tree but the
        # template, the mothership (a flake of its own), the module template (00-Template) and
        # test fixtures (a path segment test-*, or test-fixtures/).
        mapfile -t files < <(grep -rl --include='*.nix' 'system\.stateVersion' "${tree}" 2>/dev/null \
            | grep -v -e '/foundation/templates/' -e '/flake\.nix$' -e '/tappaas-cicd/tappaas-cicd\.nix$' \
                      -e '/misc/' -e '/00-Template/' -e '/test-' -e '/test-fixtures/' | sort)
        info "  evaluating ${#files[@]} NixOS module(s) of $([[ ${side} == base ]] && echo "${tag}" || echo "this tree") — nothing is built"
        (( ${#files[@]} > 0 )) || continue
        while read -r ok rel drv; do
            [[ "${ok}" == "ok:" && "${drv}" == *.drv ]] || continue
            nix-store -q --requisites "${drv}" > "${work}/${side}/$(basename "${rel}" .nix).txt" 2>/dev/null || true
        done < <(bash "${TRAIN_SCRIPTS}/nixos-baseline-eval.sh" --src "${tree}" ${mode} --drv --nixpkgs "${src}" "${files[@]}" 2>&1)
    done
    python3 "${TRAIN_SCRIPTS}/release-images.py" --repo "${REPO_DIR}" --ref "${tag}" > "${work}/base-images.json" \
        && python3 "${TRAIN_SCRIPTS}/release-images.py" --repo "${REPO_DIR}" > "${work}/now-images.json" \
        || { rm -rf "${work}"; echo "the image pins could not be read" >&2; return 1; }
    info "  scanning the images of both sides by reference (the first run fetches them)"
    local hm="${HEALTH_MANAGER:-health-manager}"
    python3 "${TRAIN_SCRIPTS}/pin-preview.py" \
        --inventory "${sbom}/site.cdx.json" --status "${sbom}/cve-status.json" \
        --base-label "${tag}" --base-closures "${work}/base" --base-images "${work}/base-images.json" \
        --base-nix-scanner "${hm} scan nix-list --components {file} --nixpkgs ${base_src}" \
        --now-closures "${work}/now" --now-images "${work}/now-images.json" \
        --now-nix-scanner "${hm} scan nix-list --components {file} --nixpkgs ${now_src} --no-db-update" \
        --image-scanner "${hm} scan images --refs {file} --no-db-update" \
        --from "${from}" --to "$(jq -r '.nodes.nixpkgs.locked.rev // empty' "${dir}/flake.lock")" --out "${out}" \
        --ignore "${REPO_DIR}/release/pin-watch-ignore.json" ${4:+--details "$4"}
    local rc=$?
    rm -rf "${work}"
    return "${rc}"
}

# The gate items a preview found that no ack covers, one per line.
unacked() {   # $1 = a preview/findings json
    local ack; ack="$(jq -c '.ack.gate // []' "${STATE_FILE}" 2>/dev/null || echo '[]')"
    jq -r --argjson a "${ack:-[]}" '(.gate // []) - $a | .[]' "$1" 2>/dev/null
}

cmd_preview() {
    # One module from the last preview's details — nothing is recomputed.
    if [[ -n "${MODULE_SHOW}" ]]; then
        python3 "${TRAIN_SCRIPTS}/pin-preview.py" --show "${MODULE_SHOW}" --details "${DETAILS_PATH:-${DETAILS_FILE}}"
        return
    fi
    read_train
    local t from; t="$(mktemp -d)"
    cp "${REPO_DIR}/src/foundation/templates/flake.nix" "${REPO_DIR}/src/foundation/templates/flake.lock" "${t}/" \
        || die "no templates flake in ${REPO_DIR}"
    if [[ -n "${TO_BRANCH}" ]]; then
        sed -i.bak "s|github:NixOS/nixpkgs/[^\"]*\"|github:NixOS/nixpkgs/${TO_BRANCH}\"|" "${t}/flake.nix" && rm -f "${t}/flake.nix.bak"
    fi
    from="$(jq -r '.nodes.nixpkgs.locked.rev // empty' "${PIN_LOCK}")"
    info "${BOLD}Pin preview${CL} — what the next pin move would bring (#788). Nothing is built or moved."
    if [[ -z "${TAPPAAS_PIN_FINDINGS:-}" && "${NO_PIN_MOVE}" != "1" ]]; then
        ( cd "${t}" && nix flake update --extra-experimental-features "nix-command flakes" ) >/dev/null 2>&1 \
            || { rm -rf "${t}"; die "could not resolve the next pin${TO_BRANCH:+ on ${TO_BRANCH}}"; }
    fi
    if ! pin_findings "${t}" "${from}" "${PREVIEW_FILE}.tmp" "${DETAILS_PATH:-${DETAILS_FILE}}"; then
        rm -rf "${t}" "${PREVIEW_FILE}.tmp"; error "no preview"; return 1
    fi
    rm -rf "${t}"
    jq --arg at "$(iso_utc "$(now_epoch)")" --arg ref "${TO_BRANCH}" '. + {at: $at, toBranch: $ref}' \
        "${PREVIEW_FILE}.tmp" > "${PREVIEW_FILE}" && rm -f "${PREVIEW_FILE}.tmp"
    local open n; open="$(unacked "${PREVIEW_FILE}")"; n="$(grep -c . <<<"${open}")"
    echo
    if [[ "$(jq '.gate | length' "${PREVIEW_FILE}")" == "0" ]]; then
        info "  ${GN}✓${CL} nothing to acknowledge — the next boundary needs no ack for this pin"
    elif [[ -z "${open}" ]]; then
        info "  ${GN}✓${CL} all of it is acknowledged already ($(jq -r '.ack.at // "?"' "${STATE_FILE}"))"
    else
        info "  the next boundary stops before its deep test until ${n} item(s) are accepted: ${SCRIPT_NAME} ack --note \"<why>\""
    fi
    info "  one module, CVE by CVE: ${SCRIPT_NAME} preview --module <name>"
    info "  written: ${PREVIEW_FILE}, ${DETAILS_PATH:-${DETAILS_FILE}}"
}

cmd_ack() {
    [[ -s "${PREVIEW_FILE}" ]] || die "nothing to acknowledge — run: ${SCRIPT_NAME} preview"
    local n; n="$(jq '.gate | length' "${PREVIEW_FILE}")"
    [[ "${n}" != "0" ]] || { info "the last preview found nothing to acknowledge"; return 0; }
    [[ -f "${STATE_FILE}" ]] || echo '{}' > "${STATE_FILE}"
    local tmp="${STATE_FILE}.tmp.$$"
    jq --slurpfile p "${PREVIEW_FILE}" --arg at "$(iso_utc "$(now_epoch)")" --arg note "${NOTE}" \
        '.ack = {gate: $p[0].gate, digest: $p[0].digest, to: $p[0].to, at: $at, note: $note}' \
        "${STATE_FILE}" > "${tmp}" && mv -f "${tmp}" "${STATE_FILE}" || { rm -f "${tmp}"; die "could not write ${STATE_FILE}"; }
    info "${GN}✓${CL} acknowledged ${n} item(s) of the preview to ${BL}$(jq -r '.to[0:12]' "${PREVIEW_FILE}")${CL}:"
    jq -r '.gate[]' "${PREVIEW_FILE}" | sed 's/^/    /'
    info "  the next boundary goes ahead if the pin it takes brings nothing beyond these"
}

# The boundary plan's line for the pin gate (#788): what the last preview
# said, against the ack — the gate this run would meet after moving the pin.
preview_plan() {
    if [[ ! -s "${PREVIEW_FILE}" ]]; then
        info "       pin gate: no preview yet — ${SCRIPT_NAME} preview shows what the pin move would bring"
        return 0
    fi
    local open n; open="$(unacked "${PREVIEW_FILE}")"; n="$(jq '.gate | length' "${PREVIEW_FILE}")"
    if [[ "${n}" == "0" ]]; then
        info "       pin gate: the last preview ($(jq -r '.at // "?"' "${PREVIEW_FILE}")) found nothing to acknowledge"
    elif [[ -z "${open}" ]]; then
        info "       pin gate: the last preview's ${n} item(s) are all acknowledged — the gate would pass"
    else
        warn "       pin gate: the gate would STOP on $(wc -l <<<"${open}" | tr -d ' ') unacknowledged item(s) — ${SCRIPT_NAME} ack"
    fi
}

# The boundary's gate, before its deep test: the pin it just moved to, against
# the ack. rc 1 = stop. A gate that cannot judge says why and lets the deep test
# decide — it adds knowledge, it does not replace the proof.
pin_gate() {   # $1 = templates dir with the moved lock, $2 = from rev
    local f="${CONFIG_DIR}/train-preview-boundary.json" open
    info "  pin preview (#788): what this pin brings, before the deep test"
    if ! pin_findings "$1" "$2" "${f}"; then
        warn "  pin preview unavailable — the deep test still proves the pin"
        return 0
    fi
    if [[ "$(jq '.gate | length' "${f}")" == "0" ]]; then
        info "  ${GN}✓${CL} no major version change, no new critical/high CVE"
        return 0
    fi
    open="$(unacked "${f}")"
    if [[ -n "${open}" ]]; then
        error "  this pin brings what nobody has accepted:"
        while IFS= read -r l; do error "    ${l}"; done <<<"${open}"
        error "  stopped before the deep test. Read the upstream notes, then:"
        error "    ${SCRIPT_NAME} preview${TO_BRANCH:+ --to ${TO_BRANCH}}   (see it all)"
        error "    ${SCRIPT_NAME} ack --note \"<why>\"   and run the boundary again"
        return 1
    fi
    local tmp="${STATE_FILE}.tmp.$$"
    jq --slurpfile p "${f}" '.boundary = ((.boundary // {}) + {accepted: $p[0].gate})' \
        "${STATE_FILE}" > "${tmp}" && mv -f "${tmp}" "${STATE_FILE}" || rm -f "${tmp}"
    info "  ${GN}✓${CL} $(jq '.gate | length' "${f}") item(s), all acknowledged ($(jq -r '.ack.at // "?"' "${STATE_FILE}"))"
    return 0
}

# ── releases ─────────────────────────────────────────────────────────
# The history, from main — so any site with a fetch sees all of it, including
# the versions newer than the one it runs.
cmd_releases() {
    if [[ "${RENDER}" == "1" ]]; then
        [[ -f "${REPO_DIR}/${RELEASES_FILE}" ]] || die "no ${RELEASES_FILE} in ${REPO_DIR}"
        render_releases "${REPO_DIR}/${RELEASES_FILE}" > "${REPO_DIR}/${RELEASES_PAGE}" || die "could not render"
        info "  ${RELEASES_PAGE} rendered from ${RELEASES_FILE}"
        return 0
    fi
    read_train
    local data
    data="$(g show "origin/main:${RELEASES_FILE}")" || data="$(cat "${REPO_DIR}/${RELEASES_FILE}" 2>/dev/null)"
    if [[ -z "${data}" ]]; then warn "no release record yet (${RELEASES_FILE} on main)"; return 0; fi
    echo
    printf '  %-9s %-13s %-11s %-11s %s\n' VERSION COMMIT STAGING PRODUCTION NOTES
    jq -r "${JQ_NOTES}"' .releases[] | [.version, .commit, (.staging // "—"), (.production // "—"), notes] | @tsv' \
        <<<"${data}" | while IFS=$'\t' read -r v c st pr n; do
        printf '  %-9s %-13s %-11s %-11s %s\n' "${v}" "${c}" "${st}" "${pr}" "${n}"
    done
    echo
    info "  now: staging $(version_of origin/staging), production $(version_of origin/stable) — git checkout v<version> to run one"
    return 0
}

# The range must cover the whole header block above: extend it when the header
# grows, or --help quietly stops before its last line.
usage() { sed -n '3,54p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

command -v jq >/dev/null 2>&1 || die "jq is required"
NO_FETCH=0; DRY_RUN=0; RESUME=0; FORCE_BOUNDARY=0
# Cut the next MAJOR at this boundary (ADR-028 D13) — only ever the operator's word.
MAJOR=0
RENDER=0
# Why an urgent fix may skip the soak (ADR-028 D12) — required by `patch`.
WHY=""
# Where production lives. `stable` unless told otherwise: an alternative lets a
# promotion be rehearsed onto a throwaway ref without touching what sites run.
PROD_BRANCH="stable"
# The staging site, for phase 6. The train runs on the UNSTABLE site, which has
# no configured knowledge that the staging site exists — there is no cross-site
# registry — so the operator names it or phase 6 is skipped with a note.
STAGING_HOST=""
# The staging channel's ref. Overridable with --production-branch so a whole
# boundary can be rehearsed onto throwaway refs — redirecting only one of the
# two promotions would still move the real staging channel, which is not a
# rehearsal at all.
STAGING_BRANCH="staging"
# The guest that meets a new pin BEFORE the mothership does (ADR-028 D9). A
# guest that fails is snapshot-rolled back by update-module.sh; the control
# plane stays able to investigate. Default: any module that dependsOn
# templates:nixos — the reliable signal, since most guests declare no `os`.
GUEST=""
# A VERSION move: the nixpkgs release branch itself (e.g. nixos-26.05), as
# opposed to a patch refresh within the current one. ADR-028 D2 calls this the
# week where the diff is bigger, not a different rhythm — and D9 is explicit
# that the script never picks a branch on its own, so this is only ever an
# operator's word.
TO_BRANCH=""
# Why an acknowledgement was given (`ack --note`), recorded with it.
NOTE=""
# The release a preview compares with (default: the newest v* tag).
SINCE_TAG=""
# `preview --module <m>`: show one module from the details; `--details-file`: where they go.
MODULE_SHOW=""; DETAILS_PATH=""
# `preview --no-pin-move`: "now" is the pin already in the tree, not the next one.
NO_PIN_MOVE=0
# Run a boundary whose value is the PROOF rather than the move: the pin is
# already where it should be (landed by hand, or a frozen branch) and this run
# exists to put it through the guest, the sweep and the deep test.
ALLOW_NO_PIN_CHANGE=0
_args=()
for a in "$@"; do
    case "${a}" in
        --no-fetch)       NO_FETCH=1 ;;
        --dry-run)        DRY_RUN=1 ;;
        --resume)         RESUME=1 ;;
        --allow-no-pin-change) ALLOW_NO_PIN_CHANGE=1 ;;
        --force-boundary) FORCE_BOUNDARY=1 ;;
        --major)          MAJOR=1 ;;
        --render)         RENDER=1 ;;
        --why=*)          WHY="${a#*=}" ;;
        --note=*)         NOTE="${a#*=}" ;;
        --since=*)        SINCE_TAG="${a#*=}" ;;
        --module=*)       MODULE_SHOW="${a#*=}" ;;
        --no-pin-move)    NO_PIN_MOVE=1 ;;
        --details-file=*) DETAILS_PATH="${a#*=}" ;;
        --production-branch=*) PROD_BRANCH="${a#*=}" ;;
        --staging-branch=*)    STAGING_BRANCH="${a#*=}" ;;
        --staging-host=*)      STAGING_HOST="${a#*=}" ;;
        --guest=*)             GUEST="${a#*=}" ;;
        --to=*)                TO_BRANCH="${a#*=}" ;;
        --production-branch|--staging-branch|--staging-host|--guest|--to|--why|--note|--since|--module|--details-file) _want="${a}" ;;
        *)
            if [[ -n "${_want:-}" ]]; then
                case "${_want}" in
                    --production-branch) PROD_BRANCH="${a}" ;;
                    --staging-branch)    STAGING_BRANCH="${a}" ;;
                    --staging-host)      STAGING_HOST="${a}" ;;
                    --guest)             GUEST="${a}" ;;
                    --to)                TO_BRANCH="${a}" ;;
                    --why)               WHY="${a}" ;;
                    --note)              NOTE="${a}" ;;
                    --since)             SINCE_TAG="${a}" ;;
                    --module)            MODULE_SHOW="${a}" ;;
                    --details-file)      DETAILS_PATH="${a}" ;;
                esac
                _want=""
            else
                _args+=("${a}")
            fi ;;
    esac
done
[[ -z "${_want:-}" ]] || { echo "${_want} needs a value" >&2; exit 2; }
set -- ${_args[@]+"${_args[@]}"}

case "${1:-}" in
    status)   cmd_status ;;
    init)     cmd_init ;;
    boundary) cmd_boundary ;;
    fault)    shift; cmd_fault "$@" ;;
    patch)    shift; cmd_patch "$@" ;;
    releases) cmd_releases ;;
    preview)  cmd_preview ;;
    ack)      cmd_ack ;;
    -h|--help|help|"") usage ;;
    *) die "unknown command '${1}' (status | init | boundary | fault | patch | preview | ack | releases)" ;;
esac
