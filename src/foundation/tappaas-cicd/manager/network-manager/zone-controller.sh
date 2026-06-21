#!/usr/bin/env bash
#
# zone-controller — single primitive for the network-zone lifecycle.
#
# Owns zone CREATE/DELETE end to end so every caller (variant-manager, or a
# hands-on operator) goes through one path that cannot forget a step. It does
# NOT reimplement OPNsense/Proxmox logic — it authors zones.json and orchestrates
# the existing reconcilers:
#
#   add    : author zones.json → maintain mgmt.access-to → zone-manager --execute
#            → distribute zones.json → proxmox-manager reconcile --apply (per-VM
#            trunks) → proxmox-manager bridge-vids --apply (node lan bridges).
#   delete : remove from mgmt.access-to → disable zone → zone-manager --execute
#            (drops the OPNsense iface) → proxmox-manager reconcile/bridge-vids
#            --apply (drops trunk + VID, guarded) → delete key → distribute.
#
# See docs/design/zone-controller.md for the full design and the bridge-vids
# safety model (adding a VID is non-disruptive and auto-applied; removing a VID
# is guarded against VMs still using it). Fixes the #335-family bridge-vids gap
# and the #372/#373 mgmt-invariant drift.
#
set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh 2>/dev/null \
    || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common-install-routines.sh"

readonly CONFIG_FILE="${CONFIG_DIR}/configuration.json"
readonly ZONES_FILE="${CONFIG_DIR}/zones.json"

# Dynamic-allocation VLAN window within a type band (10.<typeId>.<sub>.0/24).
# Matches variant-manager's range so zone choices are unchanged when it delegates.
readonly ZONE_SUB_MAX=99
readonly ZONE_SUB_MIN=60

# ── temp files / cleanup ─────────────────────────────────────────────
_TMPFILES=()
cleanup() {
    local rc=$?           # preserve the script's real exit code
    local f
    for f in "${_TMPFILES[@]:-}"; do
        [[ -n "${f}" && -e "${f}" ]] && rm -f "${f}" || true
    done
    exit "${rc}"
}
trap cleanup EXIT INT TERM

# ── usage ────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${SCRIPT_NAME} — create or delete a TAPPaaS network zone (single primitive).

Usage:
  ${SCRIPT_NAME} add <name> [options]
  ${SCRIPT_NAME} delete <name> [options]

add options:
  --from-zone <src>      inherit type/typeId/bridge/access-to/pinhole from <src>
  --type <T> --typeId <N> zone type + numeric band (default: Service / 2)
  --vlan <tag>           explicit VLAN tag (else auto-allocated ${ZONE_SUB_MIN}-${ZONE_SUB_MAX} in band)
  --variant <name>       tag the zone with this variant (metadata + description)
  --no-bridge-apply      skip 'proxmox-manager bridge-vids --apply' (advanced)
  --no-activate          author zones.json + mgmt only; skip all reconcile/apply
  --check                dry-run: show actions, mutate nothing
add echoes the created zone name on success.

delete options:
  --force                proceed even if VMs still run in the zone
  --keep-bridge-vid      do not remove the VLAN from node bridge-vids
  --check                dry-run

common:
  --zones-file <f>       default ${ZONES_FILE}
  --no-ssl-verify        passed to zone-manager (firewall API serves a self-signed cert)
  -h, --help

Examples:
  ${SCRIPT_NAME} add tenant1 --from-zone srvCust --variant tenant1
  ${SCRIPT_NAME} delete tenant1
EOF
}

# ── jq read/modify/write with validation (atomic temp→validate→mv) ───
jq_write() {
    local file="$1"; shift
    local tmp; tmp="$(mktemp)"; _TMPFILES+=("${tmp}")
    if ! jq "$@" "${file}" >"${tmp}"; then
        die "jq failed updating ${file}"
    fi
    if ! jq empty "${tmp}" 2>/dev/null; then
        die "jq produced invalid JSON for ${file}"
    fi
    mv "${tmp}" "${file}"
}

# Echo a Proxmox node hostname to ssh into (first declared cluster node).
_primary_node() {
    jq -r '."tappaas-nodes"[0].hostname // "tappaas1"' "${CONFIG_FILE}" 2>/dev/null
}

# Echo the cluster-wide list of VM config files whose NIC carries VLAN <tag>.
# /etc/pve is a shared cluster filesystem, so one node sees every node's confs.
vms_using_vlan() {
    local tag="$1" node
    node="$(_primary_node)"
    ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=6 \
        "root@${node}.mgmt.internal" \
        "grep -lE 'tag=${tag}([,]|\$)' /etc/pve/nodes/*/qemu-server/*.conf 2>/dev/null" \
        2>/dev/null || true
}

