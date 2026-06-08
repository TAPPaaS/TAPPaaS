#!/usr/bin/env bash
#
# migrate-to-variants.sh — migrate a legacy single-domain install to the variant
# registry (ADR-005, #316).
#
# Reads the legacy tappaas.domain / tappaas.tlsCertRefid and creates the default
# variant tappaas.variants[""] from them (dnsMode=wildcard). Idempotent: if the
# default variant already exists it is left as-is unless --force is given. With
# --remove-legacy the legacy top-level fields are dropped afterwards (only safe
# once nothing still reads them — see the deprecation note below).
#
# Usage:
#   migrate-to-variants.sh [--force] [--remove-legacy] [--dry-run]
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh 2>/dev/null \
    || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common-install-routines.sh"

readonly CONFIG_FILE="${CONFIG_DIR}/configuration.json"

FORCE=0
REMOVE_LEGACY=0
DRY_RUN=0

usage() {
    cat <<EOF
${SCRIPT_NAME} — migrate a legacy single-domain install to the variant registry

Usage: ${SCRIPT_NAME} [--force] [--remove-legacy] [--dry-run]

  --force          Recreate variants[""] even if it already exists
  --remove-legacy  Drop tappaas.domain / tappaas.tlsCertRefid after migrating
  --dry-run        Show what would change without writing
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)         FORCE=1; shift ;;
        --remove-legacy) REMOVE_LEGACY=1; shift ;;
        --dry-run)       DRY_RUN=1; shift ;;
        --help|-h)       usage; exit 0 ;;
        *)               die "Unknown option: $1 (try --help)" ;;
    esac
done

[[ -f "${CONFIG_FILE}" ]] || die "configuration.json not found: ${CONFIG_FILE}"

has_default="$(jq -r '((.tappaas.variants // {}) | has("")) // false' "${CONFIG_FILE}")"
legacy_domain="$(jq -r '.tappaas.domain // empty' "${CONFIG_FILE}")"
legacy_refid="$(jq -r '.tappaas.tlsCertRefid // ""' "${CONFIG_FILE}")"

if [[ "${has_default}" == "true" && "${FORCE}" -eq 0 ]]; then
    info "Default variant tappaas.variants[\"\"] already exists — nothing to migrate (use --force to recreate)."
    if [[ "${REMOVE_LEGACY}" -eq 0 ]]; then
        exit 0
    fi
fi

if [[ "${has_default}" != "true" || "${FORCE}" -eq 1 ]]; then
    [[ -n "${legacy_domain}" ]] || die "No tappaas.domain to migrate (and no variants[\"\"]). Register one with: variant-manager add \"\" --domain <domain>"
    info "Migrating legacy domain '${BL}${legacy_domain}${CL}' -> variants[\"\"] (dnsMode=wildcard, tlsCertRefid='${legacy_refid}')"
fi

# Build the target document.
new_json="$(jq --arg d "${legacy_domain}" --arg r "${legacy_refid}" --argjson remove "${REMOVE_LEGACY}" '
    .tappaas.variants = (.tappaas.variants // {})
    | (if (.tappaas.variants | has("")) and ($d == "") then .
       else .tappaas.variants[""] = ((.tappaas.variants[""] // {})
            + { domain: (if $d == "" then (.tappaas.variants[""].domain // "") else $d end),
                tlsCertRefid: ((.tappaas.variants[""].tlsCertRefid // $r)),
                dnsMode: (.tappaas.variants[""].dnsMode // "wildcard"),
                description: (.tappaas.variants[""].description // "Default (migrated)") }) end)
    | (if $remove == 1 then (del(.tappaas.domain) | del(.tappaas.tlsCertRefid)) else . end)
' "${CONFIG_FILE}")"

if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "${BOLD}--dry-run — resulting tappaas block:${CL}"
    jq '.tappaas | {domain, tlsCertRefid, variants}' <<<"${new_json}"
    exit 0
fi

tmp="$(mktemp)"
printf '%s\n' "${new_json}" > "${tmp}"
jq empty "${tmp}" 2>/dev/null || { rm -f "${tmp}"; die "migration produced invalid JSON — aborted"; }
mv "${tmp}" "${CONFIG_FILE}"

info "${GN}✓${CL} Migration complete."
[[ "${REMOVE_LEGACY}" -eq 1 ]] && info "  Removed legacy tappaas.domain / tappaas.tlsCertRefid."
jq '.tappaas | {domain: (.domain // "<removed>"), variants}' "${CONFIG_FILE}"
