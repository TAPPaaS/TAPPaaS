#!/usr/bin/env bash
#
# user-setup.sh — bootstrap the minimal People domain
#
# Copies manager/people-manager/minimal-org/* into config/people/, substituting
# the placeholders __ORG__ / __USER__ / __EMAIL__ in BOTH filenames and file
# contents, then validates the result with validate-people.sh.
#
# This is a thin bootstrap: it has no entity-creation logic of its own and it
# does NOT push anything to Authentik (that is people-manager sync — step S2b).
#
# Result: 1 organization, groups <org>__admin + <org>__users, 1 installer user
#         (root role, member of <org>__admin), and the 3 default roles.
#
# Usage: user-setup.sh --org <slug> --user <slug> --email <email> [OPTIONS]
#
# Exit codes: 0 = success, 1 = error
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Logging — reuse the project's common-install-routines.sh when present
# ---------------------------------------------------------------------------
if ! declare -F info &>/dev/null; then
    if [[ -f /home/tappaas/bin/common-install-routines.sh ]]; then
        # shellcheck source=/dev/null
        . /home/tappaas/bin/common-install-routines.sh
    else
        : "${GN:=$'\033[1;92m'}"
        : "${RD:=$'\033[01;31m'}"
        : "${YW:=$'\033[33m'}"
        : "${DGN:=$'\033[32m'}"
        : "${CL:=$'\033[m'}"
        info()  { echo -e "${DGN}[Info]${CL} $*"; }
        debug() { :; }
        warn()  { echo -e "${YW}[Warning]${CL} $*"; }
        error() { echo -e "${RD}[Error]${CL} $*" >&2; }
        die()   { error "$*"; exit 1; }
    fi
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MINIMAL_ORG_DIR="${MINIMAL_ORG_DIR:-${HERE}/minimal-org}"
VALIDATE_SCRIPT="${HERE}/validate.sh"

# Defaults
ORG=""
USER_SLUG=""
EMAIL=""
PEOPLE_DIR="${TAPPAAS_CONFIG:-/home/tappaas/config}/people"
FORCE=false
SKIP_VALIDATE=false

usage() {
    cat << EOF
Usage: $(basename "$0") --org <slug> --user <slug> --email <email> [OPTIONS]

Bootstrap the minimal TAPPaaS People domain by copying minimal-org/ into
config/people/ with placeholders substituted.

Required:
    --org   <slug>           Organization name = the TAPPaaS installation name
    --user  <slug>           The installer's username
    --email <email>          The installer's primary email address

Options:
    -h, --help               Show this help message and exit
    --people-dir <path>      Destination People directory
                             (default: ${PEOPLE_DIR})
    --minimal-org <path>     Source minimal-org directory
                             (default: ${MINIMAL_ORG_DIR})
    --force                  Overwrite an existing non-empty destination
    --skip-validate          Skip running validate-people.sh on the result

Exit Codes:
    0    Success
    1    Error

Example:
    $(basename "$0") --org foobar-site --user lars --email lars@example.com
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --org)   [[ -n "${2:-}" ]] || die "--org requires an argument";   ORG="$2"; shift 2 ;;
            --user)  [[ -n "${2:-}" ]] || die "--user requires an argument";  USER_SLUG="$2"; shift 2 ;;
            --email) [[ -n "${2:-}" ]] || die "--email requires an argument"; EMAIL="$2"; shift 2 ;;
            --people-dir)  [[ -n "${2:-}" ]] || die "--people-dir requires an argument";  PEOPLE_DIR="$2"; shift 2 ;;
            --minimal-org) [[ -n "${2:-}" ]] || die "--minimal-org requires an argument"; MINIMAL_ORG_DIR="$2"; shift 2 ;;
            --force) FORCE=true; shift ;;
            --skip-validate) SKIP_VALIDATE=true; shift ;;
            *) die "Unknown option: $1. Use --help for usage." ;;
        esac
    done
}

validate_args() {
    [[ -n "$ORG" ]]       || die "--org is required. Use --help for usage."
    [[ -n "$USER_SLUG" ]] || die "--user is required. Use --help for usage."
    [[ -n "$EMAIL" ]]     || die "--email is required. Use --help for usage."

    [[ "$ORG"       =~ ^[A-Za-z0-9_-]+$ ]] || die "--org '${ORG}' is not a valid slug ([A-Za-z0-9_-]+)"
    [[ "$USER_SLUG" =~ ^[A-Za-z0-9_-]+$ ]] || die "--user '${USER_SLUG}' is not a valid slug ([A-Za-z0-9_-]+)"
    [[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || \
        die "--email '${EMAIL}' is not a valid email address"

    [[ -d "$MINIMAL_ORG_DIR" ]] || die "minimal-org directory not found: ${MINIMAL_ORG_DIR}"
}

# ---------------------------------------------------------------------------
# Cleanup trap — remove a staging dir if we leave early
# ---------------------------------------------------------------------------
STAGE_DIR=""
cleanup() {
    [[ -n "$STAGE_DIR" && -d "$STAGE_DIR" ]] && rm -rf -- "$STAGE_DIR"
    return 0
}
trap cleanup EXIT INT TERM

# substitute placeholders in a string (used for both paths and contents)
subst() {
    local s="$1"
    s="${s//__ORG__/$ORG}"
    s="${s//__USER__/$USER_SLUG}"
    s="${s//__EMAIL__/$EMAIL}"
    printf '%s' "$s"
}

main() {
    parse_args "$@"
    validate_args

    info "Bootstrapping People domain"
    info "  org   = ${ORG}"
    info "  user  = ${USER_SLUG}"
    info "  email = ${EMAIL}"
    info "  from  = ${MINIMAL_ORG_DIR}"
    info "  to    = ${PEOPLE_DIR}"

    # Guard: refuse to clobber a non-empty destination unless --force
    if [[ -d "$PEOPLE_DIR" ]] && [[ -n "$(ls -A "$PEOPLE_DIR" 2>/dev/null)" ]]; then
        if [[ "$FORCE" != "true" ]]; then
            die "Destination ${PEOPLE_DIR} already exists and is not empty (use --force to overwrite)"
        fi
        warn "Destination is non-empty; --force given, overwriting"
    fi

    # Stage into a temp dir, then move into place atomically-ish
    STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/user-setup.XXXXXX")"

    local src rel dst dstdir
    while IFS= read -r -d '' src; do
        rel="${src#"$MINIMAL_ORG_DIR"/}"
        rel="$(subst "$rel")"
        dst="${STAGE_DIR}/${rel}"
        dstdir="$(dirname "$dst")"
        mkdir -p "$dstdir"
        # substitute contents
        subst "$(cat "$src")" > "$dst"
        debug "  staged ${rel}"
    done < <(find "$MINIMAL_ORG_DIR" -type f -name '*.json' -print0)

    # Move staged tree into the destination
    mkdir -p "$PEOPLE_DIR"
    cp -a "${STAGE_DIR}/." "$PEOPLE_DIR/"

    info "Copied minimal-org into ${PEOPLE_DIR}"

    # Validate the result
    if [[ "$SKIP_VALIDATE" != "true" ]]; then
        if [[ -x "$VALIDATE_SCRIPT" ]]; then
            info "Validating result with $(basename "$VALIDATE_SCRIPT")"
            "$VALIDATE_SCRIPT" "$PEOPLE_DIR"
        else
            warn "validate script not executable: ${VALIDATE_SCRIPT} — skipping validation"
        fi
    fi

    info "${GN:-}People bootstrap complete${CL:-}"
}

main "$@"
