#!/usr/bin/env bash
#
# validate-module-tier-source.sh — the classification lint: scope/source
# (ADR-007b, ADR-022e), and what a module's maturity claim means (#248). The file
# keeps its historical name; `tier` itself is retired (#676).
#
# Validates a module JSON file's classification:
#   - scope    DERIVED from `stack` (ADR-022e v1.1): the foundation stack is
#              site-scoped, anything else environment-scoped. A module with no
#              `stack` is warned about (it falls back to a retired `tier` for one
#              release, else to environment).
#   - `tier`   retired: its presence is warned about, and a `tier` that
#              contradicts the stack is named as ignored.
#   - `source` (optional, default 'official') must be one of:
#                official | community | private | local
#   - LINT RULE: a site-scoped module REQUIRES source:official — one from any
#                non-official source is rejected unless --allow-fork is given
#                (the documented escape hatch for a foundation fork).
#   - WARN: source:community emits a non-fatal warning (peer-reviewed, not
#           officially supported) so install can surface it to the operator.
#
# and its maturity claim (#248), which a community user reads to judge whether a
# module is worth installing:
#   - `status`  must be a MATURITY: Development | Testing | Production | Deprecated.
#               `archived` and `external` are states of a DEPLOYED config, not
#               maturities a module may claim — in a released module they are an
#               error (ADR-022g moves them to `management`).
#   - `version` should be SemVer (x.y.z; warned, not refused — modules written
#               before this rule use two parts). Below 1.0.0 says pre-stable,
#               which is what "author-tested only" means; 1.0.0 is the claim
#               that someone other than the author has run it.
#   - WARN when the two contradict: 1.0.0+ while still Development, or
#     Production below 1.0.0. Which is wrong is the author's to decide, so this
#     never fails.
#
# Used standalone (operator/CI lint) and by install-module.sh at install time.
#
# Usage: validate-module-tier-source.sh [OPTIONS] <module.json>
#
# Arguments:
#   module.json          path to a module configuration JSON file
#
# Options:
#   --allow-fork         permit a site-scoped module with a non-official source
#                        (foundation fork override — ADR-007b)
#   --quiet              only output errors/warnings
#   -h, --help           show this help and exit
#
# Exit codes: 0 = passes the lint (warnings allowed); 1 = lint failure.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Logging — reuse common-install-routines.sh when present, else minimal stubs.
# ---------------------------------------------------------------------------
if ! declare -F info >/dev/null 2>&1; then
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

command -v jq >/dev/null 2>&1 || die "jq is required but not installed."

# module_scope_of (ADR-022e) lives in the side-effect-free catalog library;
# common-install-routines.sh sources it, but the stub path above does not.
if ! declare -F module_scope_of >/dev/null 2>&1; then
    for _mcl in ${TAPPAAS_CATALOG_LIB:-} /home/tappaas/bin/module-catalog-lib.sh \
                "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../lib/module-catalog-lib.sh"; do
        # An older copy (loaded already, or without the function) must not end
        # the search: clear its double-source guard and try the next one.
        [[ -r "${_mcl}" ]] || continue
        unset _MODULE_CATALOG_LIB_LOADED
        # shellcheck source=/dev/null
        . "${_mcl}"
        declare -F module_scope_of >/dev/null 2>&1 && break
    done
    unset _mcl
fi
declare -F module_scope_of >/dev/null 2>&1 || die "module-catalog-lib.sh not found (module_scope_of)"

# Resolve the REAL script path (it is symlinked into /home/tappaas/bin), in case
# a future need arises to locate a sibling schema. readlink -f follows the link.
_SELF="$(readlink -f "${BASH_SOURCE[0]}")"
readonly _SELF

ALLOW_FORK=false
QUIET=false
TARGET=""
ERRORS=0
WARNINGS=0

readonly VALID_SOURCES="official community private local"
# #248: what a module may claim about itself. Deployment states are not here.
readonly VALID_STATUSES="Development Testing Production Deprecated"
readonly DEPLOYED_STATUSES="archived external"

usage() {
    sed -n '2,49p' "$_SELF" | sed 's/^# \{0,1\}//'
}

log_info() { [[ "$QUIET" == "false" ]] && info "$@" || true; }
lint_error() { error "SCOPE/SOURCE: $*"; ERRORS=$((ERRORS + 1)); }
lint_warn()  { warn  "SCOPE/SOURCE: $*"; WARNINGS=$((WARNINGS + 1)); }

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)    usage; exit 0 ;;
            --allow-fork) ALLOW_FORK=true; shift ;;
            --quiet)      QUIET=true; shift ;;
            -*)           die "Unknown option: $1. Use --help for usage." ;;
            *)
                [[ -z "$TARGET" ]] || die "Unexpected argument: $1 (target already '$TARGET')"
                TARGET="$1"; shift ;;
        esac
    done
}

