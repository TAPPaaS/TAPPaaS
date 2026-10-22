#!/usr/bin/env bash
# shellcheck shell=bash
#
# lan-uplink-lib.sh — what a node's lan uplink is, what it should be, and what
# is wrong with it (#40). Sourced by lan-uplink.sh; the jq programs are pure
# (JSON in, JSON out), so test-lan-uplink-lib.sh drives them with fixtures.
#
# The probe runs on the node (as root, `bash -s`) and prints one JSON object:
#   ports      every physical port: name, mac (the permanent one, also inside a
#              bond), state, speed (Mb/s, -1 unknown), mtu, mii and aggregator
#              (bond members), actorState/partnerState (802.3ad port state
#              bits, -1 when not lacp), lldp {chassis, name, port} or null
#   lan        mtu, bond ("" when a single port), mode (single | active-backup |
#              lacp | the kernel's word), active, primary, primaryMac,
#              aggregator, partnerMac, bondMtu, members (port objects)
#   wan        members (port objects)
#   lrmActive  this node's HA LRM is active — its watchdog is armed
#   corosync   links, disconnected
#   lldpd      active | inactive | absent

lu_probe_script() {
    cat <<'PROBE'
set -u
cls=/sys/class/net
rd() { cat "$1" 2>/dev/null || true; }
if command -v lldpcli >/dev/null 2>&1; then
    lldpd="$(systemctl is-active lldpd 2>/dev/null || true)"; lldpd="${lldpd:-inactive}"
    lldp="$(lldpcli show neighbors -f keyvalue 2>/dev/null || true)"
else
    lldpd=absent; lldp=""
fi
kv() { printf '%s\n' "$lldp" | awk -v p="lldp.$1.$2." -v want="$3" '
    index($0, p) == 1 { k = substr($0, length(p) + 1); k = substr(k, 1, index(k, "=") - 1)
                        if (k ~ "^(" want ")$") { print substr($0, index($0, "=") + 1); exit } }'; }
port_json() {
    local n="$1" d="$cls/$1" mac ch agg
    mac="$(rd "$d/bonding_slave/perm_hwaddr")"; [ -n "$mac" ] || mac="$(rd "$d/address")"
    agg="$(rd "$d/bonding_slave/ad_aggregator_id")"; [ "$agg" = N/A ] && agg=""   # not 802.3ad
    ch="$(kv "$n" chassis 'mac|local|ip')"
    jq -cn --arg name "$n" --arg mac "$mac" --arg state "$(rd "$d/operstate")" \
        --arg speed "$(rd "$d/speed")" --arg mtu "$(rd "$d/mtu")" \
        --arg mii "$(rd "$d/bonding_slave/mii_status")" --arg agg "$agg" \
        --arg as "$(rd "$d/bonding_slave/ad_actor_oper_port_state")" --arg ps "$(rd "$d/bonding_slave/ad_partner_oper_port_state")" \
        --arg ch "$ch" --arg nm "$(kv "$n" chassis name)" --arg pt "$(kv "$n" port 'ifname|local|mac')" \
        --arg usb "$(readlink -f "$d/device" 2>/dev/null | grep -q '/usb[0-9]' && echo true || echo false)" \
        '{name: $name, mac: ($mac | ascii_downcase), state: $state,
          speed: (($speed | tonumber?) // -1), mtu: (($mtu | tonumber?) // 0),
          mii: $mii, aggregator: $agg, usb: ($usb == "true"),
          actorState: (($as | tonumber?) // -1), partnerState: (($ps | tonumber?) // -1),
          lldp: (if $ch == "" then null else {chassis: $ch, name: $nm, port: $pt} end)}'
}
arr() { local o="" x; for x in "$@"; do o+="${o:+,}${x}"; done; printf '[%s]' "$o"; }
bridge_phys() {  # the physical ports a bridge carries, through a bond if it has one
    local p n
    for p in "$cls/$1/brif"/*; do
        [ -e "$p" ] || continue; n="${p##*/}"
        if [ -d "$cls/$n/bonding" ]; then echo "bond $n"; for m in $(rd "$cls/$n/bonding/slaves"); do echo "port $m"; done
        elif [ -e "$cls/$n/device" ]; then echo "port $n"; fi
    done
}
all=(); for d in "$cls"/*; do [ -e "$d/device" ] && all+=("$(port_json "${d##*/}")"); done
bond=""; lanm=()
while read -r kind n; do
    case "$kind" in bond) bond="$n" ;; port) lanm+=("$(port_json "$n")") ;; esac
