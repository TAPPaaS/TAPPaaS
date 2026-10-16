#!/usr/bin/env bash
#
# TAPPaaS lan uplink (lan-uplink.sh) — #40
#
# A node's `lan` bridge carries management, corosync, backup sync and every guest
# VLAN. On one port behind one switch, a port or switch failure takes all of it
# down at once, and with HA's watchdog armed the node resets. This script keeps
# that uplink declared and converged: one port, or a bond of several (`lanbond`):
#   active-backup  one leg carries traffic, the primary when it is up — any
#                  switches, any mix of speeds (10G + 1G); the default
#   lacp           802.3ad: equal speeds, and the switch side one LAG (a single
#                  switch, or a stack/MLAG pair)
#
# The declaration is the node's pvehost instance, config/<node>.json `uplinks`,
# ports by MAC (kernel names move):
#   "uplinks": {"lan": {"ports": ["<mac>", ...], "mode": "...", "primary": "<mac>", "mtu": n},
#               "wan": {"ports": ["<mac>"]}}
#
# Usage (site-manager node network … calls these):
#   lan-uplink.sh show <node> [--json]
#       Declared next to live: members, mode, state, speed, LACP aggregator, the
#       switch each port reaches (LLDP), corosync — and what is wrong with it.
#   lan-uplink.sh set <node> [--lan-ports <a,b>] [--lan-mode active-backup|lacp]
#                            [--lan-primary <p>] [--mtu <n>] [--config-only]
#                            [--dry-run|--execute] [--yes]
#       Declares the uplink (ports by name or MAC), then converges the node to it:
#       a preview by default; --execute drains the node (HA maintenance), carries
#       lan on the new ports under a 45s commit-confirmed rollback, checks it from
#       here (mgmt, members up, LACP aggregated, corosync) and only then confirms,
#       and brings the node back. Without --lan-ports it converges the declaration
#       there is. --config-only declares without contacting the node (MACs only).
#   lan-uplink.sh test <node> [--dry-run|--execute] [--yes]
#       Fails each leg over in turn on a drained node: the leg goes down for ~10s
#       while mgmt and corosync must stay up; a timer on the node brings it back
#       after 30s whatever happens here.
#   lan-uplink.sh capture <node>
#       Records the live layout as the declaration when none exists (the cluster
#       update runs it for every node). Changes nothing on the node.
#   lan-uplink.sh ensure-lldp <node>
#       lldpd, receive-only: the node learns which switch each port reaches and
#       announces nothing.
#
# Exit codes: 0 done / nothing to do, 1 failed, 2 bad usage, 3 refused (unsafe).

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/reboot-node-lib.sh disable=SC1091
. "${SCRIPT_DIR}/lib/reboot-node-lib.sh"
# shellcheck source=lib/lan-uplink-lib.sh disable=SC1091
. "${SCRIPT_DIR}/lib/lan-uplink-lib.sh"
# shellcheck source=lib/lan-bond-lib.sh disable=SC1091
. "${SCRIPT_DIR}/lib/lan-bond-lib.sh"

readonly ROLLBACK_SECS=45             # under the 60s HA watchdog
readonly CONFIRM_BY=30                # seconds this side has to confirm in
readonly LOCK=/tmp/tappaas-lan-uplink.lock

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; /^set -euo/d'; }

CMD="${1:-}"; shift || true
NODE="" JSON=0 LAN_PORTS="" LAN_MODE="" LAN_PRIMARY="" LAN_MTU="" CONFIG_ONLY=0 EXECUTE=0 YES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)        JSON=1 ;;
        --lan-ports|--lan-port) LAN_PORTS="${2:-}"; shift ;;
        --lan-mode)    LAN_MODE="${2:-}"; shift ;;
        --lan-primary) LAN_PRIMARY="${2:-}"; shift ;;
        --mtu)         LAN_MTU="${2:-}"; shift ;;
        --config-only) CONFIG_ONLY=1 ;;
        --dry-run)     EXECUTE=0 ;;
        --execute)     EXECUTE=1 ;;
        --yes)         YES=1 ;;
        -h|--help)     usage; exit 0 ;;
        -*)            error "unknown option: $1"; exit 2 ;;
        *)             NODE="$1" ;;
    esac
    shift
