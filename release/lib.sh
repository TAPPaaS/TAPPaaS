#!/usr/bin/env bash
#
# release/lib.sh — shared helpers for the TAPPaaS release scripts.
#
# Sourced by changelog.sh, bump-version.sh and make-release.sh. These scripts
# run from a developer/maintainer checkout (this Mac), NOT the mothership, so
# this lib is deliberately self-contained — it does not depend on
# /home/tappaas/bin/common-install-routines.sh. The logging style mirrors it.
#
# Not meant to be executed directly.

# ── Colors (guarded so callers/env can override) ─────────────────────
[[ -z "${RD:-}" ]]   && RD=$'\033[01;31m'
[[ -z "${YW:-}" ]]   && YW=$'\033[33m'
[[ -z "${GN:-}" ]]   && GN=$'\033[1;92m'
[[ -z "${DGN:-}" ]]  && DGN=$'\033[32m'
[[ -z "${BL:-}" ]]   && BL=$'\033[36m'
[[ -z "${CL:-}" ]]   && CL=$'\033[m'
[[ -z "${BOLD:-}" ]] && BOLD=$'\033[1m'

[[ -z "${OPT_DEBUG:-}" ]] && OPT_DEBUG="${TAPPAAS_DEBUG:-0}"

# ── Logging ──────────────────────────────────────────────────────────
info()  { echo -e "${DGN}[Info]${CL} $*"; }
step()  { echo -e "\n${GN}${BOLD}==>${CL} ${BOLD}$*${CL}"; }
warn()  { echo -e "${YW}[Warning]${CL} $*" >&2; }
error() { echo -e "${RD}[Error]${CL} $*" >&2; }
debug() { [[ "${OPT_DEBUG}" -eq 1 ]] && echo -e "${BL}[Debug]${CL} $*" >&2; return 0; }
die()   { error "$@"; exit 1; }

# ── Helpers ──────────────────────────────────────────────────────────

# require_cmd <cmd> [hint] — die unless the command is on PATH.
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' not found${2:+ — $2}"
}

# repo_root — print the git top-level dir, or die if not in a repo.
repo_root() {
    git rev-parse --show-toplevel 2>/dev/null || die "not inside a git repository"
}

# confirm <prompt> — yes/no gate. Returns 0 on yes. Honours AUTO_YES=1 (--yes)
# and DRY_RUN=1 (auto-yes so a dry run walks the whole flow without stopping).
confirm() {
    if [[ "${AUTO_YES:-0}" -eq 1 || "${DRY_RUN:-0}" -eq 1 ]]; then
        info "$1 ${DGN}[auto-yes]${CL}"
        return 0
    fi
    local reply
    read -r -p "$(echo -e "${YW}?${CL} $1 [y/N] ")" reply
    [[ "${reply}" =~ ^[Yy]$ ]]
}

# run <cmd...> — echo the command; execute it unless DRY_RUN=1.
run() {
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        echo -e "  ${BL}[dry-run]${CL} $*"
        return 0
    fi
    echo -e "  ${BL}+${CL} $*"
    "$@"
}