in_set() {
    # $1 = value, $2 = space-separated set
    local v="$1" s="$2" item
    for item in $s; do
        [[ "$v" == "$item" ]] && return 0
    done
    return 1
}

main() {
    parse_args "$@"

    [[ -n "$TARGET" ]] || { error "A module JSON file is required."; usage; exit 1; }
    [[ -f "$TARGET" ]] || die "Module JSON not found: ${TARGET}"
    jq empty "$TARGET" >/dev/null 2>&1 || die "Not valid JSON: ${TARGET}"

    local base
    base="$(basename "$TARGET")"
    log_info "Linting scope/source: ${TARGET}"

    local stack tier scope source
    stack="$(jq -r '.stack // empty' "$TARGET")"
    tier="$(jq -r '.tier // empty' "$TARGET")"
    scope="$(module_scope_of "$TARGET")"
    # source defaults to 'official' when absent (CR-05: normally inferred).
    source="$(jq -r '.source // "official"' "$TARGET")"

    # Scope follows the stack (ADR-022e v1.1). Warnings only: a module without a
    # stack still installs, environment-scoped, and `tier` is read for one more
    # release so a module JSON that has not dropped it still installs as before.
    if [[ -z "$stack" ]]; then
        lint_warn "${base}: no 'stack' — installs as ${scope}-scoped; a module states its stack (#463), and the foundation stack is what makes it site-scoped"
    fi
    if [[ -n "$tier" ]]; then
        local tier_says="environment"
        [[ "$tier" == "foundation" ]] && tier_says="site"
        if [[ -n "$stack" && "$tier_says" != "$scope" ]]; then
            lint_warn "${base}: 'tier: ${tier}' is ignored — scope follows the stack, and stack '${stack}' is ${scope}-scoped (ADR-022e)"
        else
            lint_warn "${base}: 'tier' is retired (ADR-022e, #676) — scope follows the stack; remove it"
        fi
    fi

    # source enum check (the defaulted value is always valid, so this only fires
    # on an explicit out-of-range value).
    if ! in_set "$source" "$VALID_SOURCES"; then
        lint_error "${base}: invalid source '${source}' (must be one of: ${VALID_SOURCES})"
    fi

    # LINT RULE: a site-scoped module requires source:official (unless --allow-fork).
    if [[ "$scope" == "site" && "$source" != "official" ]]; then
        if [[ "$ALLOW_FORK" == "true" ]]; then
            lint_warn "${base}: site-scoped (stack foundation) with source:'${source}' permitted by --allow-fork (foundation fork)"
        else
            lint_error "${base}: site-scoped (stack foundation) requires source:official (got '${source}'). Pass --allow-fork to permit a foundation fork."
        fi
    fi

    # community modules are valid but unsupported — surface a warning.
    if [[ "$source" == "community" ]]; then
        lint_warn "${base}: source:community — peer-reviewed but not officially supported (🟡)"
    fi

    # ── maturity: status + version (#248) ────────────────────────────────
    local status version major
    status="$(jq -r '.status // empty' "$TARGET")"
    version="$(jq -r '.version // empty' "$TARGET")"

    if [[ -z "$status" ]]; then
        lint_warn "${base}: no 'status' — a module says how far it has got: ${VALID_STATUSES// /, }"
    elif in_set "$status" "$DEPLOYED_STATUSES"; then
        lint_error "${base}: status '${status}' is a state of a DEPLOYED config, not a maturity a module claims (use ${VALID_STATUSES// /, })"
    elif ! in_set "$status" "$VALID_STATUSES"; then
        lint_error "${base}: invalid status '${status}' (must be one of: ${VALID_STATUSES})"
    fi

    if [[ -z "$version" ]]; then
        lint_warn "${base}: no 'version' — start at 0.1.0 (pre-stable until someone else has run it)"
    elif [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # A warning, not an error: two-part versions are all over the modules
        # written before this rule, and refusing to install them would punish
        # the user for the author's typo.
        lint_warn "${base}: version '${version}' is not SemVer x.y.z (0.5 is 0.5.0)"
    else
        major="${version%%.*}"
        if [[ "$major" -ge 1 && "$status" == "Development" ]]; then
            lint_warn "${base}: version ${version} claims stable while status is Development — one of the two is wrong"
        elif [[ "$major" -lt 1 && "$status" == "Production" ]]; then
            lint_warn "${base}: status Production below 1.0.0 — a validated module has earned 1.0.0"
        fi
    fi

    if [[ $ERRORS -gt 0 ]]; then
        error "classification lint failed: $ERRORS error(s), $WARNINGS warning(s)"
        exit 1
    fi
    log_info "${GN:-}classification lint passed (scope=${scope}, source=${source}, status=${status:-unset}, version=${version:-unset}, ${WARNINGS} warning(s))${CL:-}"
    exit 0
}

main "$@"
