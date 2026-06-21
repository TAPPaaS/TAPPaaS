#!/usr/bin/env bash
#
# setup-wlan-secrets.sh — interactively manage WiFi SSID names + passphrases (ADR-008, #339)
#
# WiFi networks are declared per ZONE in zones.json via the `SSID` field (the
# SSID name) and the zone's `vlantag` (the VLAN it maps to). This script walks
# the active zones that declare an SSID and, for each:
#   1. lets you set/confirm the real SSID NAME in zones.json (replacing the
#      <PLACEHOLDER> shipped in the template), and
#   2. collects the WPA passphrase into a SEPARATE 0600 secrets file
#      (~/.wlan-secrets.txt by default) that ap-manager's vendor plugins read
#      at apply time. The passphrase is NEVER written to zones.json (which is a
#      committed config), only to the secrets file.
#
# A blank passphrase means "open network / leave unchanged" — no secret stored.
# Security level (open/personal/enterprise) is chosen per-SSID in the ap-manager
# inventory (`ap-manager ssid <ap> add ... --security`); this script only owns
# the SSID name (in zones.json) and the passphrase (in the secrets file).
#
# Usage:
#   setup-wlan-secrets.sh           interactively set SSID names + passphrases
#   setup-wlan-secrets.sh --list    show zones/SSIDs and whether a secret is set
#   setup-wlan-secrets.sh --help
#
# Env:
#   WLAN_SECRETS   secrets file path (default /home/tappaas/.wlan-secrets.txt)
#

set -euo pipefail

# shellcheck source=../../tappaas-cicd/lib/common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

# Both paths are env-injectable (defaults from CONFIG_DIR / WLAN_SECRETS) so the
# offline tests can point them at fixtures.
ZONES_FILE="${ZONES_FILE:-${CONFIG_DIR}/zones.json}"
SECRETS_FILE="${SECRETS_FILE:-${WLAN_SECRETS:-/home/tappaas/.wlan-secrets.txt}}"

# Temp files cleaned up on exit/signal.
TMPFILES=()
cleanup() { local f; for f in "${TMPFILES[@]:-}"; do [[ -n "${f}" ]] && rm -f "${f}"; done; }
trap cleanup EXIT INT TERM

usage() {
    cat <<EOF
Usage: setup-wlan-secrets.sh [--list]

  (no args)   interactively set SSID names (in zones.json) + passphrases
              (in ${SECRETS_FILE}) for active zones that declare an SSID
  --list      show each SSID zone, VLAN, name and whether a secret is set
  --help      this help

A blank passphrase leaves the network open / unchanged (no secret stored).
EOF
}

# A placeholder SSID is the shipped template value, e.g. <HOME_SSID>.
is_placeholder() { [[ "$1" == \<*\> ]]; }

# ── secrets file helpers (split on the FIRST '=') ───────────────────

# Print the stored passphrase for <ssid> (empty if none).
get_secret() {
    local ssid="$1"
    [[ -f "${SECRETS_FILE}" ]] || return 0
    awk -v s="${ssid}" '{eq=index($0,"="); if(eq>0 && substr($0,1,eq-1)==s){print substr($0,eq+1); exit}}' "${SECRETS_FILE}"
}

# True if a secret line exists for <ssid>.
has_secret() {
    [[ -f "${SECRETS_FILE}" ]] || return 1
    awk -v s="${ssid:=$1}" 'BEGIN{f=1} {eq=index($0,"="); if(eq>0 && substr($0,1,eq-1)==s){f=0; exit}} END{exit f}' "${SECRETS_FILE}"
}

# Remove any secret line for <ssid>.
del_secret() {
    local ssid="$1" tmp
    [[ -f "${SECRETS_FILE}" ]] || return 0
    tmp="$(mktemp)"; TMPFILES+=("${tmp}"); chmod 600 "${tmp}"
    awk -v s="${ssid}" '{eq=index($0,"="); k=(eq>0?substr($0,1,eq-1):$0); if(k!=s) print}' "${SECRETS_FILE}" > "${tmp}"
    mv "${tmp}" "${SECRETS_FILE}"; chmod 600 "${SECRETS_FILE}"
}

# Set <ssid>=<passphrase> (replacing any existing line for that SSID).
set_secret() {
    local ssid="$1" pass="$2" tmp
    ( umask 077; touch "${SECRETS_FILE}" )
    chmod 600 "${SECRETS_FILE}"
    tmp="$(mktemp)"; TMPFILES+=("${tmp}"); chmod 600 "${tmp}"
    awk -v s="${ssid}" '{eq=index($0,"="); k=(eq>0?substr($0,1,eq-1):$0); if(k!=s) print}' "${SECRETS_FILE}" > "${tmp}"
    printf '%s=%s\n' "${ssid}" "${pass}" >> "${tmp}"
    mv "${tmp}" "${SECRETS_FILE}"; chmod 600 "${SECRETS_FILE}"
}

# ── zones.json helper ───────────────────────────────────────────────

# Set zone <zone>'s SSID name to <name> (atomic).
set_zone_ssid() {
    local zone="$1" name="$2" tmp
    tmp="$(mktemp)"; TMPFILES+=("${tmp}")
    if jq --arg z "${zone}" --arg s "${name}" '.[$z].SSID = $s' "${ZONES_FILE}" > "${tmp}"; then
        mv "${tmp}" "${ZONES_FILE}"
    else
        die "failed to update SSID for zone '${zone}' in ${ZONES_FILE}"
    fi
}

