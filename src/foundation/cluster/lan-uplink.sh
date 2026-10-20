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
#                            [--lan-primary <p>] [--mtu <n>] [--no-wan] [--switch-wait <s>] [--config-only]
#                            [--dry-run|--execute] [--yes]
#       Declares the uplink (ports by name or MAC), then converges the node to it:
#       a preview by default; --execute drains the node (HA maintenance), carries
#       lan on the new ports under a 45s commit-confirmed rollback, checks it from
#       here (mgmt, members up, LACP aggregated, corosync) and only then confirms,
#       and brings the node back. Without --lan-ports it converges the declaration
#       there is. --config-only declares without contacting the node (MACs only).
#       --no-wan: the wan bridge gives up its port (declared wan.ports []), so it
#       can join the lan bond — the node can no longer carry the firewall's WAN.
#       --switch-wait <s>: wait up to <s> seconds (instead of 30) for the change to
#       verify — time to configure the switch side, e.g. the LAG for lacp, after
#       the node already speaks it. The rollback grows with it, so it is refused
#       unless the drained node's HA watchdog is released (LRM not active).
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

ROLLBACK_SECS=45                      # under the 60s HA watchdog
CONFIRM_BY=30                         # seconds this side has to confirm in
readonly LOCK=/tmp/tappaas-lan-uplink.lock

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; /^set -euo/d'; }

CMD="${1:-}"; shift || true
NODE="" JSON=0 LAN_PORTS="" LAN_MODE="" LAN_PRIMARY="" LAN_MTU="" CONFIG_ONLY=0 EXECUTE=0 YES=0 NO_WAN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)        JSON=1 ;;
        --lan-ports|--lan-port) LAN_PORTS="${2:-}"; shift ;;
        --lan-mode)    LAN_MODE="${2:-}"; shift ;;
        --lan-primary) LAN_PRIMARY="${2:-}"; shift ;;
        --mtu)         LAN_MTU="${2:-}"; shift ;;
        --config-only) CONFIG_ONLY=1 ;;
        --no-wan)      NO_WAN=1 ;;
        --switch-wait) CONFIRM_BY="${2:-}"; shift ;;
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
[[ "${CONFIRM_BY}" =~ ^[0-9]+$ && "${CONFIRM_BY}" -ge 30 && "${CONFIRM_BY}" -le 1800 ]] \
    || die "--switch-wait: seconds, 30 to 1800"
(( CONFIRM_BY + 15 > ROLLBACK_SECS )) && ROLLBACK_SECS=$(( CONFIRM_BY + 15 ))
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
        [[ "${NO_WAN}" == 1 ]] || for m in ${macs}; do
            [[ "${wanm}" == *" ${m} "* ]] && die "$(awk -v m="$m" '$2==m{print $1}' <<<"${pairs}") is the wan bridge's port (--no-wan moves it into the lan bond)"
        done
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
    jq -cn --arg macs "${macs}" --arg mode "${mode}" --arg p "${primary}" --arg mtu "${LAN_MTU}" --argjson nowan "${NO_WAN}" \
        '{lan: ({ports: ($macs | split(" ")), mode: $mode}
                + (if $p != "" then {primary: $p} else {} end)
                + (if $mtu != "" then {mtu: ($mtu | tonumber)} else {} end))}
         + (if $nowan == 1 then {wan: {ports: []}} else {} end)'
}
LIVE_FOR_SPEED=""
live_speed() { jq -r --arg n "$1" '.ports[] | select(.name == $n) | .speed' <<<"${LIVE_FOR_SPEED}"; }

# ── converging ─────────────────────────────────────────────────────────

