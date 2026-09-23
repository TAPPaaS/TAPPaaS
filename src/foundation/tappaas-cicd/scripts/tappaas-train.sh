#!/usr/bin/env bash
#
# tappaas-train.sh — the release train (ADR-028 D9).
#
# Three channels on two-week boundaries: what a site RUNS is its channel
# (unstable | staging | production); where the code SITS is a branch
# (main | staging | stable). Promotion is fast-forward only, in one direction.
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
#   tappaas-train fault <what>             record a staging fault; blocks the next promotion
#   tappaas-train fault --resolved <commit>  clear it — the commit must be on main
#
# One boundary is one command: move the pin, prove it here, land it on main,
# then promote. Phases 1-2 take hours (a sweep that reboots nodes, then a deep
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
SITE_FILE="${CONFIG_DIR}/site.json"
STATE_FILE="${CONFIG_DIR}/release-train.json"
# The boundary interval (ADR-028 D2). Policy, so it is named once.
BOUNDARY_DAYS="${TAPPAAS_BOUNDARY_DAYS:-14}"

YW=$'\033[33m'; RD=$'\033[01;31m'; GN=$'\033[1;92m'; BL=$'\033[36m'; CL=$'\033[m'; BOLD=$'\033[1m'
info()  { echo -e "${GN}[Info]${CL} $*"; }
warn()  { echo -e "${YW}[Warning]${CL} $*"; }
error() { echo -e "${RD}[Error]${CL} $*" >&2; }
die()   { error "$*"; exit 2; }

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
        g fetch --quiet origin main staging stable || \
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

soak_started() { jq -r '.soakStartedAt // empty' "${STATE_FILE}" 2>/dev/null; }

# ── status ───────────────────────────────────────────────────────────
cmd_status() {
    read_train
    check_ancestry

    echo
    info "${BOLD}Release train — ${SITE_NAME}${CL}"
    printf '  %-12s %-9s %-10s %s\n' CHANNEL BRANCH COMMIT "DISTANCE"
    printf '  %-12s %-9s %-10s %s\n' unstable   main    "${REF_MAIN}"    "—"
    printf '  %-12s %-9s %-10s %s\n' staging    staging "${REF_STAGING}" \
        "$(g rev-list --count origin/staging..origin/main) behind main"
    printf '  %-12s %-9s %-10s %s\n' production stable  "${REF_STABLE}" \
        "$(g rev-list --count origin/stable..origin/staging) behind staging"
    echo

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
        info "  soak clock already running since $(date -u -d "@${started}" +%Y-%m-%d 2>/dev/null || date -u -r "${started}" +%Y-%m-%d)"
        return 0
    fi
    local now; now="$(now_epoch)"
    local tmp="${STATE_FILE}.tmp.$$"
    jq -n --argjson now "${now}" --arg main "${REF_MAIN}" --arg staging "${REF_STAGING}" \
          --arg stable "${REF_STABLE}" --arg pin "${PIN_REV}" '{
            soakStartedAt: $now,
            channels: { unstable: $main, staging: $staging, production: $stable },
            pin: $pin,
            fault: null
          }' > "${tmp}" && mv -f "${tmp}" "${STATE_FILE}" \
        || { rm -f "${tmp}"; error "could not write ${STATE_FILE}"; return 1; }
    info "  ${GN}✓${CL} soak clock started — a boundary becomes due in ${BOUNDARY_DAYS} days"
    return 0
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
    [[ "${DRY_RUN}" == "1" ]] && { info "  (dry run) would branch ${br} and update ${PIN_LOCK##*/}"; return 0; }

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
        info "  a frozen branch cannot refresh. Move the release instead: --to <nixos-XX.YY>"
        abandon_phase_branch "${br}"
        return 1
    fi
    info "  pin ${before:0:12} → ${after:0:12}"
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
    g push -q origin "${br}" \
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

