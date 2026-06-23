#!/usr/bin/env bash
#
# create-minimal-environments.sh — bootstrap the two always-required environments (ADR-007 P3/P6/P7)
#
# Every TAPPaaS system requires two environments:
#   - mgmt.json    : the management environment (foundation modules, internal DNS
#                    only). network.zone = mgmt, NO domains.
#   - <N>.json     : the DEFAULT tenant environment, named after the TAPPaaS
#                    system name <N> (ADR-007 S6 topology: the system name <N> =
#                    site.json.name = the default-zone name = the default-environment
#                    name). network.zone = <N>. A domain is added if --domain is
#                    given, else omitted (an operator adds it later).
#
# This script is the SINGLE OWNER of these two files (sibling of P1's
# user-setup.sh). P6/P7 reference them, they do NOT re-author them.
#
# Note: older systems may carry a literal "default.json" produced by an earlier
# version of this script. We never delete an operator file — if a stale
# default.json exists it is left in place and noted, while the system-named
# <N>.json is the file this script emits and prefers.
#
# Idempotent: an existing environment file is left untouched unless --force.
#
# Usage: create-minimal-environments.sh [OPTIONS]
#
# Options:
#   --name <N>         TAPPaaS system name (= default zone & default env name).
#                      If omitted: derived from site.json '.name', else an error.
#   --domain <D>       public domain for the default (<N>) environment's
#                      domains.primary. If omitted the default env is created with
#                      no domain (internal only; set it later via environment-manager).
#   --config-dir DIR   config directory (default: ${TAPPAAS_CONFIG:-/home/tappaas/config})
#   --out-dir DIR      output environments dir (default: <config-dir>/environments)
#   --force            overwrite existing mgmt.json / <N>.json
#   -h, --help         show this help and exit
#
# Exit codes: 0 = success or no-op; 1 = error.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Logging — reuse common-install-routines.sh when present
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

_SELF="$(readlink -f "${BASH_SOURCE[0]}")"

CONFIG_DIR="${TAPPAAS_CONFIG:-/home/tappaas/config}"
OUT_DIR=""
NAME=""
DOMAIN_OVERRIDE=""
FORCE=false

usage() {
    sed -n '2,38p' "$_SELF" | sed 's/^# \{0,1\}//'
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --name)
                [[ -n "${2:-}" ]] || die "--name requires a value"
                NAME="$2"; shift 2 ;;
            --domain)
                [[ -n "${2:-}" ]] || die "--domain requires a value"
                DOMAIN_OVERRIDE="$2"; shift 2 ;;
            --config-dir)
                [[ -n "${2:-}" ]] || die "--config-dir requires a path argument"
                CONFIG_DIR="$2"; shift 2 ;;
            --out-dir)
                [[ -n "${2:-}" ]] || die "--out-dir requires a path argument"
                OUT_DIR="$2"; shift 2 ;;
            --force) FORCE=true; shift ;;
            -*) die "Unknown option: $1. Use --help for usage." ;;
            *)  die "Unexpected argument: $1. Use --help for usage." ;;
        esac
    done
}