done
[[ -n "${CMD}" && -n "${NODE}" ]] || { usage; exit 2; }
[[ -z "${LAN_MTU}" || "${LAN_MTU}" =~ ^[0-9]+$ ]] || die "--mtu: not a number"
CFG="${CONFIG_DIR}/${NODE}.json"

# ── reading ────────────────────────────────────────────────────────────

# rn_node_ssh never reads stdin (-n); a script fed to the node needs this one.
node_ssh_stdin() {
    ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$(rn_node_fqdn "${NODE}")" "$@"
}
probe() { node_ssh_stdin 'bash -s' < <(lu_probe_script); }
declared() { jq -c '.uplinks // null' "${CFG}" 2>/dev/null || echo null; }
report() {  # <live> → {node, live, declared, findings}
    local base
    base="$(jq -cn --arg n "${NODE}" --argjson l "$1" --argjson d "$(declared)" '{node: $n, live: $l, declared: $d}')"
    jq -c --argjson f "$(lu_findings <<<"${base}")" '. + {findings: $f}' <<<"${base}"
}
need_pvehost() {
    [[ -f "${CFG}" ]] || die "${NODE} has no config/${NODE}.json — is it a node of this site? (site-manager node list)"
    [[ "$(jq -r '.moduleSource // ""' "${CFG}")" == */pvehost ]] \
        || die "config/${NODE}.json is not a pvehost instance — not a cluster node"
}

show_human() {  # <report>
    local r="$1"
    info "${BOLD}${NODE} — lan uplink${CL}"
    jq -r '
      def lldp: if .lldp == null then "-" else "\(.lldp.name // .lldp.chassis) \(.lldp.port)" end;
      def spd: if .speed < 0 then "-" elif .speed >= 1000 then "\(.speed / 1000)G" else "\(.speed)M" end;
      .live.lan as $l
      | "  live      \($l.mode)\(if $l.bond != "" then " (\($l.bond))" else "" end)  mtu \($l.mtu)"
        + (if $l.mode == "active-backup" then "  active \($l.active), primary \($l.primary)" else "" end)
        + (if $l.mode == "lacp" then "  aggregator \($l.aggregator), partner \($l.partnerMac)" else "" end),
        ($l.members[] | "    \(.name)\t\(.mac)  \(spd)\t\(.state)\(if .aggregator != "" then "  agg \(.aggregator)" else "" end)\t→ \(lldp)"),
        "  wan       \([.live.wan.members[].name] | join(", ") | if . == "" then "-" else . end)",
        "  declared  \(if .declared == null or .declared.lan == null then "nothing"
                       else "\(.declared.lan.mode // "-") on \(.declared.lan.ports | join(", "))"
                            + (if .declared.lan.primary then ", primary \(.declared.lan.primary)" else "" end) end)",
        "  ha        \(if .live.lrmActive then "LRM active — the watchdog is armed" else "LRM idle" end);  corosync \(.live.corosync.links) link(s), \(.live.corosync.disconnected) disconnected;  lldpd \(.live.lldpd)"
    ' <<<"${r}"
    local n; n="$(jq '.findings | length' <<<"${r}")"
    if [[ "${n}" == 0 ]]; then info "  ${GN}✓${CL} nothing to report"; return 0; fi
    jq -r '.findings[] | "\(.level)\t\(.text)"' <<<"${r}" | while IFS=$'\t' read -r lvl txt; do
        if [[ "${lvl}" == warn ]]; then warn "  ${txt}"; else info "  ${BL}·${CL} ${txt}"; fi
    done
}

# ── writing the declaration ────────────────────────────────────────────

write_declared() {  # <uplinks-json>: replaces .uplinks.lan, keeps .uplinks.wan unless given
    local u="$1" tmp
    tmp="$(mktemp "${CFG}.XXXX")"
    jq --argjson u "${u}" '.uplinks = ((.uplinks // {}) + $u)' "${CFG}" > "${tmp}" \
        || { rm -f "${tmp}"; die "could not write config/${NODE}.json"; }
    chmod --reference="${CFG}" "${tmp}" 2>/dev/null || true
    mv "${tmp}" "${CFG}"
}

