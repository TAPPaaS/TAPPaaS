#!/usr/bin/env bash
#
# tappaas-train.sh — the release train (ADR-028 D9).
#
# Three channels on two-week boundaries: what a site RUNS is its channel
# (unstable | staging | production); where the code SITS is a branch
# (main | staging | stable). Promotion is fast-forward only, in one direction.
#
#   tappaas-train status [--no-fetch]   where each channel points, and what blocks a boundary
#   tappaas-train init            verify the train is in a promotable state; start the clock
#
# `boundary` and `fault` are designed in docs/design/release-train-promotion.md
# and not implemented yet — this is the read-only half, deliberately first: it
# answers "is the train sound?" without touching anything, and it is what the
# write half will consult.
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

usage() { sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

command -v jq >/dev/null 2>&1 || die "jq is required"
NO_FETCH=0
_args=()
for a in "$@"; do
    case "${a}" in
        --no-fetch) NO_FETCH=1 ;;
        *) _args+=("${a}") ;;
    esac
done
set -- ${_args[@]+"${_args[@]}"}

case "${1:-}" in
    status) cmd_status ;;
    init)   cmd_init ;;
    -h|--help|help|"") usage ;;
    boundary|fault) die "'$1' is designed but not implemented yet — see docs/design/release-train-promotion.md" ;;
    *) die "unknown command '$1' (status | init)" ;;
esac
