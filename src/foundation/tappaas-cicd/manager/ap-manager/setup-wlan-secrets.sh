#!/usr/bin/env bash
#
# setup-wlan-secrets.sh — interactively name the WiFi networks and set their passphrases (ADR-008, #339, #889)
#
# A WiFi network is a site-wide SSID owned by ap-manager: it bridges to one zone
# (the zone's `SSID` field names it) and every access point broadcasts it. This
# script walks the active zones whose `SSID` the template left as a placeholder
# (<HOME_SSID>) or that name an SSID ap-manager does not hold yet, and for each:
#   1. asks for the real name and how clients join, and declares it:
#      `ap-manager ssid add <ssid> --zone <zone> --security <sec>` (which also
#      sets the zone's SSID — this script never writes zones.json), then
#   2. for a WPA-personal SSID, asks for the passphrase and hands it to
#      `ap-manager ssid set-passphrase <ssid>` on stdin. It is stored only in the
#      0600 secrets file (~/.wlan-secrets.txt by default), never in a config.
#
# A blank answer skips; nothing is written until a prompt is answered.
#
# Usage:
#   setup-wlan-secrets.sh           interactively name SSIDs + set passphrases
#   setup-wlan-secrets.sh --list    show the zones, their SSIDs and whether a passphrase is set
#   setup-wlan-secrets.sh --help
#
# Env:
#   WLAN_SECRETS   secrets file path (default /home/tappaas/.wlan-secrets.txt)
#   AP_MANAGER     the ap-manager to run (tests)
#

set -euo pipefail

# shellcheck source=../../tappaas-cicd/lib/common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh
# is_placeholder, wlan_zones and the secrets file rules — shared with ap-manager.
# shellcheck source=../../lib/wlan-lib.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../lib/wlan-lib.sh"

# Both paths are env-injectable (defaults from CONFIG_DIR / WLAN_SECRETS) so the
# offline tests can point them at fixtures.
ZONES_FILE="${ZONES_FILE:-${CONFIG_DIR}/zones.json}"
SECRETS_FILE="${SECRETS_FILE:-${WLAN_SECRETS:-/home/tappaas/.wlan-secrets.txt}}"
WLAN_SECRETS_FILE="${SECRETS_FILE}"
AP_MANAGER="${AP_MANAGER:-ap-manager}"

usage() {
    cat <<EOF
Usage: setup-wlan-secrets.sh [--list]

  (no args)   for each active zone with a placeholder SSID (or one ap-manager
              does not hold): name it and declare it (ap-manager ssid add), then
              set its passphrase (ap-manager ssid set-passphrase, into
              ${SECRETS_FILE})
  --list      show each WiFi zone, its SSID and whether a passphrase is set
  --help      this help

ap-manager ssid add|modify|remove|set-passphrase do the same one at a time.
EOF
}

# ── secrets file (wlan-lib.sh) ──────────────────────────────────────

get_secret() { wlan_secret_get "$1"; }
has_secret() { wlan_secret_has "$1"; }
set_secret() { wlan_secret_set "$1" "$2"; }
del_secret() { wlan_secret_del "$1"; }

# Emit "zone<TAB>ssid<TAB>vlantag" for each ACTIVE zone declaring an SSID.
ssid_zones() { wlan_zones "${ZONES_FILE}"; }

# The site-wide SSIDs as ap-manager holds them (JSON list; [] if unreadable).
site_ssids() { "${AP_MANAGER}" ssid list --json 2>/dev/null || echo '[]'; }

# ── --list ──────────────────────────────────────────────────────────