# ── add ──────────────────────────────────────────────────────────────
cmd_add() {
    local name="${1:-}"; shift || true
    local from_zone="" vlan="" type="" typeId="" variant=""
    local no_bridge=0 activate=1 dry=0 ssl_flag="--no-ssl-verify"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from-zone)   from_zone="${2:-}"; shift 2;;
            --type)        type="${2:-}"; shift 2;;
            --typeId)      typeId="${2:-}"; shift 2;;
            --vlan)        vlan="${2:-}"; shift 2;;
            --variant)     variant="${2:-}"; shift 2;;
            --no-bridge-apply) no_bridge=1; shift;;
            --no-activate) activate=0; shift;;
            --check)       dry=1; shift;;
            --zones-file)  shift 2;;   # honored via global; accepted for symmetry
            --no-ssl-verify) ssl_flag="--no-ssl-verify"; shift;;
            -h|--help)     usage; exit 0;;
            *) die "Unknown option for add: $1";;
        esac
    done

    # ── preflight ──
    [[ -n "${name}" ]] || die "add requires a zone <name>"
    [[ "${name}" =~ ^[a-z][a-zA-Z0-9]*$ ]] \
        || die "zone name '${name}' must be camelCase (^[a-z][a-zA-Z0-9]*\$, no hyphens — see #278)"
    [[ -f "${ZONES_FILE}" ]] || die "zones.json not found at ${ZONES_FILE}"
    jq -e --arg z "${name}" 'has($z)|not' "${ZONES_FILE}" >/dev/null 2>&1 \
        || die "Zone '${name}' already exists in ${ZONES_FILE}"

    # ── resolve template (inherit from --from-zone, else Service default) ──
    local bridge access_to pinhole parent=""
    if [[ -n "${from_zone}" ]]; then
        jq -e --arg z "${from_zone}" 'has($z)' "${ZONES_FILE}" >/dev/null 2>&1 \
            || die "--from-zone '${from_zone}' not found in ${ZONES_FILE}"
        typeId="${typeId:-$(jq -r --arg z "${from_zone}" '.[$z].typeId' "${ZONES_FILE}")}"
        type="${type:-$(jq -r --arg z "${from_zone}" '.[$z].type' "${ZONES_FILE}")}"
        bridge="$(jq -r --arg z "${from_zone}" '.[$z].bridge // "lan"' "${ZONES_FILE}")"
        access_to="$(jq -c --arg z "${from_zone}" '.[$z]["access-to"] // []' "${ZONES_FILE}")"
        pinhole="$(jq -c --arg z "${from_zone}" '.[$z]["pinhole-allowed-from"] // []' "${ZONES_FILE}")"
        parent="${from_zone}"
    else
        typeId="${typeId:-2}"; type="${type:-Service}"; bridge="lan"
        access_to='["internet","dmz"]'; pinhole='[]'
    fi
    [[ "${typeId}" =~ ^[0-9]+$ ]] || die "typeId must be numeric (got '${typeId}')"

    # ── allocate VLAN tag + subnet ──
    local sub vt
    if [[ -n "${vlan}" ]]; then
        [[ "${vlan}" =~ ^[0-9]+$ ]] || die "--vlan must be numeric"
        vt="${vlan}"; sub=$((vt % 100))
        jq -e --argjson t "${vt}" 'any(.[]?; (.vlantag // -1) == $t)' "${ZONES_FILE}" >/dev/null 2>&1 \
            && die "VLAN ${vt} is already in use"
    else
        sub=""
        local s
        for ((s = ZONE_SUB_MAX; s >= ZONE_SUB_MIN; s--)); do
            vt=$((typeId * 100 + s))
            if ! jq -e --argjson t "${vt}" 'any(.[]?; (.vlantag // -1) == $t)' "${ZONES_FILE}" >/dev/null 2>&1; then
                sub="${s}"; break
            fi
        done
        [[ -n "${sub}" ]] || die "No free VLAN in type ${typeId} (${typeId}${ZONE_SUB_MIN}-${typeId}${ZONE_SUB_MAX} all used)"
        vt=$((typeId * 100 + sub))
    fi
    local ip="10.${typeId}.${sub}.0/24"
    local descr
    if [[ -n "${variant}" ]]; then
        descr="Variant zone for ${variant}${parent:+ (inherited from ${parent})}"
    else
        descr="Zone ${name}${parent:+ (inherited from ${parent})}"
    fi

    local dtag=""; [[ "${dry}" -eq 1 ]] && dtag=" [dry-run]"
    info "zone-controller add '${name}': type=${type} vlan=${vt} ip=${ip}${parent:+ parent=${parent}}${variant:+ variant=${variant}}${dtag}"

    if [[ "${dry}" -eq 1 ]]; then
        info "  [dry-run] would author zones.json entry, append '${name}' to mgmt.access-to,"
        info "  [dry-run] run zone-manager --execute, distribute, proxmox-manager reconcile/bridge-vids --apply"
        echo "${name}"
        return 0
    fi

    # ── 1. author the zone entry (atomic) ──
    jq_write "${ZONES_FILE}" \
        --arg z "${name}" --arg type "${type}" --arg typeId "${typeId}" \
        --arg subId "${sub}" --argjson vlantag "${vt}" --arg ip "${ip}" \
        --arg bridge "${bridge}" --argjson access "${access_to}" \
        --argjson pinhole "${pinhole}" --arg parent "${parent}" \
        --arg variant "${variant}" --arg descr "${descr}" '
        .[$z] = ({
            type: $type, typeId: $typeId, subId: $subId, vlantag: $vlantag,
            ip: $ip, bridge: $bridge, state: "Active",
            "access-to": $access, "pinhole-allowed-from": $pinhole,
            description: $descr
        }
        + (if $parent  == "" then {} else { parent: $parent }   end)
        + (if $variant == "" then {} else { variant: $variant } end))'
    info "  ${GN}✓${CL} authored zone '${name}' in zones.json"

    # ── 2. mgmt reachability invariant (explicit list; see design doc) ──
    ensure_mgmt_access "${name}"

    if [[ "${activate}" -eq 0 ]]; then
        info "Zone '${name}' authored (activation skipped: --no-activate)"
        echo "${name}"
        return 0
    fi

    # ── 3. reconcile OPNsense ──
    activate_opnsense "${ssl_flag}" || warn "zone-manager --execute returned non-zero; activate manually"

    # ── 4. distribute zones.json to the Proxmox nodes ──
    distribute_zones_to_nodes || warn "Could not distribute zones.json — module installs into '${name}' may fail"

    # ── 5. update Proxmox LAN ports across the nodes ──
    update_proxmox_add "${no_bridge}"

    info "${GN}✓${CL} zone '${name}' created (VLAN ${vt}, ${ip})"
    echo "${name}"
}

