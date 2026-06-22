#!/usr/bin/env bash
#
# migrate-variants.sh — migrate configuration.json variants -> environments (ADR-007 P3)
#
# PHASED migration (#318): creates config/environments/<name>.json files from the
# legacy configuration.json '.tappaas.variants' construct. This is the
# variant->environment structural migration ONLY. It does NOT:
#   - delete configuration.json (the flag-day cutover is a later step),
#   - touch any existing configuration.json reader,
#   - modify variant-manager.sh / migrate-to-variants.sh.
#
# Input shape (configuration.json):
#   .tappaas.variants = { "<name>": { domain, tlsCertRefid, dnsMode, description }, ... }
#   The key "" is the DEFAULT variant -> environments/default.json (name "default").
#   .tappaas.domain is a legacy fallback for the "" variant's domain.
#
# Field mapping (variant -> environment):
#   <name>            -> .name           ("" maps to "default")
#   <name>            -> .displayName    (Title-cased name; "default" -> "Default Environment")
#   .domain           -> .domains.primary
#   .dnsMode          -> .domains.dnsMode (default "per-service")
#   .zone             -> .network.zone   (default "default")
#   (site owner)      -> .ownerOrg       (first org slug under config/people/organizations/, else "")
#
# DROPPED (deliberately): tlsCertRefid — it is NOT an authored Environment field.
#   Whether a cert ref exists is decided by dnsMode; the refid (if any) is
#   reconciler-populated runtime state owned by the network/cert layer (ADR-007
#   "TLS certificate handling"). It is never written into environment.json.
#   A variant with no .domain produces an environment WITHOUT a domains object.
#
# Idempotent: an existing environments/<name>.json is skipped unless --force.
# configuration.json is LEFT in place (phased migration); not modified.
#
# Usage: migrate-variants.sh [OPTIONS]
#
# Options:
#   --config-dir DIR   config directory (default: ${TAPPAAS_CONFIG:-/home/tappaas/config})
#   --input  FILE      input configuration.json (default: <config-dir>/configuration.json)
#   --out-dir DIR      output environments dir   (default: <config-dir>/environments)
#   --force            overwrite existing environment files
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
INPUT=""
OUT_DIR=""
FORCE=false

usage() {
    sed -n '2,49p' "$_SELF" | sed 's/^# \{0,1\}//'
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
            --out-dir)
                [[ -n "${2:-}" ]] || die "--out-dir requires a path argument"
                OUT_DIR="$2"; shift 2 ;;
            --force) FORCE=true; shift ;;
            -*) die "Unknown option: $1. Use --help for usage." ;;
            *)  die "Unexpected argument: $1. Use --help for usage." ;;
        esac
    done
}

# Title-case a slug for displayName (foo -> Foo, foo-bar -> Foo-bar).
display_name_for() {
    local n="$1"
    [[ "$n" == "default" ]] && { printf 'Default Environment'; return; }
    printf '%s%s' "$(printf '%s' "${n:0:1}" | tr '[:lower:]' '[:upper:]')" "${n:1}"
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

# Emit one environment JSON to stdout.
#   $1 name  $2 displayName  $3 ownerOrg  $4 domain  $5 dnsMode  $6 zone
build_environment() {
    local name="$1" displayName="$2" ownerOrg="$3" domain="$4" dnsMode="$5" zone="$6"
    jq -n \
        --arg name "$name" \
        --arg displayName "$displayName" \
        --arg ownerOrg "$ownerOrg" \
        --arg domain "$domain" \
        --arg dnsMode "$dnsMode" \
        --arg zone "$zone" \
        '
        {
            name: $name,
            displayName: $displayName,
            ownerOrg: $ownerOrg
        }
        + (if $domain != "" then
              { domains: { primary: $domain, dnsMode: (if $dnsMode != "" then $dnsMode else "per-service" end) } }
           else {} end)
        + { network: { zone: (if $zone != "" then $zone else "default" end) } }
        '
}

main() {
    parse_args "$@"

    CONFIG_DIR="${CONFIG_DIR%/}"
    [[ -n "$INPUT"   ]] || INPUT="${CONFIG_DIR}/configuration.json"
    [[ -n "$OUT_DIR" ]] || OUT_DIR="${CONFIG_DIR}/environments"

    [[ -f "$INPUT" ]] || die "Input configuration.json not found: ${INPUT}"
    jq empty "$INPUT" >/dev/null 2>&1 || die "Input is not valid JSON: ${INPUT}"

    mkdir -p "$OUT_DIR"

    local owner
    owner="$(site_owner)"
    [[ -n "$owner" ]] || warn "No organization found under ${CONFIG_DIR}/people/organizations/ — ownerOrg left empty in migrated environments."

    # Legacy fallback domain for the "" (default) variant.
    local legacy_domain
    legacy_domain="$(jq -r '.tappaas.domain // empty' "$INPUT")"

    # Variant keys (one per line; "" key emitted as the literal empty line).
    # Use a sentinel so the empty default key survives the read loop.
    local keys
    keys="$(jq -r '(.tappaas.variants // {}) | keys[] | if . == "" then "__DEFAULT__" else . end' "$INPUT")"

    if [[ -z "$keys" && -z "$legacy_domain" ]]; then
        info "No variants and no legacy domain in ${INPUT} — nothing to migrate."
        exit 0
    fi

    # Always handle the default ("") even if no explicit "" key but a legacy domain exists.
    if [[ -n "$legacy_domain" ]] && ! printf '%s\n' "$keys" | grep -qx '__DEFAULT__'; then
        keys="$(printf '%s\n__DEFAULT__\n' "$keys")"
    fi

    local migrated=0 skipped=0
    local key vkey name out domain dnsMode zone displayName
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        if [[ "$key" == "__DEFAULT__" ]]; then
            vkey=""
            name="default"
        else
            vkey="$key"
            name="$key"
        fi

        out="${OUT_DIR}/${name}.json"
        if [[ -f "$out" && "$FORCE" != "true" ]]; then
            info "environments/${name}.json already exists — skipping (use --force to overwrite)."
            skipped=$((skipped + 1))
            continue
        fi

        domain="$(jq -r --arg k "$vkey" '(.tappaas.variants[$k].domain) // empty' "$INPUT")"
        dnsMode="$(jq -r --arg k "$vkey" '(.tappaas.variants[$k].dnsMode) // empty' "$INPUT")"
        zone="$(jq -r --arg k "$vkey" '(.tappaas.variants[$k].zone) // empty' "$INPUT")"

        # Legacy fallback domain only for the default.
        if [[ -z "$domain" && "$name" == "default" ]]; then
            domain="$legacy_domain"
        fi

        displayName="$(display_name_for "$name")"

        local tmp
        tmp="$(mktemp "${out}.XXXXXX")"
        # shellcheck disable=SC2064
        trap "rm -f '${tmp}'" EXIT INT TERM
        build_environment "$name" "$displayName" "$owner" "$domain" "$dnsMode" "$zone" > "$tmp"
        mv "$tmp" "$out"
        trap - EXIT INT TERM

        info "${GN:-}Wrote ${out}${CL:-} (name=${name}, ownerOrg=${owner:-<unset>}, domain=${domain:-<none>}, dnsMode=${dnsMode:-per-service}, zone=${zone:-default}; tlsCertRefid DROPPED)"
        migrated=$((migrated + 1))
    done <<< "$keys"

    info "Variant migration complete: ${migrated} written, ${skipped} skipped. configuration.json left in place (phased migration)."
}

main "$@"
