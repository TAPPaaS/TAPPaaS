#!/usr/bin/env bash
#
# migrate-configuration.sh — migrate configuration.json -> site.json (ADR-007 P2)
#
# PHASED migration (S3a): creates config/site.json from the legacy
# configuration.json. This is the structural site-identity/hardware migration
# ONLY. It does NOT:
#   - delete configuration.json (the flag-day cutover is a later step),
#   - migrate variants -> environments (that is S4/P3 — environments stays []),
#   - touch any existing configuration.json reader.
#
# Field mapping (configuration.json -> site.json):
#   name              <- .tappaas.name, else first DNS label of .tappaas.domain
#   displayName       <- .tappaas.displayName, else name
#   owner             <- first org slug under config/people/organizations/,
#                        else "" (operator must set it; a warning is emitted)
#   version           <- .tappaas.version
#   location.timezone <- system tz (timedatectl / /etc/localtime, fallback Europe/Amsterdam)
#   location.country  <- derived from timezone region (fallback NL)
#   location.locale   <- system locale ($LANG / localectl, fallback en_US)
#   network.isp       <- null
#   network.publicIp  <- "auto"
#   hardware.nodes    <- .tappaas-nodes[] mapped to {name: .hostname, storagePools: []}
#                        (storagePools is NOT in the source — left empty; a later
#                         step populates it from pvesm/zfs discovery)
#   backup            <- null
#   updateSchedule    <- .tappaas.updateSchedule
#   automaticReboot   <- .tappaas.automaticReboot
#   snapshotRetention <- .tappaas.snapshotRetention // 5
#   repositories      <- .tappaas.repositories
#   environments      <- []  (S4/P3 populates from variants)
#   organizations     <- references to config/people/organizations/*.json if present, else []
#
# DROPPED (deliberately, move to environments in S4): domain, email, variants, nodeCount.
#
# Idempotent: if site.json already exists it is a no-op unless --force is given.
# configuration.json is backed up to configuration.json.bak and LEFT in place.
#
# Usage: migrate-configuration.sh [OPTIONS]
#
# Options:
#   --config-dir DIR   config directory (default: ${TAPPAAS_CONFIG:-/home/tappaas/config})
#   --input  FILE      input configuration.json (default: <config-dir>/configuration.json)
#   --output FILE      output site.json          (default: <config-dir>/site.json)
#   --force            overwrite an existing site.json
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

CONFIG_DIR="${TAPPAAS_CONFIG:-/home/tappaas/config}"
INPUT=""
OUTPUT=""
FORCE=false

usage() {
    sed -n '2,40p' "$(readlink -f "${BASH_SOURCE[0]}")" | sed 's/^# \{0,1\}//'
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --config-dir)
                [[ -n "${2:-}" ]] || die "--config-dir requires a path argument"
                CONFIG_DIR="$2"; shift 2 ;;
            --input)
                [[ -n "${2:-}" ]] || die "--input requires a path argument"
                INPUT="$2"; shift 2 ;;
            --output)
                [[ -n "${2:-}" ]] || die "--output requires a path argument"
                OUTPUT="$2"; shift 2 ;;
            --force) FORCE=true; shift ;;
            -*) die "Unknown option: $1. Use --help for usage." ;;
            *)  die "Unexpected argument: $1. Use --help for usage." ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# System-fact derivation (timezone / country / locale). All have safe fallbacks
# so the migration never fails just because a fact is unavailable (e.g. tests
# on a container without timedatectl).
# ---------------------------------------------------------------------------
detect_timezone() {
    local tz=""
    if command -v timedatectl >/dev/null 2>&1; then
        tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    fi
    if [[ -z "$tz" && -L /etc/localtime ]]; then
        # /etc/localtime -> /usr/share/zoneinfo/Europe/Amsterdam
        local target
        target="$(readlink -f /etc/localtime 2>/dev/null || true)"
        tz="${target#*/zoneinfo/}"
        [[ "$tz" == "$target" ]] && tz=""   # no zoneinfo segment found
    fi
    if [[ -z "$tz" && -f /etc/timezone ]]; then
        tz="$(tr -d '[:space:]' < /etc/timezone 2>/dev/null || true)"
    fi
    [[ -n "$tz" ]] || tz="Europe/Amsterdam"
    printf '%s' "$tz"
}

# Map an IANA timezone to an ISO 3166-1 alpha-2 country. Only the regions
# relevant to the current TAPPaaS deployments are mapped explicitly; everything
# else falls back to NL (the project's primary locale).
country_from_timezone() {
    local tz="$1"
    case "$tz" in
        Europe/Amsterdam) echo "NL" ;;
        Europe/Copenhagen) echo "DK" ;;
        Europe/Berlin) echo "DE" ;;
        Europe/Brussels) echo "BE" ;;
        Europe/Paris) echo "FR" ;;
        Europe/London) echo "GB" ;;
        Europe/Madrid) echo "ES" ;;
        Europe/Rome) echo "IT" ;;
        America/*) echo "US" ;;
        *) echo "NL" ;;
    esac
}

detect_locale() {
    local loc=""
    if command -v localectl >/dev/null 2>&1; then
        loc="$(localectl status 2>/dev/null | sed -n 's/.*LANG=\([^ ]*\).*/\1/p' | head -1 || true)"
    fi
    [[ -z "$loc" ]] && loc="${LANG:-}"
    # strip any encoding suffix (en_US.UTF-8 -> en_US)
    loc="${loc%%.*}"
    # reject C / POSIX / empty
    case "$loc" in ""|C|POSIX) loc="en_US" ;; esac
    printf '%s' "$loc"
}