done < <(bridge_phys lan)
wanm=(); while read -r kind n; do [ "$kind" = port ] && wanm+=("$(port_json "$n")"); done < <(bridge_phys wan)
mode=single; active=""; primary=""; agg=""; partner=""; bmtu=""
if [ -n "$bond" ]; then
    b="$cls/$bond/bonding"; mode="$(rd "$b/mode")"; mode="${mode%% *}"
    [ "$mode" = 802.3ad ] && mode=lacp
    active="$(rd "$b/active_slave")"; primary="$(rd "$b/primary")"
    agg="$(rd "$b/ad_aggregator")"; partner="$(rd "$b/ad_partner_mac")"; bmtu="$(rd "$cls/$bond/mtu")"
    [ "$agg" = N/A ] && agg=""; [ "$partner" = N/A ] && partner=""
fi
lrm=false; ha-manager status 2>/dev/null | grep -q "^lrm $(hostname -s) (active" && lrm=true
cs="$(corosync-cfgtool -s 2>/dev/null || true)"
links="$(grep -c '^LINK ID' <<<"$cs" || true)"; disc="$(grep -c 'disconnected' <<<"$cs" || true)"
jq -cn --arg node "$(hostname -s)" --argjson ports "$(arr ${all[@]+"${all[@]}"})" \
    --argjson lanm "$(arr ${lanm[@]+"${lanm[@]}"})" --argjson wanm "$(arr ${wanm[@]+"${wanm[@]}"})" \
    --arg bond "$bond" --arg mode "$mode" --arg active "$active" --arg primary "$primary" \
    --arg agg "$agg" --arg partner "$partner" --arg bmtu "$bmtu" --arg lmtu "$(rd "$cls/lan/mtu")" \
    --argjson lrm "$lrm" --arg links "${links:-0}" --arg disc "${disc:-0}" --arg lldpd "$lldpd" \
    '{node: $node, ports: $ports,
      lan: {mtu: (($lmtu | tonumber?) // 0), bond: $bond, mode: $mode, active: $active, primary: $primary,
            primaryMac: ([$lanm[] | select(.name == $primary) | .mac][0] // ""),
            aggregator: $agg, partnerMac: $partner, bondMtu: (($bmtu | tonumber?) // null), members: $lanm},
      wan: {members: $wanm}, lrmActive: $lrm,
      corosync: {links: ($links | tonumber), disconnected: ($disc | tonumber)}, lldpd: $lldpd}'
PROBE
}

# The declaration a live layout amounts to (capture): ports by MAC. stdin: probe.
lu_declaration() {
    jq -c '{lan: ({ports: [.lan.members[].mac], mode: .lan.mode}
                  + (if .lan.mode == "active-backup" and .lan.primaryMac != "" then {primary: .lan.primaryMac} else {} end)
                  + (if .lan.mtu != 0 and .lan.mtu != 1500 then {mtu: .lan.mtu} else {} end)),
            wan: {ports: [.wan.members[].mac]}}'
}