cmd_list() {
    info "${BOLD}WiFi zones (active zones with an SSID):${CL}"
    printf '  %-12s %-6s %-24s %-15s %s\n' "ZONE" "VLAN" "SSID" "SECURITY" "PASSPHRASE"
    local zone ssid vlan sites sec mark
    sites="$(site_ssids)"
    while IFS=$'\t' read -r zone ssid vlan; do
        [[ -z "${zone}" ]] && continue
        sec="$(jq -r --arg s "${ssid}" '[.[] | select(.name == $s)][0].security // ""' <<<"${sites}")"
        if is_placeholder "${ssid}"; then
            mark="${YW:-}(placeholder — name it: ap-manager ssid add <ssid> --zone ${zone} --security <sec>)${CL:-}"
        elif [[ -z "${sec}" ]]; then
            mark="${YW:-}(not declared — ap-manager ssid add '${ssid}' --zone ${zone} --security <sec>)${CL:-}"
        else
            mark="$(jq -r --arg s "${ssid}" '[.[] | select(.name == $s)][0].passphrase' <<<"${sites}")"
        fi
        printf '  %-12s %-6s %-24s %-15s %b\n' "${zone}" "${vlan}" "${ssid}" "${sec:--}" "${mark}"
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
read_passphrase() {
    local p1 p2 why
    while true; do
        read -rs -p "    passphrase (blank = leave it): " p1 < /dev/tty; echo >&2
        [[ -z "${p1}" ]] && { echo ""; return 0; }
        why="$(wlan_passphrase_problem "${p1}")"
        if [[ -n "${why}" ]]; then warn "    ${why}; try again"; continue; fi
        read -rs -p "    confirm passphrase: " p2 < /dev/tty; echo >&2
        [[ "${p1}" == "${p2}" ]] && { printf '%s' "${p1}"; return 0; }
        warn "    passphrases did not match; try again"
    done
}

cmd_interactive() {
    [[ -t 0 ]] || die "interactive mode needs a terminal (use --list for a non-interactive view)"
    no_one_to_ask && die "interactive mode needs someone at the terminal (use --list for a non-interactive view)"
    info "${BOLD}WiFi networks: names and passphrases${CL}"
    info "Active zones with an SSID in ${ZONES_FILE}; passphrases → ${SECRETS_FILE}"
    info "Press Ctrl-C any time; nothing is written until you answer each prompt."
    echo

    local zone ssid vlan newname sec ans pass sites changed=0
    while IFS=$'\t' read -r zone ssid vlan; do
        [[ -z "${zone}" ]] && continue
        sites="$(site_ssids)"
        sec="$(jq -r --arg s "${ssid}" '[.[] | select(.name == $s)][0].security // ""' <<<"${sites}")"
        info "${BOLD}Zone '${zone}' (VLAN ${vlan})${CL} — SSID: ${ssid}${sec:+ (${sec})}"

        # 1. a placeholder or an SSID ap-manager does not hold: name and declare it
        if [[ -z "${sec}" ]]; then
            if is_placeholder "${ssid}"; then
                read -r -p "    real SSID name (blank = skip this zone): " newname < /dev/tty
            else
                read -r -p "    SSID name [${ssid}] (Enter to keep, '-' to skip): " newname < /dev/tty
                newname="${newname:-${ssid}}"
                [[ "${newname}" == "-" ]] && newname=""
            fi
            [[ -z "${newname}" ]] && { info "    skipped"; echo; continue; }
            read -r -p "    how clients join [wpa2-personal] (wpa3-personal, open, wpa2-enterprise, wpa3-enterprise): " sec < /dev/tty
            sec="${sec:-wpa2-personal}"
            if ! "${AP_MANAGER}" ssid add "${newname}" --zone "${zone}" --security "${sec}" < /dev/null; then
                warn "    not declared — skipped"; echo; continue
            fi
            ssid="${newname}"
            changed=1
        fi

        # 2. the passphrase, for a WPA-personal SSID
        if [[ "${sec}" == wpa2-personal || "${sec}" == wpa3-personal ]]; then
            if has_secret "${ssid}"; then
                read -r -p "    a passphrase is already stored for '${ssid}'. Replace it? [y/N]: " ans < /dev/tty
                [[ "${ans,,}" == y* ]] || { info "    kept the passphrase"; echo; continue; }
            fi
            pass="$(read_passphrase)"
            if [[ -z "${pass}" ]]; then
                info "    no passphrase stored — the access points cannot create '${ssid}' without one"
            elif printf '%s\n' "${pass}" | "${AP_MANAGER}" ssid set-passphrase "${ssid}"; then
                changed=1
            fi
        fi
        echo
    done < <(ssid_zones)

    if [[ "${changed}" -eq 1 ]]; then
        info "${GN}Done.${CL} To program the access points: ap-manager reconcile --apply"
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