# ── delete ───────────────────────────────────────────────────────────
cmd_delete() {
    local name="${1:-}"; shift || true
    local force=0 keep_vid=0 dry=0 ssl_flag="--no-ssl-verify"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)         force=1; shift;;
            --keep-bridge-vid) keep_vid=1; shift;;
            --check)         dry=1; shift;;
            --zones-file)    shift 2;;
            --no-ssl-verify) ssl_flag="--no-ssl-verify"; shift;;
            -h|--help)       usage; exit 0;;
            *) die "Unknown option for delete: $1";;
        esac
    done

    [[ -n "${name}" ]] || die "delete requires a zone <name>"
    [[ -f "${ZONES_FILE}" ]] || die "zones.json not found at ${ZONES_FILE}"
    jq -e --arg z "${name}" 'has($z)' "${ZONES_FILE}" >/dev/null 2>&1 \
        || die "Zone '${name}' not found in ${ZONES_FILE}"
    local vt; vt="$(jq -r --arg z "${name}" '.[$z].vlantag // empty' "${ZONES_FILE}")"

    # preflight: refuse if VMs still run in the zone (unless --force)
    local in_use; in_use="$(vms_using_vlan "${vt}")"
    if [[ -n "${in_use}" ]]; then
        warn "VMs still on VLAN ${vt}:"; warn "${in_use}"
        [[ "${force}" -eq 1 ]] || die "Refusing to delete zone '${name}' — VMs still present (pass --force)"
        keep_vid=1   # never strip a VID from the bridge while a VM uses it
        warn "  --force: proceeding, but keeping VLAN ${vt} in node bridge-vids (VMs still using it)"
    fi

    local dtag=""; [[ "${dry}" -eq 1 ]] && dtag=" [dry-run]"
    local ktag=""; [[ "${keep_vid}" -eq 1 ]] && ktag=" (keep VID ${vt})"
    info "zone-controller delete '${name}' (VLAN ${vt})${dtag}"
    if [[ "${dry}" -eq 1 ]]; then
        info "  [dry-run] would remove '${name}' from mgmt.access-to, disable + reconcile (drop OPNsense iface),"
        info "  [dry-run] proxmox-manager reconcile/bridge-vids --apply${ktag}, then delete the key"
        return 0
    fi

    # 1. mgmt invariant
    remove_mgmt_access "${name}"

    # 2. disable the zone so zone-manager tears down its OPNsense iface/DHCP/rules
    jq_write "${ZONES_FILE}" --arg z "${name}" '.[$z].state = "Disabled"'
    info "  ${GN}✓${CL} zone '${name}' set Disabled"

    # 3. reconcile OPNsense (removes the disabled zone's interface/VLAN/rules)
    activate_opnsense "${ssl_flag}" || warn "zone-manager --execute returned non-zero; verify OPNsense manually"

    # 4. update Proxmox: drop trunk + (guarded) bridge-vid
    update_proxmox_delete "${keep_vid}"

    # 5. remove the key + distribute
    jq_write "${ZONES_FILE}" --arg z "${name}" 'del(.[$z])'
    distribute_zones_to_nodes || warn "Could not distribute zones.json after delete"

    info "${GN}✓${CL} zone '${name}' deleted"
}