# Ports named by interface name or MAC → "name mac" lines, in the order given.
# Args: <probe-json> <a,b,...>. Non-zero, naming the first unknown one, on stderr.
lu_resolve_ports() {
    local live="$1" t out
    for t in ${2//,/ }; do
        out="$(jq -r --arg t "${t,,}" '.ports[] | select(.name == $t or .mac == $t) | "\(.name) \(.mac)"' <<<"${live}" | head -1)"
        [[ -n "${out}" ]] || { echo "${t} is not a physical port on $(jq -r .node <<<"${live}")" >&2; return 1; }
        echo "${out}"
    done
}

# What is wrong. stdin: {node, live, declared} → [{level: warn|info, text}].
lu_findings() {
    jq -c '
      . as $r | $r.live as $L | ($r.declared // {}) as $D | $L.lan.members as $M | $r.node as $n
      | ($D.lan // null) as $DL
      | [
        ( if ($M | length) <= 1 and $L.lrmActive then
            {level: "warn", text: "fencing is armed and lan has one port (\($M[0].name // "none")): a port or switch failure resets this node — add a second: site-manager node network set \($n) --lan-ports <a>,<b> --apply"}
          else empty end ),
        ( if ($M | length) > 1 then
            ( $M[] | select(.state != "up" or (.mii != "" and .mii != "up"))
              | {level: "warn", text: "\(.name) is down — the bond runs on one leg less\(if .usb then " (a USB NIC: replug it, or on the node: ifup \($L.lan.bond))" else "" end)"} )
          else empty end ),
        # A declared lan port the node does not have at all — on a site that
        # declares a USB leg, an adapter pulled out or not enumerated (#849).
        ( if $DL != null then
            ( $DL.ports[] | ascii_downcase | select(. as $m | [$L.ports[].mac] | index($m) | not)
              | {level: "warn", text: "declared lan port \(.) is not on \($n) — a USB NIC unplugged or not seen by the kernel? Replug it (lsusb on the node)"} )
          else empty end ),
        ( if $L.lan.mode == "active-backup" and $L.lan.primary != "" and $L.lan.active != $L.lan.primary then
            {level: "warn", text: "active-backup runs on \($L.lan.active), not on its primary \($L.lan.primary)"}
          else empty end ),
        ( if $L.lan.mode == "lacp" then
            ( if ($L.lan.partnerMac == "" or $L.lan.partnerMac == "00:00:00:00:00:00") then
                {level: "warn", text: "no LACP partner — the switch ports are not configured as one LAG"}
              else
                ( $M[] | select(.aggregator != $L.lan.aggregator)
                  | {level: "warn", text: "\(.name) is outside the active aggregator — its switch port is not in the LAG"} ),
                # 802.3ad port state bits: 2 short timeout, 8 in sync, 16 collecting,
                # 32 distributing, 64 defaulted, 128 expired.
                ( $M[] | select(.aggregator == $L.lan.aggregator and (.actorState // -1) >= 0)
                  | select(((.actorState / 8 | floor) % 8) != 7 or .actorState >= 64)
                  | {level: "warn", text: "\(.name) is not carrying traffic in the LAG (LACP state \(.actorState)\(if .actorState >= 128 then ", the LACP from the switch on it expired" elif .actorState >= 64 then ", no LACP from the switch on it" else "" end))"} ),
                ( [ $M[] | select((.partnerState // -1) >= 0 and ((.partnerState / 2 | floor) % 2) == 0 and .actorState < 64) ] | first
                  | select(. != null)
                  | {level: "warn", text: "the switch asks for the slow LACP rate: a leg that fails with its link still up is noticed only after ~90s (link loss is noticed at once)"} )
              end )
          else empty end ),
        ( if ($M | length) > 1 then
            ( [$M[] | select(.lldp == null) | .name] ) as $blind
            | ( [$M[] | select(.lldp != null) | .lldp.chassis] | unique ) as $sw
            | if ($blind | length) > 0 then
                {level: "info", text: "which switch \($blind | join(", ")) reach(es) is unknown — no LLDP from it"}
              elif ($sw | length) == 1 then
                {level: "warn", text: "every leg reaches the same switch (\($M[0].lldp.name // $M[0].lldp.chassis)) — redundant ports, not redundant switches"}
              else empty end
          else empty end ),
        ( [$L.lan.mtu, ($L.lan.bondMtu // empty), ($M[].mtu)] | unique ) as $mt
        | ( if ($mt | length) > 1 then
              {level: "warn", text: "MTU differs between lan, the bond and its ports (\($mt | map(tostring) | join(" / ")))"}
            else empty end ),
        ( if $L.corosync.disconnected > 0 then
            {level: "warn", text: "corosync reports \($L.corosync.disconnected) disconnected link(s)"}
          else empty end ),
        ( if $L.lldpd == "absent" then
            {level: "info", text: "lldpd is not installed — the next cluster update installs it (receive-only)"}
          else empty end ),
        ( if $DL == null then
            {level: "info", text: "no uplinks declared — the next cluster update records this layout"}
          else
            ( [$DL.ports[] | ascii_downcase] ) as $dp
            | ( [$M[].mac] ) as $lp
            | ( $dp - [$L.ports[].mac] ) as $missing
            | ( if ($missing | length) > 0 then
                  {level: "warn", text: "declared port(s) \($missing | join(", ")) not on \($n) — a replaced NIC? declare again: site-manager node network set \($n) --lan-ports …"}
                else empty end ),
              ( ($DL.mode // (if ($dp | length) > 1 then "active-backup" else "single" end)) as $dm
                | if ($dp | sort) != ($lp | sort) or $dm != $L.lan.mode
                     or ($dm == "active-backup" and ($DL.primary // "") != ""
                         and ($DL.primary | ascii_downcase) != $L.lan.primaryMac)
                     or (($DL.mtu // null) != null and $DL.mtu != $L.lan.mtu) then
                    {level: "warn", text: "drift: declared \($dm) on \($dp | join(", ")), live \($L.lan.mode) on \($lp | join(", ")) — converge: site-manager node network set \($n) --apply"}
                  else empty end )
          end ),
        ( if ($D.wan.ports? // null) != null then
            ( [$D.wan.ports[] | ascii_downcase] | sort ) as $dw
            | ( [$L.wan.members[].mac] | sort ) as $lw
            | if $dw != $lw then
                {level: "warn", text: "drift: declared wan on \(if $dw == [] then "no port" else ($dw | join(", ")) end), live wan on \(if $lw == [] then "no port" else ($lw | join(", ")) end) — converge: site-manager node network set \($n) --apply"}
              else empty end
          else empty end )
      ]'
}
