#!/usr/bin/env bash
#
# zone-state.sh — atomic state change for a zone in zones.json (#209).
#
# Replaces the manual `jq '.<zone>.state = "..."' zones.json > tmp && mv …`
# ritual with a one-liner that validates the zone exists, refuses bogus
# transitions, and prints the next-step `zone-manager --execute` command.
#
# Does NOT push to OPNsense — by design, the operator runs zone-manager
# themselves when they're ready. This keeps the helper safe to call from
# automation and from interactive shells.
#
# Usage:
#   zone-state.sh enable  <zone-name>
#   zone-state.sh disable <zone-name>
#   zone-state.sh manual  <zone-name>
#
# Verb → state mapping:
#   enable  → "Active"
#   disable → "Inactive"
#   manual  → "Manual"
#
# Mandatory zones (e.g. dmz) are refused without --force; Disabled is reserved
# for the zone-manager remove flow and is not exposed here.
#
# Exit codes:
#   0  state changed (or no-op when already in the requested state)
#   1  zone not found / file IO failure / invalid current state
#   2  bad arguments
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

readonly ZONES_FILE="${CONFIG_DIR}/zones.json"

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} <enable|disable|manual> <zone-name> [--force]

Atomically change the state of a zone in ${ZONES_FILE}.

Verbs:
    enable    Set state to "Active"   (zone-manager will create VLAN + DHCP + rules)
    disable   Set state to "Inactive" (defined-but-not-deployed)
    manual    Set state to "Manual"   (operator-managed, zone-manager leaves alone)

Options:
    --force   Allow leaving the "Mandatory" state (refused by default)
    -h, --help  Show this help

After mutating zones.json, the change must be applied to OPNsense via
zone-manager. This script prints the exact command to run; it does not
push to the firewall itself.

Exit codes:
    0  state changed (or no-op when already in the requested state)
    1  zone not found / file IO failure
    2  bad arguments
EOF
}

# ── Arguments ────────────────────────────────────────────────────────

VERB=""
ZONE=""
OPT_FORCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)  usage; exit 0 ;;
        --force)    OPT_FORCE=1; shift ;;
        enable|disable|manual)
            if [[ -n "${VERB}" ]]; then
                error "Multiple verbs given"; usage; exit 2
            fi
            VERB="$1"; shift
            ;;
        -*)
            error "Unknown option: $1"; usage; exit 2
            ;;
        *)
            if [[ -z "${ZONE}" ]]; then
                ZONE="$1"
            else
                error "Unexpected argument: $1"; usage; exit 2
            fi
            shift
            ;;
    esac
done

if [[ -z "${VERB}" || -z "${ZONE}" ]]; then
    error "Both a verb and a zone name are required"
    usage
    exit 2
fi

# Map verb → state.
declare -A VERB_TO_STATE=(
    [enable]="Active"
    [disable]="Inactive"
    [manual]="Manual"
)
TARGET_STATE="${VERB_TO_STATE[${VERB}]}"

# ── Validate file + zone ─────────────────────────────────────────────

if [[ ! -f "${ZONES_FILE}" ]]; then
    die "zones.json not found at ${ZONES_FILE}"
fi
if ! jq empty "${ZONES_FILE}" 2>/dev/null; then
    die "zones.json is not valid JSON: ${ZONES_FILE}"
fi
if ! jq -e --arg z "${ZONE}" 'has($z)' "${ZONES_FILE}" >/dev/null; then
    error "Zone '${ZONE}' not found in ${ZONES_FILE}"
    info "  Known zones:"
    jq -r 'keys[]' "${ZONES_FILE}" | sed 's/^/    /'
    exit 1
fi

# ── Read current state + guard transitions ──────────────────────────

CURRENT_STATE="$(jq -r --arg z "${ZONE}" '.[$z].state // ""' "${ZONES_FILE}")"
if [[ -z "${CURRENT_STATE}" ]]; then
    die "Zone '${ZONE}' has no 'state' field"
fi

if [[ "${CURRENT_STATE}" == "${TARGET_STATE}" ]]; then
    info "${ZONE}: state already ${BL}${TARGET_STATE}${CL} — no change"
    exit 0
fi

if [[ "${CURRENT_STATE}" == "Mandatory" && "${OPT_FORCE}" -eq 0 ]]; then
    error "Zone '${ZONE}' is currently 'Mandatory' — refusing to change without --force"
    error "  Mandatory zones (e.g. dmz) are required for the platform's security model."
    exit 1
fi

# ── Mutate atomically ────────────────────────────────────────────────

tmp="$(mktemp)"
if ! jq --arg z "${ZONE}" --arg s "${TARGET_STATE}" \
        '.[$z].state = $s' "${ZONES_FILE}" > "${tmp}"; then
    rm -f "${tmp}"
    die "Failed to write updated zones.json"
fi
if ! jq empty "${tmp}" 2>/dev/null; then
    rm -f "${tmp}"
    die "Updated zones.json failed JSON validation — original left unchanged"
fi
mv "${tmp}" "${ZONES_FILE}"

info "${ZONE}: ${BL}${CURRENT_STATE}${CL} → ${GN}${TARGET_STATE}${CL}"
echo ""
info "  To apply on OPNsense, run:"
info "    ${BL}zone-manager --no-ssl-verify --zones-file ${ZONES_FILE} --execute${CL}"

exit 0