# ── shared orchestration helpers ─────────────────────────────────────
ensure_mgmt_access() {
    local z="$1"
    if jq -e --arg z "${z}" '(.mgmt["access-to"] // []) | index($z)' "${ZONES_FILE}" >/dev/null 2>&1; then
        debug "  mgmt.access-to already lists '${z}'"
        return 0
    fi
    jq_write "${ZONES_FILE}" --arg z "${z}" '.mgmt["access-to"] = ((.mgmt["access-to"] // []) + [$z])'
    info "  ${GN}✓${CL} appended '${z}' to mgmt.access-to (operational-visibility invariant)"
}

remove_mgmt_access() {
    local z="$1"
    jq_write "${ZONES_FILE}" --arg z "${z}" '.mgmt["access-to"] = ((.mgmt["access-to"] // []) | map(select(. != $z)))'
    info "  ${GN}✓${CL} removed '${z}' from mgmt.access-to"
}

activate_opnsense() {
    local ssl_flag="$1"
    command -v zone-manager >/dev/null 2>&1 || { warn "zone-manager not on PATH — reconcile OPNsense manually"; return 1; }
    info "  reconciling OPNsense (zone-manager --execute)…"
    zone-manager "${ssl_flag}" --zones-file "${ZONES_FILE}" --execute
}

update_proxmox_add() {
    local no_bridge="$1"
    if ! command -v proxmox-manager >/dev/null 2>&1; then
        warn "proxmox-manager not on PATH — trunk the new VLAN to the firewall VM and add it to node"
        warn "  bridge-vids manually, or VMs in the new zone get no IP"
        return 0
    fi
    info "  updating per-VM trunks (proxmox-manager reconcile --apply)…"
    proxmox-manager reconcile --apply || warn "proxmox-manager reconcile reported drift/errors"
    if [[ "${no_bridge}" -eq 1 ]]; then
        warn "  --no-bridge-apply: skipping node bridge-vids — VMs off the firewall node get no IP until applied"
        return 0
    fi
    # Adding a VID only widens the bridge allow-list (non-disruptive) → auto-apply.
    info "  adding the VLAN to node lan bridges (proxmox-manager bridge-vids --apply)…"
    proxmox-manager bridge-vids --apply || warn "proxmox-manager bridge-vids reported errors — verify node bridges"
}

update_proxmox_delete() {
    local keep_vid="$1"
    command -v proxmox-manager >/dev/null 2>&1 || { warn "proxmox-manager not on PATH — clean node trunks/bridge-vids manually"; return 0; }
    info "  dropping the firewall trunk (proxmox-manager reconcile --apply)…"
    proxmox-manager reconcile --apply || warn "proxmox-manager reconcile reported drift/errors"
    if [[ "${keep_vid}" -eq 1 ]]; then
        info "  keeping the VLAN in node bridge-vids (--keep-bridge-vid or VMs still using it)"
        return 0
    fi
    # Removing a VID is the sensitive direction — only reached when no VM uses it.
    info "  removing the VLAN from node lan bridges (proxmox-manager bridge-vids --apply)…"
    proxmox-manager bridge-vids --apply || warn "proxmox-manager bridge-vids reported errors — verify node bridges"
}

# ── dispatch ─────────────────────────────────────────────────────────
main() {
    local cmd="${1:-}"; shift || true
    case "${cmd}" in
        add)    cmd_add "$@";;
        delete) cmd_delete "$@";;
        -h|--help|help|"") usage; exit 0;;
        *) error "Unknown command: ${cmd}"; usage; exit 1;;
    esac
}

main "$@"