# First organization slug under config/people/organizations/ (sorted), else "".
site_owner() {
    local orgdir="${CONFIG_DIR}/people/organizations" f base
    [[ -d "$orgdir" ]] || return 0
    for f in "$orgdir"/*.json; do
        [[ -e "$f" ]] || continue
        base="$(basename "$f" .json)"
        printf '%s\n' "$base"
    done | LC_ALL=C sort | head -1
}

# Resolve the TAPPaaS system name <N>:
#   1. explicit --name
#   2. site.json '.name'
# Echoes the name, or returns 1 (with no output) when none is derivable.
resolve_name() {
    if [[ -n "$NAME" ]]; then
        printf '%s\n' "$NAME"; return 0
    fi

    local site="${CONFIG_DIR}/site.json" n
    if [[ -f "$site" ]]; then
        n="$(jq -r '.name // empty' "$site" 2>/dev/null)"
        if [[ -n "$n" ]]; then printf '%s\n' "$n"; return 0; fi
    fi

    return 1
}

# Domain (if derivable) for the default environment, else "".
# site.json deliberately carries NO site-wide domain (ADR-007d) — domains are
# per-environment — and the legacy configuration.json variant registry is
# retired (ADR-007 Phase D). The only source is the --domain override.
default_domain() {
    printf '%s\n' ""
}

# Write a JSON document atomically to $1 unless it exists (and not --force).
# $2 = the JSON content. Returns 0 (written) or 1 (skipped).
write_if_absent() {
    local out="$1" content="$2"
    if [[ -f "$out" && "$FORCE" != "true" ]]; then
        info "$(basename "$out") already exists — leaving it untouched (use --force to overwrite)."
        return 1
    fi
    local tmp
    tmp="$(mktemp "${out}.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '${tmp}'" EXIT INT TERM
    printf '%s\n' "$content" > "$tmp"
    mv "$tmp" "$out"
    trap - EXIT INT TERM
    return 0
}

main() {
    parse_args "$@"

    CONFIG_DIR="${CONFIG_DIR%/}"
    [[ -n "$OUT_DIR" ]] || OUT_DIR="${CONFIG_DIR}/environments"
    mkdir -p "$OUT_DIR"

    local name
    if ! name="$(resolve_name)"; then
        die "Cannot determine the TAPPaaS system name. Pass --name <N>, or provide a site.json with '.name'."
    fi
    # The default-env name doubles as a zone key — keep it slug-safe.
    if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        die "Resolved system name '${name}' is not a valid slug (allowed: A-Z a-z 0-9 _ -)."
    fi
    if [[ "$name" == "mgmt" ]]; then
        die "The TAPPaaS system name must not be 'mgmt' (that name is reserved for the management environment)."
    fi

    local owner
    owner="$(site_owner)"
    [[ -n "$owner" ]] || warn "No organization found under ${CONFIG_DIR}/people/organizations/ — ownerOrg left empty in bootstrap environments."

    local domain
    domain="${DOMAIN_OVERRIDE:-$(default_domain)}"

    local display
    display="$(printf '%s%s' "$(printf '%s' "${name:0:1}" | tr '[:lower:]' '[:upper:]')" "${name:1}")"

    local mgmt_json default_json
    mgmt_json="$(jq -n --arg owner "$owner" '
        {
            name: "mgmt",
            displayName: "Management",
            ownerOrg: $owner,
            network: { zone: "mgmt" }
        }')"
    default_json="$(jq -n \
        --arg name "$name" \
        --arg display "$display" \
        --arg owner "$owner" \
        --arg domain "$domain" '
        {
            name: $name,
            displayName: $display,
            ownerOrg: $owner
        }
        + (if $domain != "" then { domains: { primary: $domain } } else {} end)
        + { network: { zone: $name } }')"

    if write_if_absent "${OUT_DIR}/mgmt.json" "$mgmt_json"; then
        info "${GN:-}Wrote ${OUT_DIR}/mgmt.json${CL:-} (zone=mgmt, no domains)"
    fi
    if write_if_absent "${OUT_DIR}/${name}.json" "$default_json"; then
        info "${GN:-}Wrote ${OUT_DIR}/${name}.json${CL:-} (default environment: name=${name}, zone=${name}, domain=${domain:-<none>})"
    fi

    # Note (do not delete) a stale literal default.json from older bootstraps.
    if [[ "$name" != "default" && -f "${OUT_DIR}/default.json" ]]; then
        warn "A legacy '${OUT_DIR}/default.json' exists — the default environment is now '${name}.json'. The legacy file is left in place; remove it manually once you have confirmed nothing references it."
    fi

    info "Minimal environments bootstrap complete (name=${name}, ownerOrg=${owner:-<unset>})."
}

main "$@"
