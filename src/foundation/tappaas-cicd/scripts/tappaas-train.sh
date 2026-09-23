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
#   tappaas-train fault <what>             record a staging fault; blocks the next promotion
#   tappaas-train fault --resolved <commit>  clear it — the commit must be on main
#
# Phases 1-2 of a boundary (move the pin, prove it on this site) stay the
# operator's own cycle: they run a sweep and a deep test that take hours and
# want a human watching. What this automates is the part that must NOT be done
# by hand — the promotions, in the right order, fast-forward only, with the
# soak and the fault rule enforced. See docs/design/release-train-promotion.md.
#
# NOT `site-manager repository release` — that verb means "release a pull HOLD"
# (#653). Two unrelated operations must not share a name in the one place an
# operator reaches under time pressure.
#
# Exit: 0 sound (or reported) · 1 the train is not promotable · 2 usage
#
# Environment (tests): TAPPAAS_CONFIG_DIR, TAPPAAS_REPO_DIR, TAPPAAS_TRAIN_NOW

set -uo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
CONFIG_DIR="${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}"
REPO_DIR="${TAPPAAS_REPO_DIR:-/home/tappaas/TAPPaaS}"
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
    if ! g merge-base --is-ancestor origin/stable origin/staging; then
        ANCESTRY_OK=0
        ANCESTRY_WHY="stable is not an ancestor of staging — something was pushed to stable directly"
    elif ! g merge-base --is-ancestor origin/staging origin/main; then
        ANCESTRY_OK=0
        ANCESTRY_WHY="staging is not an ancestor of main — staging has commits main does not"
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
    info "  1  branch pin/$(date -u +%Y-w%V), refresh the estate pin"
    info "  2  prove it here: one guest first, then the sweep, then --deep"
    info "  3  land on main"
    info "  4  promote staging → stable   ($(g rev-list --count origin/stable..origin/staging) commits reach production)"
    info "  5  promote main → staging"
    info "  6  verify the staging site"
    if [[ "${DRY_RUN}" == "1" ]]; then
        echo; info "Dry run: nothing was changed."
        return 0
    fi

    # Phases 1-2 (the pin move and proving it here) are the operator's own
    # cycle and are deliberately NOT automated yet: they run a sweep and a deep
    # test that take hours and want a human watching. The boundary drives the
    # promotion, which is the part that must not be done by hand.
    warn "  phases 1-2 are not automated: move the pin and prove it here, then re-run with --resume"
    if phase_pending "prove"; then
        error "Refusing to promote what this site has not proved."
        error "  nix flake update --flake ${REPO_DIR}/src/foundation/templates"
        error "  ...test it, land it on main, then: ${SCRIPT_NAME} boundary --resume"
        return 1
    fi

    info "${BOLD}Promoting${CL}"
    phase_pending "stable"  && { promote_ref staging stable  || return 1; phase_done "stable"; }
    phase_pending "staging" && { promote_ref main    staging || return 1; phase_done "staging"; }

    # The clock restarts from the promotion, not from when someone remembered.
    local tmp="${STATE_FILE}.tmp.$$"
    jq --argjson now "$(now_epoch)" --arg forced "${forced}" \
       '.soakStartedAt = $now
        | .channels = {unstable: "'"$(g rev-parse --short origin/main)"'",
                       staging: "'"$(g rev-parse --short origin/staging)"'",
                       production: "'"$(g rev-parse --short origin/stable)"'"}
        | .lastBoundary = {at: $now, forced: ($forced == "1")}
        | .boundary = null' "${STATE_FILE}" > "${tmp}" && mv -f "${tmp}" "${STATE_FILE}" || rm -f "${tmp}"

    echo
    info "${GN}Boundary complete.${CL} The next one is due in ${BOUNDARY_DAYS} days."
    info "  Verify the staging site now: it is the only thing that can find what this promoted."
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
_args=()
for a in "$@"; do
    case "${a}" in
        --no-fetch)       NO_FETCH=1 ;;
        --dry-run)        DRY_RUN=1 ;;
        --resume)         RESUME=1 ;;
        --force-boundary) FORCE_BOUNDARY=1 ;;
        *) _args+=("${a}") ;;
    esac
done
set -- ${_args[@]+"${_args[@]}"}

case "${1:-}" in
    status)   cmd_status ;;
    init)     cmd_init ;;
    boundary) cmd_boundary ;;
    fault)    shift; cmd_fault "$@" ;;
    -h|--help|help|"") usage ;;
    *) die "unknown command '${1}' (status | init | boundary | fault)" ;;
esac