# The lan declaration from the flags, checked against the node when <live> is
# given (names → MACs, speeds for lacp, the primary). Prints {lan: {...}}.
declaration_from_flags() {
    local live="${1:-}" pairs names macs n mode primary="" err
    if [[ -n "${live}" ]]; then
        pairs="$(lu_resolve_ports "${live}" "${LAN_PORTS}")" || exit 2
        names="$(awk '{print $1}' <<<"${pairs}" | paste -sd' ' -)"
        macs="$(awk '{print $2}' <<<"${pairs}" | paste -sd' ' -)"
        local wanm
        wanm=" $(jq -r '[.wan.members[].mac] | join(" ")' <<<"${live}") "
        for m in ${macs}; do [[ "${wanm}" == *" ${m} "* ]] && die "$(awk -v m="$m" '$2==m{print $1}' <<<"${pairs}") is the wan bridge's port"; done
    else
        names="$(lb_ports "${LAN_PORTS}")" || exit 2
        for m in ${names}; do [[ "${m,,}" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || die "--config-only names ports by MAC (${m} is not one) — nothing can look the name up"; done
        macs="${names,,}"
    fi
    n="$(wc -w <<<"${macs}" | tr -d ' ')"
    err="$(lb_mode "${n}" "${LAN_MODE}" 2>&1 >/dev/null)" || die "${err}"
    mode="$(lb_mode "${n}" "${LAN_MODE}")"
    if [[ -n "${live}" ]]; then
        LB_SPEED_CMD=live_speed; LIVE_FOR_SPEED="${live}"
        if [[ "${mode}" == lacp ]] && ! err="$(lb_equal_speeds "${names}" 2>&1)"; then
            [[ "${err}" == *=-1* ]] && warn "lacp: a port's speed is unknown (${err}) — LACP needs equal speeds" >&2 \
                || die "lacp needs ports of equal speed (${err}) — use --lan-mode active-backup"
        fi
        if [[ "${mode}" == active-backup ]]; then
            if [[ -n "${LAN_PRIMARY}" ]]; then
                primary="$(lu_resolve_ports "${live}" "${LAN_PRIMARY}" | awk '{print $2}')" || exit 2
                [[ " ${macs} " == *" ${primary} "* ]] || die "--lan-primary ${LAN_PRIMARY} is not one of the lan ports"
            else
                primary="$(awk -v p="$(lb_default_primary "${names}")" '$1==p{print $2}' <<<"${pairs}")"
            fi
        fi
    elif [[ "${mode}" == active-backup && -n "${LAN_PRIMARY}" ]]; then
        primary="${LAN_PRIMARY,,}"
        [[ " ${macs} " == *" ${primary} "* ]] || die "--lan-primary ${LAN_PRIMARY} is not one of the lan ports"
    fi
    # stdout is the declaration: everything said here goes to stderr.
    [[ "${mode}" == active-backup || -z "${LAN_PRIMARY}" ]] || warn "--lan-primary applies to active-backup only — ignored" >&2
    jq -cn --arg macs "${macs}" --arg mode "${mode}" --arg p "${primary}" --arg mtu "${LAN_MTU}" \
        '{lan: ({ports: ($macs | split(" ")), mode: $mode}
                + (if $p != "" then {primary: $p} else {} end)
                + (if $mtu != "" then {mtu: ($mtu | tonumber)} else {} end))}'
}
LIVE_FOR_SPEED=""
live_speed() { jq -r --arg n "$1" '.ports[] | select(.name == $n) | .speed' <<<"${LIVE_FOR_SPEED}"; }

# ── converging ─────────────────────────────────────────────────────────