# Emit "zone<TAB>ssid<TAB>vlantag" for each ACTIVE zone declaring an SSID.
ssid_zones() {
    jq -r 'to_entries[]
           | select((.value.SSID? != null) and ((.value.state // "Active") == "Active"))
           | "\(.key)\t\(.value.SSID)\t\(.value.vlantag // 0)"' "${ZONES_FILE}"
}

# ── --list ──────────────────────────────────────────────────────────

cmd_list() {
    info "${BOLD}WiFi SSIDs declared in zones.json (active zones):${CL}"
    printf '  %-12s %-6s %-24s %s\n' "ZONE" "VLAN" "SSID" "SECRET"
    local zone ssid vlan mark
    while IFS=$'\t' read -r zone ssid vlan; do
        [[ -z "${zone}" ]] && continue
        if is_placeholder "${ssid}"; then
            mark="${YW:-}(placeholder — set a real name)${CL:-}"
        elif has_secret "${ssid}"; then
            mark="${GN:-}set${CL:-}"
        else
            mark="-  (open / not set)"
        fi
        printf '  %-12s %-6s %-24s %b\n' "${zone}" "${vlan}" "${ssid}" "${mark}"
    done < <(ssid_zones)
    if [[ -f "${SECRETS_FILE}" ]]; then
        info "secrets file: ${SECRETS_FILE} ($(stat -c '%a' "${SECRETS_FILE}"))"
    else
        info "secrets file: ${SECRETS_FILE} (not created yet)"
    fi
    return 0
}

# ── interactive ─────────────────────────────────────────────────────

# Read a passphrase twice (hidden); echoes the value on stdout, empty if blank.
# WPA-PSK must be 8–63 chars; re-prompt on mismatch / bad length.
read_passphrase() {
    local p1 p2
    while true; do
        read -rs -p "    passphrase (blank = open/unchanged): " p1 < /dev/tty; echo >&2
        [[ -z "${p1}" ]] && { echo ""; return 0; }
        if [[ ${#p1} -lt 8 || ${#p1} -gt 63 ]]; then
            warn "    WPA passphrase must be 8–63 characters; try again"; continue
        fi
        read -rs -p "    confirm passphrase: " p2 < /dev/tty; echo >&2
        [[ "${p1}" == "${p2}" ]] && { printf '%s' "${p1}"; return 0; }
        warn "    passphrases did not match; try again"
    done
}

cmd_interactive() {
    [[ -t 0 ]] || die "interactive mode needs a terminal (use --list for a non-interactive view)"
    info "${BOLD}WiFi SSID + passphrase setup${CL}"
    info "Reads active zones with an SSID from ${ZONES_FILE}; secrets → ${SECRETS_FILE}"
    info "Press Ctrl-C any time; nothing is written until you answer each prompt."
    echo

    local zone ssid vlan newname ans pass changed=0
    while IFS=$'\t' read -r zone ssid vlan; do
        [[ -z "${zone}" ]] && continue
        info "${BOLD}Zone '${zone}' (VLAN ${vlan})${CL} — current SSID: ${ssid}"

        # 1. SSID name
        if is_placeholder "${ssid}"; then
            read -r -p "    real SSID name (blank = skip this zone): " newname < /dev/tty
            [[ -z "${newname}" ]] && { info "    skipped"; echo; continue; }
        else
            read -r -p "    SSID name [${ssid}] (Enter to keep): " newname < /dev/tty
            newname="${newname:-${ssid}}"
        fi
        if [[ "${newname}" != "${ssid}" ]]; then
            set_zone_ssid "${zone}" "${newname}"
            # carry any existing secret to the new name; drop the old key
            local old; old="$(get_secret "${ssid}")"
            if [[ -n "${old}" ]]; then set_secret "${newname}" "${old}"; del_secret "${ssid}"; fi
            info "    ${GN}✓${CL} SSID name → '${newname}' (zones.json)"
            changed=1
        fi
        ssid="${newname}"

        # 2. passphrase
        if [[ -n "$(get_secret "${ssid}")" ]]; then
            read -r -p "    a passphrase is already stored for '${ssid}'. Replace it? [y/N]: " ans < /dev/tty
            [[ "${ans,,}" == y* ]] || { info "    kept existing passphrase"; echo; continue; }
        fi
        pass="$(read_passphrase)"
        if [[ -z "${pass}" ]]; then
            info "    no passphrase stored (open network / unchanged)"
        else
            set_secret "${ssid}" "${pass}"
            info "    ${GN}✓${CL} passphrase stored for '${ssid}'"
            changed=1
        fi
        echo
    done < <(ssid_zones)

    if [[ "${changed}" -eq 1 ]]; then
        info "${GN}Done.${CL} Next steps:"
        info "  1. Add each SSID to your AP:   ap-manager ssid <ap> add <ssid> --zone <zone> --security wpa2-personal"
        info "  2. Push to the controller:     ap-manager reconcile --apply"
    else
        info "No changes made."
    fi
    return 0
}

# ── Main ─────────────────────────────────────────────────────────────

main() {
    [[ -f "${ZONES_FILE}" ]] || die "zones.json not found: ${ZONES_FILE}"
    case "${1:-}" in
        -h|--help) usage ;;
        --list)    cmd_list ;;
        "")        cmd_interactive ;;
        *)         die "unknown argument '$1' (try --help)" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
