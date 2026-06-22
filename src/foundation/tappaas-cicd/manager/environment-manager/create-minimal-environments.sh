#!/usr/bin/env bash
#
# create-minimal-environments.sh — bootstrap the two always-required environments (ADR-007 P3)
#
# Every TAPPaaS system requires two environments:
#   - mgmt.json    : the management environment (foundation modules, internal DNS
#                    only). network.zone = mgmt, NO domains.
#   - default.json : the default tenant environment. network.zone = default,
#                    no domains by default (a domain is added by the variant
#                    migration or by an operator later).
#
# This script is the SINGLE OWNER of these two files (sibling of P1's
# user-setup.sh). P6/P7 reference them, they do NOT re-author them.
#
# Idempotent: an existing environment file is left untouched unless --force.
# When default.json was already produced by migrate-variants.sh (e.g. it carries
# a domain), this script will not clobber it.
#
# Usage: create-minimal-environments.sh [OPTIONS]
#
# Options:
#   --config-dir DIR   config directory (default: ${TAPPAAS_CONFIG:-/home/tappaas/config})
#   --out-dir DIR      output environments dir (default: <config-dir>/environments)
#   --force            overwrite existing mgmt.json / default.json
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
FORCE=false

usage() {
    sed -n '2,32p' "$_SELF" | sed 's/^# \{0,1\}//'
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
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

    local owner
    owner="$(site_owner)"
    [[ -n "$owner" ]] || warn "No organization found under ${CONFIG_DIR}/people/organizations/ — ownerOrg left empty in bootstrap environments."

    local mgmt_json default_json
    mgmt_json="$(jq -n --arg owner "$owner" '
        {
            name: "mgmt",
            displayName: "Management",
            ownerOrg: $owner,
            network: { zone: "mgmt" }
        }')"
    default_json="$(jq -n --arg owner "$owner" '
        {
            name: "default",
            displayName: "Default Environment",
            ownerOrg: $owner,
            network: { zone: "default" }
        }')"

    if write_if_absent "${OUT_DIR}/mgmt.json" "$mgmt_json"; then
        info "${GN:-}Wrote ${OUT_DIR}/mgmt.json${CL:-} (zone=mgmt, no domains)"
    fi
    if write_if_absent "${OUT_DIR}/default.json" "$default_json"; then
        info "${GN:-}Wrote ${OUT_DIR}/default.json${CL:-} (zone=default)"
    fi

    info "Minimal environments bootstrap complete (ownerOrg=${owner:-<unset>})."
}

main "$@"