# The config-network.sh arguments that carry the declaration on <live>'s ports.
setlan_args() {  # <live> <decl-lan>
    local gone
    gone="$(jq -r --argjson l "$1" '[.ports[] | ascii_downcase | select(. as $m | [$l.ports[].mac] | index($m) | not)] | join(", ")' <<<"$2")"
    [[ -z "${gone}" ]] || { error "declared port(s) ${gone} not on ${NODE} — declare again: --lan-ports"; return 1; }
    jq -r --argjson l "$1" '
        def name($m): [$l.ports[] | select(.mac == ($m | ascii_downcase)) | .name][0];
        ["--lan-port", ([.ports[] | name(.)] | join(","))]
        + (if (.ports | length) > 1 then ["--lan-mode", (.mode // "active-backup")] else [] end)
        + (if (.primary // "") != "" and (.mode // "active-backup") == "active-backup" then ["--lan-primary", name(.primary)] else [] end)
        + (if .mtu then ["--mtu", (.mtu | tostring)] else [] end)
        | @sh' <<<"$2"
}

drift() {  # <report> → true when live differs from the declaration
    jq -e '[.findings[] | select(.text | startswith("drift:"))] | length > 0' <<<"$1" >/dev/null
}

confirm() {  # <what>
    [[ "${YES}" == 1 ]] && return 0
    warn "${BOLD}$1${CL}"
    read -rp "  Type the node name to confirm (or Ctrl-C to abort): " _c </dev/tty
    [[ "${_c}" == "${NODE}" ]] || die "confirmation mismatch — nothing changed"
}

# Is the node, seen from here, on its declared uplink and healthy? <decl-lan>
verified() {
    local live r
    live="$(probe 2>/dev/null)" || return 1
    r="$(jq -cn --argjson l "${live}" --argjson d "{\"lan\": $1}" --arg n "${NODE}" '{node: $n, live: $l, declared: $d}' | lu_findings)"
    # Drift, a leg down, no LAG, corosync down: not confirmed. LLDP and the like are advice.
    ! jq -e '[.[] | select(.level == "warn") | select(.text | test("^drift:|is down|LACP partner|outside the active aggregator|corosync"))] | length > 0' <<<"${r}" >/dev/null
}

converge() {  # <decl-lan>
    local decl="$1" live args res t
    live="$(probe)" || die "cannot reach ${NODE}"
    if ! drift "$(report "${live}")"; then
        info "${GN}✓${CL} ${NODE}'s lan is already on its declared uplink — nothing to change"
        return 0
    fi
    args="$(setlan_args "${live}" "${decl}")" || exit 1

    info "${BOLD}Converging ${NODE}'s lan uplink${CL}: config-network.sh --set-lan ${args//\'/}"
    # The node shows the exact change; nothing is written.
    rn_node_ssh "${NODE}" "mkdir -p /root/tappaas/lan-uplink" \
        && scp -q -o BatchMode=yes "${SCRIPT_DIR}/config-network.sh" "${SCRIPT_DIR}/lib/lan-bond-lib.sh" \
               "root@$(rn_node_fqdn "${NODE}"):/root/tappaas/lan-uplink/" \
        || die "could not copy config-network.sh to ${NODE}"
    rn_node_ssh "${NODE}" "/root/tappaas/lan-uplink/config-network.sh --set-lan --dry-run --non-interactive ${args}" \
        || die "the node refused the change (above) — nothing written"
    if [[ "${EXECUTE}" != 1 ]]; then
        info "${YW}Preview only.${CL} To apply: site-manager node network set ${NODE} --apply"
        info "  It drains ${NODE} (HA maintenance), applies under a ${ROLLBACK_SECS}s rollback, checks from here, brings ${NODE} back."
        return 0
    fi

    exec 9>"${LOCK}"
    flock -n 9 || die "another lan uplink change is running on this site — one node at a time"
    confirm "Re-carry ${NODE}'s lan bridge: its HA guests move off first, and lan blips while the uplink changes."

    RN_DRAIN_FOR=changed
    local drc=0
    rn_drain_node "${NODE}" || drc=$?
    [[ ${drc} -eq 0 ]] || { [[ ${drc} -eq 3 ]] && exit 3; die "${NODE} not drained — nothing changed"; }

    local ok=0
    info "  Applying on ${NODE} (it reverts by itself unless confirmed within ${ROLLBACK_SECS}s)..."
    rn_node_ssh "${NODE}" "systemd-run --quiet --collect --unit=tappaas-set-lan /root/tappaas/lan-uplink/config-network.sh --set-lan --apply --non-interactive --confirm-external --rollback-secs ${ROLLBACK_SECS} ${args}" \
        || warn "  could not start the change on ${NODE}"
    for (( t=0; t<CONFIRM_BY; t+=3 )); do
        sleep 3
        res="$(ssh -n -o BatchMode=yes -o ConnectTimeout=3 "root@$(rn_node_fqdn "${NODE}")" \
               'cat /run/tappaas-net-set-lan 2>/dev/null' 2>/dev/null || true)"
        case "${res}" in
            ok)
                if verified "${decl}"; then
                    rn_node_ssh "${NODE}" "touch /run/tappaas-net-ok" && { ok=1; break; }
                fi ;;
            fail*) warn "  ${NODE}: ${res#fail }"; break ;;
        esac
    done
    if [[ "${ok}" == 1 ]]; then
        info "  ${GN}✓${CL} ${NODE} is on its declared uplink — change confirmed"
    else
        warn "  Not confirmed — ${NODE} reverts to its previous uplink. Waiting for it..."
        sleep $(( ROLLBACK_SECS + 10 ))
        res="$(ssh -n -o BatchMode=yes -o ConnectTimeout=5 "root@$(rn_node_fqdn "${NODE}")" \
               'cat /run/tappaas-net-set-lan 2>/dev/null' 2>/dev/null || true)"
        [[ "${res}" == reverted ]] && info "  ${NODE} reverted and answers again" \
            || warn "  ${NODE} does not answer as reverted (${res:-no answer}) — check its console before anything else"
    fi
    rn_undrain_node "${NODE}" || warn "  ${NODE} is still in HA maintenance — clear it: ha-manager crm-command node-maintenance disable ${NODE}"
    [[ "${ok}" == 1 ]] || die "${NODE}'s lan uplink was not changed (reverted)"
    show_human "$(report "$(probe)")"
}

# ── test: fail each leg over ───────────────────────────────────────────

leg_test() {
    local live members m pass=1 t
    live="$(probe)" || die "cannot reach ${NODE}"
    members="$(jq -r '.lan.members[].name' <<<"${live}")"
    [[ "$(wc -l <<<"${members}")" -ge 2 ]] || die "${NODE}'s lan has one port — nothing to fail over to"
    jq -cn --arg n "${NODE}" --argjson l "${live}" '{node: $n, live: $l, declared: null}' | lu_findings \
        | jq -e '[.[] | select(.text | test("is down|LACP partner|outside the active aggregator|corosync"))] | length == 0' >/dev/null \
        || die "${NODE}'s lan is not healthy now — fix that first (site-manager node network show ${NODE})"
    info "${BOLD}Failover test on ${NODE}${CL}: each of $(paste -sd' ' - <<<"${members}") goes down for 10s in turn"
    if [[ "${EXECUTE}" != 1 ]]; then
        info "${YW}Preview only.${CL} To run it: site-manager node network test ${NODE} --apply (drains ${NODE} first)"
        return 0
    fi
    exec 9>"${LOCK}"
    flock -n 9 || die "another lan uplink change is running on this site — one node at a time"
    confirm "Take each of ${NODE}'s lan legs down in turn (its HA guests move off first)."
    RN_DRAIN_FOR=tested
    local drc=0
    rn_drain_node "${NODE}" || drc=$?
    [[ ${drc} -eq 0 ]] || { [[ ${drc} -eq 3 ]] && exit 3; die "${NODE} not drained — nothing tested"; }

    while read -r m; do
        info "  ${m} down..."
        # The restore is the node's own timer: if the other leg does not carry
        # lan, nothing from here can reach the node to bring this one back.
        timeout 15 ssh -n -o BatchMode=yes -o ConnectTimeout=5 "root@$(rn_node_fqdn "${NODE}")" \
            "systemd-run --quiet --collect --unit=tappaas-lan-test-restore --on-active=30 ip link set ${m} up && ip link set ${m} down" \
            || true
        sleep 10
        if rn_node_ssh "${NODE}" true 2>/dev/null \
           && [[ "$(rn_node_ssh "${NODE}" "corosync-cfgtool -s | grep -c disconnected" 2>/dev/null || echo 1)" == 0 ]]; then
            info "  ${GN}✓${CL} without ${m}: mgmt and corosync up"
        else
            warn "  without ${m}: ${NODE} lost mgmt or corosync — the other leg does not carry lan"
            pass=0
        fi
        rn_node_ssh "${NODE}" "ip link set ${m} up; systemctl stop tappaas-lan-test-restore.timer" 2>/dev/null || true
        for (( t=0; t<45; t+=3 )); do
            jq -e --arg m "${m}" '.lan.members[] | select(.name == $m) | .state == "up" and (.mii == "" or .mii == "up")' \
                <<<"$(probe 2>/dev/null || echo '{"lan":{"members":[]}}')" >/dev/null 2>&1 && break
            sleep 3
        done
        sleep 5   # let LACP re-aggregate before the next leg goes
    done <<<"${members}"

    rn_undrain_node "${NODE}" || warn "  ${NODE} is still in HA maintenance — clear it: ha-manager crm-command node-maintenance disable ${NODE}"
    [[ "${pass}" == 1 ]] || die "failover test FAILED on ${NODE} — see above"
    info "${GN}✓${CL} every leg of ${NODE}'s lan failed over cleanly"
}

# ── commands ───────────────────────────────────────────────────────────

case "${CMD}" in
    show)
        need_pvehost
        r="$(report "$(probe)")" || die "cannot reach ${NODE}"
        if [[ "${JSON}" == 1 ]]; then jq . <<<"${r}"; else show_human "${r}"; fi
        ;;
    set)
        need_pvehost
        if [[ -n "${LAN_PORTS}" ]]; then
            if [[ "${CONFIG_ONLY}" == 1 ]]; then
                d="$(declaration_from_flags)"
            else
                live="$(probe)" || die "cannot reach ${NODE} (--config-only declares without it, by MAC)"
                d="$(declaration_from_flags "${live}")"
            fi
            write_declared "${d}"
            info "${GN}✓${CL} declared in config/${NODE}.json: $(jq -c .lan <<<"${d}")"
        else
            [[ -z "${LAN_MODE}${LAN_PRIMARY}${LAN_MTU}" ]] || die "--lan-mode/--lan-primary/--mtu go with --lan-ports"
            [[ "$(declared | jq -c '.lan // null')" != null ]] || die "nothing declared for ${NODE} — give --lan-ports"
        fi
        [[ "${CONFIG_ONLY}" == 1 ]] && exit 0
        converge "$(declared | jq -c .lan)"
        ;;
    test)
        need_pvehost
        leg_test
        ;;
    capture)
        need_pvehost
        if [[ "$(declared | jq -c '.lan // null')" != null ]]; then debug "  ${NODE}: uplinks declared"; exit 0; fi
        live="$(probe)" || { warn "  ${NODE}: not reachable — uplinks not recorded"; exit 0; }
        [[ "$(jq '.lan.members | length' <<<"${live}")" -gt 0 ]] || { warn "  ${NODE}: no lan bridge — nothing recorded"; exit 0; }
        write_declared "$(lu_declaration <<<"${live}")"
        info "  ${GN}✓${CL} ${NODE}: uplinks recorded — lan $(jq -r '"\(.lan.mode) on \([.lan.members[].name] | join(", "))"' <<<"${live}")"
        ;;
    ensure-lldp)
        node_ssh_stdin 'bash -s' <<'LLDP'
set -e
conf=/etc/lldpd.d/tappaas.conf
want='# TAPPaaS (#40): learn which switch each port reaches; announce nothing.
configure lldp status rx-only'
if ! command -v lldpd >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q lldpd >/dev/null 2>/tmp/lldpd-apt.err \
        || { cat /tmp/lldpd-apt.err >&2; exit 1; }
    echo "lldpd installed"
fi
mkdir -p /etc/lldpd.d
if [ "$(cat "$conf" 2>/dev/null)" != "$want" ]; then
    printf '%s\n' "$want" > "$conf"; systemctl restart lldpd; echo "lldpd set receive-only"
fi
systemctl is-enabled -q lldpd || systemctl enable -q lldpd
systemctl is-active -q lldpd || systemctl start lldpd
LLDP
        ;;
    *) usage; exit 2 ;;
esac