# The config-network.sh arguments that carry the declaration on <live>'s ports.
setlan_args() {  # <live> <declaration>
    local gone
    gone="$(jq -r --argjson l "$1" '[.lan.ports[] | ascii_downcase | select(. as $m | [$l.ports[].mac] | index($m) | not)] | join(", ")' <<<"$2")"
    [[ -z "${gone}" ]] || { error "declared port(s) ${gone} not on ${NODE} — declare again: --lan-ports"; return 1; }
    jq -r --argjson l "$1" '
        def name($m): [$l.ports[] | select(.mac == ($m | ascii_downcase)) | .name][0];
        (.wan.ports? // null) as $wan | .lan
        | ["--lan-port", ([.ports[] | name(.)] | join(","))]
        + (if (.ports | length) > 1 then ["--lan-mode", (.mode // "active-backup")] else [] end)
        + (if (.primary // "") != "" and (.mode // "active-backup") == "active-backup" then ["--lan-primary", name(.primary)] else [] end)
        + (if .mtu then ["--mtu", (.mtu | tostring)] else [] end)
        + (if $wan == [] and ($l.wan.members | length) > 0 then ["--no-wan"] else [] end)
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

# Is the node, seen from here, on its declared uplink and healthy? <declaration>
verified() {
    local live r
    live="$(probe 2>/dev/null)" || return 1
    r="$(jq -cn --argjson l "${live}" --argjson d "$1" --arg n "${NODE}" '{node: $n, live: $l, declared: $d}' | lu_findings)"
    # Drift, a leg down, no LAG, corosync down: not confirmed. LLDP and the like are advice.
    ! jq -e '[.[] | select(.level == "warn") | select(.text | test("^drift:|is down|LACP partner|outside the active aggregator|not carrying traffic|corosync"))] | length > 0' <<<"${r}" >/dev/null
}

# ── the switch side of lacp (#40) ──────────────────────────────────────
# A LACP bond needs its switch ports to be one aggregate. switch-manager
# declares and programs it (`lag set|remove … --apply`); the ports are the ones
# its inventory records as this node's lan NICs (type node, target <node>,
# targetPort <nic>). The aggregate is named <node>-lan.
SW_ACTUAL="${CONFIG_DIR}/switch-configuration-actual.json"
LAG_NAME=""
lag_name() { echo "${NODE}-lan"; }
have_switch_controller() { command -v switch-manager >/dev/null 2>&1 && [[ -f "${SW_ACTUAL}" ]]; }

# "<switch>\t<p,p>" for the lan NICs in <names> — or, when they reach the two
# switches of an MLAG pair (#847), "<switch>\t<a>:<p>,<b>:<q>", one aggregate
# across both. Non-zero, naming why, when switch-manager cannot do the switch side
# (the operator then does it by hand, within --switch-wait).
switch_ports_for() {
    local names="$1" rows sw
    rows=$(jq -r --arg n "${NODE}" --arg nics " ${names} " '
        .switches // {} | to_entries[] | .key as $sw | .value.ports // {} | to_entries[]
        | (.value.targetPort // "") as $tp
        | select(.value.type == "node" and .value.target == $n and $tp != "" and ($nics | contains(" \($tp) ")))
        | "\($sw)\t\(.key)\t\(.value.targetPort)"' "${SW_ACTUAL}" 2>/dev/null)
    local nic missing=""
    for nic in ${names}; do awk -F'\t' -v n="${nic}" '$3 == n {f=1} END {exit !f}' <<<"${rows}" || missing+=" ${nic}"; done
    if [[ -n "${missing}" ]]; then
        echo "switch-manager does not know which switch port${missing} reach(es) — register it: switch-manager add-port <switch> <port> --type node --target ${NODE} --target-port <nic>" >&2
        return 1
    fi
    sw=$(cut -f1 <<<"${rows}" | sort -u)
    if [[ "$(wc -l <<<"${sw}")" -eq 1 ]]; then
        printf '%s\t%s\n' "${sw}" "$(cut -f2 <<<"${rows}" | sort -V | paste -sd, -)"
        return 0
    fi
    local a b
    a="$(head -1 <<<"${sw}")"; b="$(sed -n 2p <<<"${sw}")"
    if [[ "$(wc -l <<<"${sw}")" -eq 2 ]] && jq -e --arg a "${a}" --arg b "${b}" \
            'any(.mlagPairs // {} | .[]; (.switches | index($a)) != null and (.switches | index($b)) != null)' "${SW_ACTUAL}" >/dev/null 2>&1; then
        printf '%s\t%s\n' "${a}" "$(awk -F'\t' '{print $1 ":" $2}' <<<"${rows}" | sort -V | paste -sd, -)"
        return 0
    fi
    echo "the lan NICs reach different switches (${sw//$'\n'/, }) that are not an MLAG pair: one LAG cannot span them (switch-manager mlag-pair set, if they can be one)" >&2
    return 1
}
# The switch that holds this node's LAG in the declaration, if any.
switch_with_lag() {
    jq -r --arg l "$(lag_name)" '.switches // {} | to_entries[] | select(any(.value.ports[]?; .lag == $l)) | .key' "${SW_ACTUAL}" 2>/dev/null | head -1
}
switch_lag() {  # set <switch> <ports> | remove <switch> — indented, rc of switch-manager
    local rc=0
    if [[ "$1" == set ]]; then
        switch-manager lag set "$2" "$(lag_name)" --ports "$3" --apply 2>&1 | sed 's/^/    /' || true
        rc=${PIPESTATUS[0]}
    else
        switch-manager lag remove "$2" "$(lag_name)" --apply 2>&1 | sed 's/^/    /' || true
        rc=${PIPESTATUS[0]}
    fi
    return "${rc}"
}

# The node's LRM holds no watchdog: it is in maintenance or idle, and no HA
# service is on the node any more.
watchdog_released() {
    rn_node_ssh "${NODE}" "jq -r .state /etc/pve/nodes/${NODE}/lrm_status; \
        jq -r --arg n ${NODE} '[.service_status // {} | .[] | select(.node == \$n and .state != \"stopped\")] | length' /etc/pve/ha/manager_status" \
        2>/dev/null | { read -r st; read -r n; [[ "${st}" =~ ^(maintenance|wait_for_agent_lock)$ && "${n}" == 0 ]]; }
}

# What keeps the node from verifying, for the wait above. <declaration>
missing() {
    local live
    live="$(probe 2>/dev/null)" || { echo "no answer from ${NODE}"; return; }
    jq -cn --argjson l "${live}" --argjson d "$1" --arg n "${NODE}" '{node: $n, live: $l, declared: $d}' | lu_findings \
        | jq -r '[.[] | select(.level == "warn") | .text | split(" — ")[0]] | join("; ") | if . == "" then "settling" else . end'
}

converge() {  # <declaration>
    local decl="$1" live args res t
    live="$(probe)" || die "cannot reach ${NODE}"
    if ! drift "$(report "${live}")"; then
        info "${GN}✓${CL} ${NODE}'s lan is already on its declared uplink — nothing to change"
        return 0
    fi
    args="$(setlan_args "${live}" "${decl}")" || exit 1

    # The switch side (#40): into lacp the aggregate is formed after the node
    # speaks LACP; out of it, taken apart before. Both through switch-manager,
    # when it knows the ports; otherwise the operator does it within --switch-wait.
    local want_lacp=0 live_lacp=0 sw_set="" sw_ports="" sw_remove="" names
    [[ "$(jq -r '.lan.mode // ""' <<<"${decl}")" == lacp ]] && want_lacp=1
    [[ "$(jq -r '.lan.mode' <<<"${live}")" == lacp ]] && live_lacp=1
    if have_switch_controller; then
        sw_remove="$(switch_with_lag)"
        if [[ "${want_lacp}" == 1 ]]; then
            names="$(jq -r --argjson l "${live}" '[.lan.ports[] | ascii_downcase as $m | $l.ports[] | select(.mac == $m) | .name] | join(" ")' <<<"${decl}")"
            local sp
            if sp="$(switch_ports_for "${names}" 2>/dev/null)"; then
                sw_set="${sp%%$'\t'*}"; sw_ports="${sp#*$'\t'}"
                [[ "${sw_remove}" == "${sw_set}" ]] && sw_remove=""   # set re-declares it there
            else
                # Not automatable (#847): the operator forms the aggregate by
                # hand within --switch-wait, as on a site switch-manager does not know.
                warn "  switch side by hand: $(switch_ports_for "${names}" 2>&1 >/dev/null) — form the aggregate on the switch within --switch-wait"
            fi
            # Forming the aggregate and its LACP negotiation take longer than 30s.
            (( CONFIRM_BY < 180 )) && { CONFIRM_BY=180; ROLLBACK_SECS=195; }
        elif [[ "${live_lacp}" != 1 ]]; then
            sw_remove=""                                       # no LACP on either side
        fi
    elif [[ "${want_lacp}" == 1 || "${live_lacp}" == 1 ]]; then
        warn "  switch-manager does not know this site's switches: configure the aggregate by hand, within --switch-wait"
    fi

    info "${BOLD}Converging ${NODE}'s lan uplink${CL}: config-network.sh --set-lan ${args//\'/}"
    # The node shows the exact change; nothing is written.
    rn_node_ssh "${NODE}" "mkdir -p /root/tappaas/lan-uplink" \
        && scp -q -o BatchMode=yes "${SCRIPT_DIR}/config-network.sh" "${SCRIPT_DIR}/lib/lan-bond-lib.sh" \
               "root@$(rn_node_fqdn "${NODE}"):/root/tappaas/lan-uplink/" \
        || die "could not copy config-network.sh to ${NODE}"
    rn_node_ssh "${NODE}" "/root/tappaas/lan-uplink/config-network.sh --set-lan --dry-run --non-interactive ${args}" \
        || die "the node refused the change (above) — nothing written"
    [[ -n "${sw_remove}" ]] && info "  switch side: take apart LAG $(lag_name) on ${sw_remove} first (switch-manager)"
    [[ -n "${sw_set}" ]] && info "  switch side: ports ${sw_ports} of ${sw_set} become LAG $(lag_name) once ${NODE} speaks LACP (switch-manager)"
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

    # A rollback past the watchdog's 60s is only safe on a node whose LRM has
    # released it: a node cut off longer than that would otherwise fence itself.
    # `ha-manager status` says "watchdog active" for any LRM in maintenance, so
    # ask what the LRM does instead: in maintenance (or idle) with no HA service
    # left on the node it gives the watchdog up (PVE::HA::LRM). Wait for that.
    if (( ROLLBACK_SECS > 45 )); then
        local w=0
        until watchdog_released; do
            (( w == 0 )) && info "  Waiting for ${NODE}'s LRM to release its HA watchdog before a ${ROLLBACK_SECS}s rollback window..."
            if (( w >= ${WATCHDOG_WAIT:-300} )); then
                rn_undrain_node "${NODE}" || true
                die "${NODE}'s HA watchdog was still held after ${w}s drained — a ${ROLLBACK_SECS}s rollback could fence it. Nothing changed."
            fi
            sleep 10; w=$((w + 10))
        done
        info "  ${GN}✓${CL} ${NODE}'s HA watchdog is released"
    fi
    # Out of lacp: the aggregate goes first. The node keeps talking LACP to no
    # partner on one leg meanwhile; were the aggregate left while the node went
    # active-backup, the switch would hash half its frames onto the idle leg.
    local sw_restore=""
    if [[ -n "${sw_remove}" ]]; then
        info "  Taking apart LAG $(lag_name) on ${sw_remove}..."
        if ! switch_lag remove "${sw_remove}"; then
            rn_undrain_node "${NODE}" || true
            die "the switch did not take the aggregate apart — ${NODE} left as it was"
        fi
        [[ "${live_lacp}" == 1 ]] && sw_restore="${sw_remove}"
    fi
    local ok=0 said="" sw_done=0
    info "  Applying on ${NODE} (it reverts by itself unless confirmed within ${ROLLBACK_SECS}s)..."
    (( CONFIRM_BY > 30 )) && info "  ${BOLD}Configure the switch side now${CL} — waiting up to ${CONFIRM_BY}s for it to verify."
    rn_node_ssh "${NODE}" "systemd-run --quiet --collect --unit=tappaas-set-lan /root/tappaas/lan-uplink/config-network.sh --set-lan --apply --non-interactive --confirm-external --rollback-secs ${ROLLBACK_SECS} ${args}" \
        || warn "  could not start the change on ${NODE}"
    for (( t=0; t<CONFIRM_BY; t+=3 )); do
        sleep 3
        res="$(ssh -n -o BatchMode=yes -o ConnectTimeout=3 "root@$(rn_node_fqdn "${NODE}")" \
               'cat /run/tappaas-net-set-lan 2>/dev/null' 2>/dev/null || true)"
        case "${res}" in
            ok)
                # Into lacp: the node speaks it now (on one leg) — form the aggregate.
                if [[ -n "${sw_set}" && "${sw_done}" == 0 ]]; then
                    sw_done=1
                    info "  ${NODE} speaks LACP — forming LAG $(lag_name) on ${sw_set} ports ${sw_ports}..."
                    local src=0; switch_lag set "${sw_set}" "${sw_ports}" || src=$?
                    case "${src}" in
                        0) ;;
                        2) warn "  ${sw_set} is configured by hand: form the aggregate of ports ${sw_ports} now" ;;
                        *) warn "  ${sw_set} did not form the aggregate"; break ;;
                    esac
                fi
                if verified "${decl}"; then
                    rn_node_ssh "${NODE}" "touch /run/tappaas-net-ok" && { ok=1; break; }
                elif (( CONFIRM_BY > 30 )) && [[ -z "${said}" || $(( t % 30 )) -eq 0 ]]; then
                    said=1; info "  still waiting ($(( CONFIRM_BY - t ))s left): $(missing "${decl}")"
                fi ;;
            fail*) warn "  ${NODE}: ${res#fail }"; break ;;
        esac
    done
    if [[ "${ok}" == 1 ]]; then
        info "  ${GN}✓${CL} ${NODE} is on its declared uplink — change confirmed"
    else
        # Back as it was on the switch too: an aggregate formed for this change
        # goes; one taken apart for it comes back.
        if [[ "${sw_done}" == 1 ]]; then
            warn "  Taking LAG $(lag_name) apart again on ${sw_set}..."
            switch_lag remove "${sw_set}" || warn "  …it did not: take ports ${sw_ports} of ${sw_set} out of the aggregate by hand"
        fi
        warn "  Not confirmed — ${NODE} reverts to its previous uplink. Waiting for it..."
        sleep $(( ROLLBACK_SECS + 10 ))
        res="$(ssh -n -o BatchMode=yes -o ConnectTimeout=5 "root@$(rn_node_fqdn "${NODE}")" \
               'cat /run/tappaas-net-set-lan 2>/dev/null' 2>/dev/null || true)"
        [[ "${res}" == reverted ]] && info "  ${NODE} reverted and answers again" \
            || warn "  ${NODE} does not answer as reverted (${res:-no answer}) — check its console before anything else"
        if [[ -n "${sw_restore}" ]]; then
            local back
            back="$(switch_ports_for "$(jq -r '[.lan.members[].name] | join(" ")' <<<"${live}")" 2>/dev/null | cut -f2)"
            warn "  Forming LAG $(lag_name) on ${sw_restore} again (ports ${back:-?})..."
            [[ -n "${back}" ]] && switch_lag set "${sw_restore}" "${back}" \
                || warn "  …it did not: put ${NODE}'s ports of ${sw_restore} back into one aggregate by hand"
        fi
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
        | jq -e '[.[] | select(.text | test("is down|LACP partner|outside the active aggregator|not carrying traffic|corosync"))] | length == 0' >/dev/null \
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
           && [[ "$(rn_node_ssh "${NODE}" "corosync-cfgtool -s | grep -c disconnected || true" 2>/dev/null)" == 0 ]]; then
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
        if [[ -z "${LAN_PORTS}" && "${NO_WAN}" == 1 ]]; then
            write_declared '{"wan": {"ports": []}}'
            info "${GN}✓${CL} declared in config/${NODE}.json: no wan port"
        elif [[ -n "${LAN_PORTS}" ]]; then
            if [[ "${CONFIG_ONLY}" == 1 ]]; then
                d="$(declaration_from_flags)"
            else
                live="$(probe)" || die "cannot reach ${NODE} (--config-only declares without it, by MAC)"
                d="$(declaration_from_flags "${live}")"
            fi
            write_declared "${d}"
            info "${GN}✓${CL} declared in config/${NODE}.json: $(jq -c . <<<"${d}")"
        else
            [[ -z "${LAN_MODE}${LAN_PRIMARY}${LAN_MTU}" ]] || die "--lan-mode/--lan-primary/--mtu go with --lan-ports"
            [[ "$(declared | jq -c '.lan // null')" != null ]] || die "nothing declared for ${NODE} — give --lan-ports"
        fi
        [[ "${CONFIG_ONLY}" == 1 ]] && exit 0
        converge "$(declared)"
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
