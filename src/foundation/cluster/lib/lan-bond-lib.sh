#!/usr/bin/env bash
# shellcheck shell=bash
#
# lan-bond-lib.sh — the lan bridge's uplink as a bond (#40). Pure text functions,
# shared by config-network.sh (writes /etc/network/interfaces on the node) and
# its tests; nothing here touches a live interface.
#
# One or more physical ports carry the `lan` bridge:
#   single         one port, the bridge's own member (the layout before #40)
#   active-backup  ports under `lanbond`, one carries traffic, the primary when up;
#                  any switch, any mix of speeds (1G + 10G)
#   lacp           ports under `lanbond` as one 802.3ad LAG; equal speeds, and the
#                  switch side must be one LAG: one switch, or a stack/MLAG pair
#
# Proxmox documents active-backup as the bond mode it supports for cluster
# traffic, which is why it is the default when more than one port is given.

LB_BOND="lanbond"

# The mode a port list implies when none is asked for. Args: <count> [<mode>]
# Prints the mode, or an error text on stderr with a non-zero return.
lb_mode() {
    local count="$1" mode="${2:-}"
    if (( count < 1 )); then echo "no lan port given" >&2; return 1; fi
    if (( count == 1 )); then
        [[ -z "${mode}" || "${mode}" == single ]] || { echo "--lan-mode ${mode} needs two or more ports" >&2; return 1; }
        echo single; return 0
    fi
    case "${mode:-active-backup}" in
        active-backup|lacp) echo "${mode:-active-backup}" ;;
        single) echo "single takes one port, not ${count}" >&2; return 1 ;;
        *) echo "unknown --lan-mode '${mode}' (single | active-backup | lacp)" >&2; return 1 ;;
    esac
}

# "a,b" or "a b" → "a b"; refuses a port named twice. Prints the list.
lb_ports() {
    local raw="${1//,/ }" p seen=" " out=""
    for p in ${raw}; do
        [[ "${seen}" == *" ${p} "* ]] && { echo "port ${p} named twice" >&2; return 1; }
        seen+="${p} "; out+="${out:+ }${p}"
    done
    printf '%s' "${out}"
}

# The bridge-ports value for `lan`: the port itself, or the bond.
lb_bridge_port() { local ports="$1"; [[ "${ports}" == *" "* ]] && echo "${LB_BOND}" || echo "${ports}"; }

# The bond stanza (empty for a single port). Args: <ports> <mode> <primary> [<mtu>]
lb_bond_stanza() {
    local ports="$1" mode="$2" primary="$3" mtu="${4:-}"
    [[ "${mode}" == single ]] && return 0
    printf 'auto %s\niface %s inet manual\n' "${LB_BOND}" "${LB_BOND}"
    printf '\tbond-slaves %s\n\tbond-miimon 100\n' "${ports}"
    if [[ "${mode}" == lacp ]]; then
        printf '\tbond-mode 802.3ad\n\tbond-lacp-rate fast\n\tbond-xmit-hash-policy layer2+3\n'
    else
        printf '\tbond-mode active-backup\n'
        [[ -n "${primary}" ]] && printf '\tbond-primary %s\n' "${primary}"
    fi
    [[ -n "${mtu}" ]] && printf '\tmtu %s\n' "${mtu}"
    printf '\n'
}

# Rewrite an interfaces file (stdin → stdout) so `lan` is carried by <bridge-port>:
# any existing lanbond stanza goes, the new one (may be empty) goes in front of
# `lan`, and lan's bridge-ports — and mtu, when given — are set. Everything else
# in the file (wan, addresses, gateway, post-up routes) is kept as it is.
# Args: <bridge-port> <bond-stanza> [<mtu>]
lb_set_lan() {
    local bport="$1" stanza="$2" mtu="${3:-}"
    # The stanza goes through the environment: -v would expand its escapes.
    LB_STANZA="${stanza}" awk -v bport="${bport}" -v mtu="${mtu}" -v bond="${LB_BOND}" '
        BEGIN { stanza = ENVIRON["LB_STANZA"]; sub(/\n+$/, "", stanza) }
        function flush_lan() { if (inlan && mtu != "" && !mtudone) print "\tmtu " mtu; inlan = 0 }
        # A stanza ends at the next unindented, non-blank line.
        /^[^ \t]/ {
            flush_lan(); skip = 0
            if ($0 ~ "^(auto|allow-hotplug) " bond "$" || $0 ~ "^iface " bond "( |$)") { skip = 1; next }
            if (!placed && ($0 ~ /^auto lan$/ || $0 ~ /^iface lan( |$)/)) {
                if (stanza != "") printf "%s\n\n", stanza
                placed = 1
            }
            if ($0 ~ /^iface lan( |$)/) { inlan = 1; mtudone = 0 }
        }
        skip { next }
        inlan && /^[ \t]+bridge-ports[ \t]/ { print "\tbridge-ports " bport; next }
        inlan && /^[ \t]+mtu[ \t]/ { if (mtu != "") { print "\tmtu " mtu; mtudone = 1; next } }
        inlan && /^[ \t]*$/ { flush_lan() }
        { print }
        END { flush_lan() }
    '
}

# The wan bridge gives up its port(s) (stdin → stdout): `bridge-ports none`, as a
# node added with --no-wan has, so a port can move into the lan bond. The wan
# stanza otherwise — address, post-up routes — is kept.
lb_wan_none() {
    awk '
        /^[^ \t]/ { inwan = ($0 ~ /^iface wan( |$)/) }
        inwan && /^[ \t]+bridge-ports[ \t]/ { print "\tbridge-ports none"; next }
        { print }
    '
}

# The wan bridge carries <port> (#849): the reverse of lb_wan_none, so the
# firewall's WAN role can move to this node. stdin → stdout.
lb_wan_port() {
    awk -v p="$1" '
        /^[^ \t]/ { inwan = ($0 ~ /^iface wan( |$)/) }
        inwan && /^[ \t]+bridge-ports[ \t]/ { print "\tbridge-ports " p; next }
        { print }
    '
}

# The port to prefer in active-backup: the fastest, the first named on a tie.
# Args: <ports>; speeds from LB_SPEED_CMD <port> (Mb/s, -1 or empty = unknown).
lb_speed() { cat "/sys/class/net/$1/speed" 2>/dev/null || echo -1; }
LB_SPEED_CMD="${LB_SPEED_CMD:-lb_speed}"
lb_default_primary() {
    local p s best="" bests=-2
    for p in $1; do
        s="$("${LB_SPEED_CMD}" "${p}")"; [[ "${s}" =~ ^[0-9]+$ ]] || s=-1
        (( s > bests )) && { best="${p}"; bests="${s}"; }
    done
    echo "${best}"
}

# Equal speeds, as LACP needs. Args: <ports>. Non-zero with the speeds on stderr.
lb_equal_speeds() {
    local p s first="" desc=""
    for p in $1; do
        s="$("${LB_SPEED_CMD}" "${p}")"; desc+="${desc:+, }${p}=${s}"
        [[ -z "${first}" ]] && first="${s}"
        [[ "${s}" == "${first}" ]] || { echo "${desc}" >&2; return 1; }
    done
}