# Collect organization slugs (basenames) under config/people/organizations/,
# in sorted order, one per line. Empty output if the directory is absent/empty.
# (No subshell-mutated globals — callers capture the output.)
org_slugs() {
    local orgdir="${CONFIG_DIR}/people/organizations" f base
    [[ -d "$orgdir" ]] || return 0
    for f in "$orgdir"/*.json; do
        [[ -e "$f" ]] || continue
        base="$(basename "$f" .json)"
        printf '%s\n' "$base"
    done | LC_ALL=C sort
}

main() {
    parse_args "$@"

    CONFIG_DIR="${CONFIG_DIR%/}"
    [[ -n "$INPUT"  ]] || INPUT="${CONFIG_DIR}/configuration.json"
    [[ -n "$OUTPUT" ]] || OUTPUT="${CONFIG_DIR}/site.json"

    # Idempotency guard: existing site.json is a no-op unless --force.
    if [[ -f "$OUTPUT" && "$FORCE" != "true" ]]; then
        info "site.json already exists at ${OUTPUT} — nothing to do (use --force to overwrite)."
        exit 0
    fi

    [[ -f "$INPUT" ]] || die "Input configuration.json not found: ${INPUT}"
    jq empty "$INPUT" >/dev/null 2>&1 || die "Input is not valid JSON: ${INPUT}"

    info "Migrating ${INPUT} -> ${OUTPUT}"

    # --- Derive system facts ---
    local tz country locale
    tz="$(detect_timezone)"
    country="$(country_from_timezone "$tz")"
    locale="$(detect_locale)"
    debug "timezone=${tz} country=${country} locale=${locale}"

    # --- Derive name / displayName ---
    local name displayName domain
    name="$(jq -r '.tappaas.name // empty' "$INPUT")"
    domain="$(jq -r '.tappaas.domain // empty' "$INPUT")"
    if [[ -z "$name" && -n "$domain" ]]; then
        name="${domain%%.*}"   # first DNS label, e.g. test2.tapaas.org -> test2
    fi
    [[ -n "$name" ]] || name="tappaas-site"
    displayName="$(jq -r '.tappaas.displayName // empty' "$INPUT")"
    [[ -n "$displayName" ]] || displayName="$name"

    # --- Derive owner + organizations[] from config/people/organizations/ ---
    local slugs orgs owner
    slugs="$(org_slugs)"
    if [[ -n "$slugs" ]]; then
        owner="$(printf '%s\n' "$slugs" | head -1)"
        orgs="$(printf '%s\n' "$slugs" \
            | sed 's#^#config/people/organizations/#; s#$#.json#' \
            | jq -R . | jq -s .)"
    else
        owner=""
        orgs='[]'
        warn "No organization found under ${CONFIG_DIR}/people/organizations/ — owner left empty; set it manually in site.json."
    fi

    # --- Build site.json ---
    local tmp
    tmp="$(mktemp "${OUTPUT}.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '${tmp}'" EXIT INT TERM

    jq -n \
        --arg name "$name" \
        --arg displayName "$displayName" \
        --arg owner "$owner" \
        --arg country "$country" \
        --arg timezone "$tz" \
        --arg locale "$locale" \
        --slurpfile cfg "$INPUT" \
        --argjson orgs "$orgs" \
        '
        ($cfg[0].tappaas // {}) as $t
        | {
            name: $name,
            displayName: $displayName,
            owner: $owner,
            version: ($t.version // "1.0"),
            location: {
                country: $country,
                timezone: $timezone,
                locale: $locale
            },
            network: {
                isp: null,
                publicIp: "auto"
            },
            hardware: {
                nodes: (
                    ($cfg[0]["tappaas-nodes"] // [])
                    | map({ name: .hostname, storagePools: [] })
                )
            },
            backup: null,
            updateSchedule: (if ($t | has("updateSchedule")) then $t.updateSchedule else ["monthly", "Thursday", 2] end),
            automaticReboot: (if ($t | has("automaticReboot")) then $t.automaticReboot else true end),
            snapshotRetention: (if ($t | has("snapshotRetention")) then $t.snapshotRetention else 5 end),
            repositories: ($t.repositories // []),
            environments: [],
            organizations: $orgs
          }
        ' > "$tmp"

    # --- Back up configuration.json (do NOT delete it) ---
    if [[ -f "$INPUT" ]]; then
        cp -p "$INPUT" "${INPUT}.bak"
        debug "Backed up ${INPUT} -> ${INPUT}.bak"
    fi

    mv "$tmp" "$OUTPUT"
    trap - EXIT INT TERM

    info "${GN:-}Wrote ${OUTPUT}${CL:-} (name=${name}, owner=${owner:-<unset>}, tz=${tz}, country=${country})"
    info "configuration.json left in place (phased migration); backed up to ${INPUT}.bak"
}

main "$@"