cmd_boundary() {
    preflight
    echo
    info "${BOLD}Boundary preflight${CL}"
    report_preflight
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
    info "  2  prove it here: $(pick_guest 2>/dev/null || echo "a guest") first, then the sweep, then --deep"
    info "  3  land on main (hours: the sweep reboots nodes, the deep test builds guests)"
    info "  4  promote ${STAGING_BRANCH} → ${PROD_BRANCH}   ($(g rev-list --count "origin/${PROD_BRANCH}..origin/staging" 2>/dev/null || echo "?") commits reach production)"
    info "  5  promote main → ${STAGING_BRANCH}"
    info "  6  verify the staging site"
    if [[ "${DRY_RUN}" == "1" ]]; then
        echo; info "Dry run: nothing was changed."
        return 0
    fi

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
    phase_pending "staging" && { promote_ref main "${STAGING_BRANCH}" || return 1; phase_done "staging"; }

    # The clock restarts from the promotion, not from when someone remembered.
    local tmp="${STATE_FILE}.tmp.$$"
    jq --argjson now "$(now_epoch)" --arg forced "${forced}" \
       '.soakStartedAt = $now
        | .channels = {unstable: "'"$(g rev-parse --short origin/main)"'",
                       staging: "'"$(g rev-parse --short "origin/${STAGING_BRANCH}" 2>/dev/null)"'",
                       production: "'"$(g rev-parse --short "origin/${PROD_BRANCH}" 2>/dev/null)"'"}
        | .lastBoundary = {at: $now, forced: ($forced == "1")}
        | .pin = "'"$(jq -r '.nodes.nixpkgs.locked.rev // empty' "${PIN_LOCK}" 2>/dev/null)"'"
        | .boundary = null' "${STATE_FILE}" > "${tmp}" && mv -f "${tmp}" "${STATE_FILE}" || rm -f "${tmp}"

    echo
    info "${GN}Boundary complete.${CL} The next one is due in ${BOUNDARY_DAYS} days."

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
        if ! g merge-base --is-ancestor "${commit}" origin/main; then
            error "${commit} is not on main."
            error "  A fix that lives only on staging is reintroduced by the next boundary,"
            error "  which promotes main into staging. Land it on main first."
            return 1
        fi
        local tmp="${STATE_FILE}.tmp.$$"
        jq --arg c "${commit}" --argjson now "$(now_epoch)" \
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
    jq --arg w "${what}" --argjson now "$(now_epoch)" \
       '.fault = {what: $w, at: $now}' "${STATE_FILE}" > "${tmp}" \
        && mv -f "${tmp}" "${STATE_FILE}" || { rm -f "${tmp}"; die "could not update ${STATE_FILE}"; }
    warn "  Fault recorded. Promotion to production is BLOCKED until it is resolved on main."
    info "  Staging keeps the revision; production keeps what it has (ADR-028 D9)."
    info "  When the fix is on main: ${SCRIPT_NAME} fault --resolved <commit>"
    return 0
}

usage() { sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

command -v jq >/dev/null 2>&1 || die "jq is required"
NO_FETCH=0; DRY_RUN=0; RESUME=0; FORCE_BOUNDARY=0
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
_args=()
for a in "$@"; do
    case "${a}" in
        --no-fetch)       NO_FETCH=1 ;;
        --dry-run)        DRY_RUN=1 ;;
        --resume)         RESUME=1 ;;
        --force-boundary) FORCE_BOUNDARY=1 ;;
        --production-branch=*) PROD_BRANCH="${a#*=}" ;;
        --staging-branch=*)    STAGING_BRANCH="${a#*=}" ;;
        --staging-host=*)      STAGING_HOST="${a#*=}" ;;
        --guest=*)             GUEST="${a#*=}" ;;
        --to=*)                TO_BRANCH="${a#*=}" ;;
        --production-branch|--staging-branch|--staging-host|--guest|--to) _want="${a}" ;;
        *)
            if [[ -n "${_want:-}" ]]; then
                case "${_want}" in
                    --production-branch) PROD_BRANCH="${a}" ;;
                    --staging-branch)    STAGING_BRANCH="${a}" ;;
                    --staging-host)      STAGING_HOST="${a}" ;;
                    --guest)             GUEST="${a}" ;;
                    --to)                TO_BRANCH="${a}" ;;
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
    -h|--help|help|"") usage ;;
    *) die "unknown command '${1}' (status | init | boundary | fault)" ;;
esac
