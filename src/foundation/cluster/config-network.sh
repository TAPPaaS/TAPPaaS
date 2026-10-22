#!/usr/bin/env bash
#
# TAPPaaS Network Configuration (config-network.sh)  — issue #141
#
# Builds the TAPPaaS node network model on a fresh Proxmox VE host, and performs
# the post-firewall "gateway cutover".
#
#   lan : VLAN-aware bridge carrying the management network (untagged, 10.0.0.0/24)
#         plus every TAPPaaS VLAN (2-4094) as a trunk to the downstream switch.
#         Holds this node's management IP (10.0.0.<9+N>). The OPNsense firewall
#         VM's LAN and all guest VLAN interfaces attach here.
#   wan : plain bridge for the upstream/ISP uplink (the firewall VM's WAN). On the
#         first node it also keeps the node's original install IP so the node has
#         internet during bootstrap (and so the cutover need not break the admin
#         session). On secondary nodes the wan bridge is wired but unused until
#         the node is enabled for firewall HA.
#
# NIC roles are assigned by node role, auto-detected from connectivity:
#   first node      : the install NIC (the one with upstream internet) is WAN;
#                     the other NIC (to the downstream switch) is LAN.
#   secondary node  : the install NIC is already on the mgmt net (10.0.0.x via the
#                     firewall) so it is LAN; the other NIC is WAN (for firewall HA).
#
# Modes:
#   (default)        Build the lan/wan bridges and place the mgmt IP (bootstrap).
#   --swap-gateway   Cutover: point the node's default route + DNS at the firewall
#                    (10.0.0.1) and ensure corosync uses the mgmt IP. ADDITIVE — it
#                    does NOT remove the upstream IP, so connectivity is preserved
#                    (formerly "--swap-cables"). No cables are moved.
#   --admin-route N  With --swap-gateway: keep a static route to management network
#                    N (CIDR/IP) via the OLD upstream gateway, so an admin client
#                    reached that way (e.g. a jump LAN) stays connected after the
#                    default route moves to the firewall. Prompted if interactive.
#   --drop-upstream  Hardening (run later): remove the node's upstream (wan-side)
#                    host IP so Proxmox is reachable only on the mgmt net / via the
#                    firewall (or netbird).
#   --set-lan        Running node (#40): carry the existing `lan` bridge on the
#                    --lan-port list — one port, or a bond of several (`lanbond`).
#                    Only lan's uplink changes: its address, gateway and the wan
#                    bridge are kept. Guarded by a --rollback-secs timer (default
#                    45s, under the 60s HA watchdog) that restores the previous
#                    file unless the change is confirmed; with --confirm-external
#                    the caller confirms (touch /run/tappaas-net-ok) once it has
#                    checked the node from outside. Normally run by
#                    lan-uplink.sh (site-manager node network set), not by hand.
#                    With --no-wan the wan bridge gives up its port (bridge-ports
#                    none, as on a node added with --no-wan), so that port can join
#                    the lan bond; refused while a guest is on the wan bridge.
#                    With --wan-port p the wan bridge carries p (#849): the reverse,
#                    so the firewall's WAN role can move to this node; p must be a
#                    free physical port, not one of the lan ports.
#
# lan uplink (#40):
#   --lan-port a,b   Two or more ports bond under `lan` as `lanbond`.
#   --lan-mode m     active-backup (default for 2+ ports; any switches, any speeds)
#                    or lacp (802.3ad: equal speeds, and the switch side one LAG).
#   --lan-primary p  active-backup: the port that carries traffic when it is up
#                    (default: the fastest).
#   --mtu n          MTU on the bond and the lan bridge (default: unchanged).
#   A USB NIC among the lan ports (#849) is pinned to `usblanN` by its MAC, USB
#   autosuspend is turned off for it, and a udev rule puts it back in its bond
#   when it appears after boot or a replug (ifupdown2 skips a missing member).
#
# Usage:
#   config-network.sh [--lan-port <ifname>[,<ifname>...]] [--wan-port <ifname>]
#                     [--lan-mode active-backup|lacp] [--lan-primary <ifname>] [--mtu <n>]
#                     [--mgmt-ip <CIDR>] [--gateway <ip>] [--fw-ip <ip>]
#                     [--swap-gateway [--admin-route <CIDR>] | --drop-upstream
#                      | --set-lan [--rollback-secs <s>] [--confirm-external]]
#                     [--no-rollback] [--apply|--dry-run] [--non-interactive]
#                     [-h|--help]
#
# Defaults:
#   mgmt IP   : 10.0.0.<9+N> for tappaasN (10.0.0.10 for tappaas1), overridable.
#   firewall  : 10.0.0.1.
#   rollback  : 90s (revert the bridge build unless connectivity is confirmed).
#
# Exit codes: 0 success/no-op, 1 error, 2 bad usage.

set -euo pipefail

readonly RD=$'\033[01;31m' YW=$'\033[33m' GN=$'\033[1;92m' BL=$'\033[36m' CL=$'\033[m' BOLD=$'\033[1m'
info()  { echo -e "${GN}[network]${CL} $*"; }
warn()  { echo -e "${YW}[network][warn]${CL} $*"; }
error() { echo -e "${RD}[network][error]${CL} $*" >&2; }
# Detail lines shown only under TAPPAAS_DEBUG=1 (cyan, matching the [Debug] convention).
debug() { [ "${TAPPAAS_DEBUG:-0}" = "1" ] && echo -e "${BL}[network]${CL} $*" || true; }
die()   { error "$*"; exit 1; }

readonly INTERFACES=/etc/network/interfaces
readonly ROLLBACK_BIN=/usr/local/sbin/tappaas-net-rollback.sh
readonly ROLLBACK_OK=/run/tappaas-net-ok
readonly SET_LAN_RESULT=/run/tappaas-net-set-lan   # --set-lan: "ok" | "fail <why>"
readonly MGMT_SUBNET="10.0.0"   # /24 management network prefix
readonly MGMT_POOL_START=100    # mgmt DHCP pool starts here: .10-.99 are the nodes' (#673)

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; /^set -euo/d'; }

# The lan uplink's bond rendering (#40). Fetched beside this script by the node
# step (cluster/install.sh), copied beside it by lan-uplink.sh, and in lib/ in
# the repository.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _lib in "${_here}/lib/lan-bond-lib.sh" "${_here}/lan-bond-lib.sh"; do
  # shellcheck source=lib/lan-bond-lib.sh disable=SC1090
  [[ -r "${_lib}" ]] && { . "${_lib}"; break; }
done
declare -F lb_set_lan >/dev/null || { echo "config-network.sh: lan-bond-lib.sh not found beside it" >&2; exit 1; }

# ── Arguments ────────────────────────────────────────────────────────
LAN_PORT="" WAN_PORT="" MGMT_IP="" GATEWAY="" ADMIN_ROUTE=""
DO_ROLLBACK=1 INTERACTIVE=1 DRY_RUN=0 ROLLBACK_SECS=""
SWAP_GATEWAY=0 DROP_UPSTREAM=0 FW_IP="${MGMT_SUBNET}.1"
LAN_MODE="" LAN_PRIMARY="" LAN_MTU="" SET_LAN=0 CONFIRM_EXTERNAL=0 NO_WAN=0
LAN_PORTS="" LAN_BRIDGE_PORT="" LAN_STANZA=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lan-port)        LAN_PORT="${2:-}"; shift 2 ;;
    --wan-port)        WAN_PORT="${2:-}"; shift 2 ;;
    --mgmt-ip)         MGMT_IP="${2:-}"; shift 2 ;;
    --gateway)         GATEWAY="${2:-}"; shift 2 ;;
    --swap-gateway)    SWAP_GATEWAY=1; shift ;;
    --admin-route)     ADMIN_ROUTE="${2:-}"; shift 2 ;;
    --drop-upstream)   DROP_UPSTREAM=1; shift ;;
    --fw-ip)           FW_IP="${2:-}"; shift 2 ;;
    --lan-mode)        LAN_MODE="${2:-}"; shift 2 ;;
    --lan-primary)     LAN_PRIMARY="${2:-}"; shift 2 ;;
    --mtu)             LAN_MTU="${2:-}"; shift 2 ;;
    --set-lan)         SET_LAN=1; shift ;;
    --rollback-secs)   ROLLBACK_SECS="${2:-}"; shift 2 ;;
    --confirm-external) CONFIRM_EXTERNAL=1; shift ;;
    --no-wan)          NO_WAN=1; shift ;;
    --no-rollback)     DO_ROLLBACK=0; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    --apply)           DRY_RUN=0; shift ;;
    --non-interactive) INTERACTIVE=0; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) error "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

# 90s for a bootstrap (an operator watches it); 45s for --set-lan on a running
# node, which has to revert before the HA watchdog (60s) could fence it.
[[ -n "$ROLLBACK_SECS" ]] || { [[ "$SET_LAN" == 1 ]] && ROLLBACK_SECS=45 || ROLLBACK_SECS=90; }
[[ "$ROLLBACK_SECS" =~ ^[0-9]+$ ]] || { echo "--rollback-secs: not a number of seconds" >&2; exit 2; }
[[ -z "$LAN_MTU" || "$LAN_MTU" =~ ^[0-9]+$ ]] || { echo "--mtu: not a number" >&2; exit 2; }

[[ $EUID -eq 0 ]] || die "Must run as root."
command -v ifreload >/dev/null || warn "ifreload not found — will fall back to 'systemctl restart networking'."
HAVE_WHIPTAIL=0; command -v whiptail >/dev/null && HAVE_WHIPTAIL=1
[[ -t 0 && -t 1 ]] || INTERACTIVE=0

# ── Shared helpers ────────────────────────────────────────────────────

# This node's management IP on the lan bridge: <mgmt subnet>.<9+N> for tappaasN
# — a sequence, not a list (#673). The node numbers are unbounded; the ADDRESSES
# run out where the mgmt zone's DHCP pool begins (MGMT_POOL_START, .100 by
# convention), which leaves .10-.99 for nodes. Its DNS entry is created when the
# node is registered (cluster/update.sh), not shipped in advance.
node_mgmt_ip() {
  if [[ -n "$MGMT_IP" ]]; then echo "${MGMT_IP%/*}"; return; fi
  local n; n="$(hostname -s | grep -oE '[0-9]+$' || true)"
  [[ -n "$n" ]] || { echo "${MGMT_SUBNET}.10"; return; }
  local host=$((9 + n))
  if (( host >= MGMT_POOL_START )); then
    die "Node ${n} (tappaas${n}) would take ${MGMT_SUBNET}.${host}, which is inside the mgmt DHCP pool (from ${MGMT_SUBNET}.${MGMT_POOL_START}). Assign one outside the pool with --mgmt-ip."
  fi
  echo "${MGMT_SUBNET}.${host}"
}

# Address currently held on bridge $1 (CIDR), empty if none.
bridge_ip() { ip -o -4 addr show "$1" 2>/dev/null | awk '{print $4; exit}'; }

# ── Auto-rollback guard (prevents permanent lockout) ─────────────────
# A one-shot timer restores the backup unless the operator confirms connectivity
# (which removes the guard). If applying the new config drops the operator's
# session, the node self-heals back to the working config.
arm_rollback() {
  rm -f "$ROLLBACK_OK"
  cat >"$ROLLBACK_BIN" <<EOF
#!/bin/sh
if [ -f "${ROLLBACK_OK}" ]; then
  logger -t tappaas "config-network: rollback skipped (operator confirmed)"
else
  logger -t tappaas "config-network: AUTO-REVERTING to ${BACKUP} (no confirmation)"
  cp -a "${BACKUP}" "${INTERFACES}"
  echo reverted > "${SET_LAN_RESULT}"
  ifreload -a 2>/dev/null || systemctl restart networking
fi
rm -f "${ROLLBACK_BIN}"
EOF
  chmod 755 "$ROLLBACK_BIN"
  systemd-run --on-active="${ROLLBACK_SECS}" /bin/sh "$ROLLBACK_BIN" >/dev/null 2>&1 \
    || warn "Could not arm systemd rollback timer (proceeding without auto-rollback)."
}

apply_network() { ifreload -a 2>/dev/null || systemctl restart networking; }

# ── Mode: gateway cutover (additive — preserves the upstream IP) ──────
swap_gateway() {
  local host mgmt_ip old_ip old_gw
  host="$(hostname -s)"
  mgmt_ip="$(node_mgmt_ip)"
  old_ip="$(bridge_ip wan | cut -d/ -f1)"
  # Capture the CURRENT upstream gateway BEFORE we move the default route to the
  # firewall — used to keep a route to the operator's management network reachable.
  old_gw="$(ip -o -4 route show default 2>/dev/null | awk '{print $3; exit}')"

  info "${BOLD}Gateway cutover${CL}: default route + DNS → firewall (${BL}${FW_IP}${CL}); node mgmt IP ${BL}${mgmt_ip}${CL}."
  info "  Additive — the upstream IP${old_ip:+ (${old_ip})} is kept, so your current session stays up."

  # 1. Ensure the mgmt IP is on the lan bridge (it should be from bootstrap).
  if ! ip -o -4 addr show lan 2>/dev/null | grep -qw "${mgmt_ip}/24"; then
    info "  adding ${mgmt_ip}/24 to lan"
    ip addr add "${mgmt_ip}/24" dev lan 2>/dev/null || true
  fi

  # 2. /etc/network/interfaces — move the default gateway from wan → lan and make
  #    the lan mgmt address permanent. The wan stanza keeps its address (if any)
  #    but loses its gateway, so the firewall becomes the node's default route.
  cp -a "$INTERFACES" "${INTERFACES}.tappaas.$(date +%Y%m%d-%H%M%S).bak"
  sed -i -E "/^iface wan inet/,/^[[:space:]]*\$/ { /^[[:space:]]*gateway[[:space:]]/d }" "$INTERFACES"
  if grep -qE '^[[:space:]]*address[[:space:]]+'"${mgmt_ip//./\\.}"'/' "$INTERFACES"; then :; else
    # lan has no static mgmt address yet — add it.
    sed -i -E "/^iface lan inet/ s|inet manual|inet static|" "$INTERFACES"
    sed -i -E "/^iface lan inet static/ a\\\taddress ${mgmt_ip}/24" "$INTERFACES"
  fi
  if grep -qE "^iface lan inet static" "$INTERFACES" \
     && ! awk '/^iface lan inet static/{f=1;next} /^iface |^auto /{f=0} f&&/gateway/{found=1} END{exit !found}' "$INTERFACES"; then
    sed -i -E "/^iface lan inet static/,/^[[:space:]]*\$/ s|^([[:space:]]*address[[:space:]].*)|\1\n\tgateway ${FW_IP}|" "$INTERFACES"
  else
    sed -i -E "/^iface lan inet static/,/^[[:space:]]*\$/ s|^([[:space:]]*gateway[[:space:]]+).*|\1${FW_IP}|" "$INTERFACES"
  fi
  info "  /etc/network/interfaces → default gateway ${FW_IP} on lan (wan gateway removed)"

  # 3. DNS via the firewall.
  cp -a /etc/resolv.conf "/etc/resolv.conf.tappaas.$(date +%Y%m%d-%H%M%S).bak" 2>/dev/null || true
  printf 'search internal mgmt.internal\nnameserver %s\n' "$FW_IP" > /etc/resolv.conf
  info "  /etc/resolv.conf → nameserver ${FW_IP}"

  # 4. /etc/hosts — this node's record at the mgmt IP.
  sed -i -E "/[[:space:]]${host}([[:space:]]|\$)/d" /etc/hosts 2>/dev/null || true
  printf '%s %s.mgmt.internal %s\n' "$mgmt_ip" "$host" "$host" >> /etc/hosts
  info "  /etc/hosts → ${mgmt_ip} ${host}.mgmt.internal ${host}"

  # 4.5 Optional admin route: after the default route moves to the firewall, a
  #     management client reached via the OLD upstream gateway (e.g. an admin
  #     laptop on a jump network) would lose its return path. Keep a static route
  #     to that network via the upstream gateway so the operator stays connected.
  if [[ -z "$ADMIN_ROUTE" && "$INTERACTIVE" == "1" && -n "$old_gw" ]]; then
    echo "" >&2
    info "Is your management console (browser/SSH) on a DIFFERENT network than this node?"
    info "  - If YES: enter that network below to add a static route via ${old_gw},"
    info "            so you keep connectivity after the default route moves to the firewall."
    info "  - If NO (same subnet as this node): just press Enter — no extra route needed."
    read -r -p "  Admin network to route via ${old_gw} (CIDR, e.g. 192.168.1.0/24, or blank): " ADMIN_ROUTE
  fi
  if [[ -n "$ADMIN_ROUTE" ]]; then
    if [[ -z "$old_gw" ]]; then
      warn "  No upstream gateway detected — cannot add admin route ${ADMIN_ROUTE}."
    elif [[ ! "$ADMIN_ROUTE" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]]; then
      warn "  '${ADMIN_ROUTE}' is not a valid IP/CIDR — skipping admin route."
    else
      [[ "$ADMIN_ROUTE" == */* ]] || ADMIN_ROUTE="${ADMIN_ROUTE}/32"
      info "  admin route: ${ADMIN_ROUTE} via ${old_gw} (kept reachable across the cutover)"
      ip route replace "$ADMIN_ROUTE" via "$old_gw" 2>/dev/null || warn "  runtime 'ip route' add failed (will still persist)"
      # Persist as a post-up on the wan stanza (the upstream-side bridge).
      if ! grep -qF "ip route add ${ADMIN_ROUTE} via ${old_gw}" "$INTERFACES"; then
        sed -i -E "/^iface wan inet/,/^[[:space:]]*\$/ s|^([[:space:]]*bridge-ports[[:space:]].*)|\1\n\tpost-up ip route add ${ADMIN_ROUTE} via ${old_gw} || true|" "$INTERFACES"
      fi
    fi
  fi

  # 5. corosync — ensure this node's ring0_addr is the mgmt IP, then RESTART the
  #    daemon so it rebinds (a config-file change alone needed a reboot before).
  #    Ideally the cluster was already created bound to the mgmt IP, so this is a
  #    no-op edit + a clean restart.
  if [[ -f /etc/pve/corosync.conf && -n "$old_ip" ]] && grep -qF "$old_ip" /etc/pve/corosync.conf 2>/dev/null; then
    local cv tmp esc_old
    cv="$(grep -oE 'config_version:[[:space:]]*[0-9]+' /etc/pve/corosync.conf | grep -oE '[0-9]+' | head -1)"
    esc_old="${old_ip//./\\.}"
    tmp="$(mktemp)"
    sed -E -e "s/(ring0_addr:[[:space:]]*)${esc_old}([[:space:]]|\$)/\1${mgmt_ip}\2/" \
           -e "s/\b${esc_old}\b/${mgmt_ip}/g" \
           -e "s/(config_version:[[:space:]]*)[0-9]+/\1$(( ${cv:-1} + 1 ))/" \
           /etc/pve/corosync.conf > "$tmp"
    cat "$tmp" > /etc/pve/corosync.conf && rm -f "$tmp"
    info "  /etc/pve/corosync.conf → ring0_addr ${mgmt_ip} (config_version $(( ${cv:-1} + 1 )))"
  else
    debug "  corosync ring0_addr already on the mgmt net — no change."
  fi

  # 6. Apply. Additive, so the existing session survives; restart corosync to
  #    rebind to the mgmt IP without a reboot.
  debug "  reloading network + restarting corosync (no reboot needed)..."
  ifreload -a 2>/dev/null || systemctl restart networking || warn "network reload returned non-zero"
  systemctl restart corosync pve-cluster 2>/dev/null || warn "corosync/pve-cluster restart returned non-zero"

  info "${GN}Gateway cutover complete.${CL} Node mgmt ${BL}${mgmt_ip}${CL}, routing via the firewall."
  debug "  Verify: ping ${FW_IP}; ping 8.8.8.8; pvecm status"
}

# ── Mode: drop the upstream IP (later hardening) ─────────────────────
drop_upstream() {
  info "${BOLD}Dropping the upstream (wan-side) host IP${CL} — Proxmox will be reachable"
  info "  only on the mgmt net (10.0.0.0/24) / via the firewall or netbird."
  local wan_ip; wan_ip="$(bridge_ip wan)"
  cp -a "$INTERFACES" "${INTERFACES}.tappaas.$(date +%Y%m%d-%H%M%S).bak"
  # Turn the wan stanza back into a plain (IP-less) bridge.
  sed -i -E "/^iface wan inet/,/^[[:space:]]*\$/ { /^[[:space:]]*address[[:space:]]/d; /^[[:space:]]*gateway[[:space:]]/d }" "$INTERFACES"
  sed -i -E "/^iface wan inet/ s|inet static|inet manual|" "$INTERFACES"
  [[ -n "$wan_ip" ]] && ip addr del "$wan_ip" dev wan 2>/dev/null || true
  info "  reloading network..."
  ifreload -a 2>/dev/null || systemctl restart networking || warn "network reload returned non-zero"
  info "${GN}Upstream IP removed.${CL} Reach this node at $(node_mgmt_ip) on the mgmt net."
}

if [[ "$SWAP_GATEWAY" == "1" ]]; then swap_gateway; exit 0; fi
if [[ "$DROP_UPSTREAM" == "1" ]]; then drop_upstream; exit 0; fi

# ── Physical port inventory ──────────────────────────────────────────
# A physical port has a backing device under /sys/class/net/<n>/device,
# which excludes lo, bridges, bonds, vlans, taps and veths.
is_physical() { [[ -e "/sys/class/net/$1/device" ]]; }

port_desc() {
  local n="$1" mac speed state master
  mac="$(cat "/sys/class/net/$n/address" 2>/dev/null || echo '??')"
  state="$(cat "/sys/class/net/$n/operstate" 2>/dev/null || echo '?')"
  speed="$(cat "/sys/class/net/$n/speed" 2>/dev/null || echo '')"
  [[ -n "$speed" && "$speed" != "-1" ]] && speed="${speed}Mb/s" || speed="link-down"
  master="$(ip -o link show "$n" 2>/dev/null | grep -oE 'master [^ ]+' | awk '{print $2}')"
  echo "mac=${mac} ${state}/${speed}${master:+ (in ${master})}"
}

declare -a PORTS PORT_DESCS
for _path in /sys/class/net/*; do
  n="${_path##*/}"
  is_physical "$n" || continue
  PORTS+=("$n"); PORT_DESCS+=("$(port_desc "$n")")
done

[[ ${#PORTS[@]} -ge 1 ]] || die "No physical network ports found."
info "Physical ports found: ${#PORTS[@]}"
for i in "${!PORTS[@]}"; do echo "    ${BL}${PORTS[$i]}${CL}  ${PORT_DESCS[$i]}"; done

# Comma-separated list of a bridge's member ports ("" if none), glob-based so it
# needs no `ls` parsing and is safe on an empty bridge.
bridge_members() {
  local p out=""
  for p in "/sys/class/net/$1/brif"/*; do
    [[ -e "$p" ]] || continue
    out+="${out:+,}${p##*/}"
  done
  printf '%s' "$out"
}

# ── The lan uplink: one port, or a bond of several (#40) ──────────────
# Sets LAN_PORTS (space-separated), LAN_MODE, LAN_PRIMARY, LAN_BRIDGE_PORT and
# LAN_STANZA (the bond's stanza, empty for one port) from --lan-port & co.
in_ports() { local x; for x in "${PORTS[@]}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }
resolve_lan() {
  local p n err
  err="$(lb_ports "$LAN_PORT" 2>&1 >/dev/null)" || die "--lan-port: ${err}"
  LAN_PORTS="$(lb_ports "$LAN_PORT")"
  for p in $LAN_PORTS; do in_ports "$p" || die "LAN port '${p}' is not a physical port."; done
  n="$(wc -w <<<"$LAN_PORTS" | tr -d ' ')"
  err="$(lb_mode "$n" "$LAN_MODE" 2>&1 >/dev/null)" || die "${err}"
  LAN_MODE="$(lb_mode "$n" "$LAN_MODE")"
  if [[ "$LAN_MODE" == lacp ]] && ! err="$(lb_equal_speeds "$LAN_PORTS" 2>&1)"; then
    # A port without link reads -1: unknown, not unequal — the switch may be off.
    [[ "$err" == *=-1* ]] && warn "lacp: a port's speed is unknown (${err}) — LACP needs equal speeds"       || die "lacp needs ports of equal speed (${err}) — use --lan-mode active-backup"
  fi
  if [[ "$LAN_MODE" == active-backup ]]; then
    [[ -n "$LAN_PRIMARY" ]] || LAN_PRIMARY="$(lb_default_primary "$LAN_PORTS")"
    [[ " $LAN_PORTS " == *" $LAN_PRIMARY "* ]] || die "--lan-primary ${LAN_PRIMARY} is not one of the lan ports (${LAN_PORTS})"
  else
    [[ -z "$LAN_PRIMARY" ]] || warn "--lan-primary applies to active-backup only — ignored for ${LAN_MODE}"
    LAN_PRIMARY=""
  fi
  LAN_BRIDGE_PORT="$(lb_bridge_port "$LAN_PORTS")"
  LAN_STANZA="$(lb_bond_stanza "$LAN_PORTS" "$LAN_MODE" "$LAN_PRIMARY" "$LAN_MTU")"
}
lan_desc() { echo "${LAN_PORTS}$([[ "$LAN_MODE" == single ]] || echo " as ${LB_BOND} (${LAN_MODE}${LAN_PRIMARY:+, primary ${LAN_PRIMARY}})")${LAN_MTU:+, mtu ${LAN_MTU}}"; }

# ── USB NICs as lan ports (#849) ──────────────────────────────────────
# A USB NIC's kernel name (enx<mac>) is pinned to usblanN, so the bond names
# something stable; /usr/local/sbin/tappaas-usb-nic-up, run by a udev rule when
# it appears, turns USB autosuspend off and re-adds it to the bond that lists it.
readonly USB_HELPER=/usr/local/sbin/tappaas-usb-nic-up
readonly USB_RULES=/etc/udev/rules.d/90-tappaas-usb-nic.rules
is_usb() { readlink -f "/sys/class/net/$1/device" 2>/dev/null | grep -q '/usb[0-9]'; }
next_usb_name() {
  local i=0
  while [[ -e "/sys/class/net/usblan${i}" ]] || grep -q "Name=usblan${i}\$" /usr/local/lib/systemd/network/*.link /etc/systemd/network/*.link 2>/dev/null; do
    i=$((i + 1))
  done
  echo "usblan${i}"
}
install_usb_helper() {
  cat > "$USB_HELPER" <<'HELPER'
#!/bin/sh
# tappaas-usb-nic-up <ifname> — a USB lan port appeared (#849): USB autosuspend
# off for its device, and back into the bond /etc/network/interfaces lists it in.
# Run by udev (90-tappaas-usb-nic.rules) through systemd-run; installed by
# config-network.sh --set-lan.
n="$1"; [ -n "$n" ] || exit 2
d="$(readlink -f "/sys/class/net/$n/device")"
while [ -n "$d" ] && [ "$d" != "/" ]; do
  if [ -f "$d/idVendor" ] && [ -w "$d/power/control" ]; then echo on > "$d/power/control"; break; fi
  d="$(dirname "$d")"
done
b="$(awk -v n="$n" '/^iface /{i=$2} $1=="bond-slaves"{for(k=2;k<=NF;k++) if($k==n) print i}' /etc/network/interfaces | head -1)"
[ -n "$b" ] || exit 0
# Before networking is up the bond does not exist: ifupdown2 enslaves it then.
[ -d "/sys/class/net/$b/bonding" ] || exit 0
case " $(cat "/sys/class/net/$b/bonding/slaves" 2>/dev/null) " in *" $n "*) exit 0 ;; esac
if ! ifup "$b" >/dev/null 2>&1 || ! grep -qw "$n" "/sys/class/net/$b/bonding/slaves"; then
  ip link set "$n" down; ip link set "$n" master "$b"; ip link set "$n" up
fi
logger -t tappaas-usb-nic "$n rejoined $b"
HELPER
  chmod 755 "$USB_HELPER"
}
# forget_usb_rules: a USB NIC no longer among the lan ports loses its udev rule
# (its pinned name stays: harmless, and stable if it comes back).
forget_usb_rules() {
  [[ -f "$USB_RULES" && "$DRY_RUN" != 1 ]] || return 0
  local keep="" p mac tmp
  for p in $LAN_PORTS; do mac="$(cat "/sys/class/net/$p/address" 2>/dev/null)"; [[ -n "$mac" ]] && keep+=" ${mac,,}"; done
  tmp="$(mktemp)"
  while IFS= read -r line; do
    mac="$(grep -oiE 'address\}=="([0-9a-f]{2}:){5}[0-9a-f]{2}' <<<"$line" | grep -oiE '([0-9a-f]{2}:){5}[0-9a-f]{2}')"
    if [[ -z "$mac" || " ${keep} " == *" ${mac,,} "* ]]; then printf '%s\n' "$line" >> "$tmp"
    else info "  ${mac} is no longer a lan port: its USB rejoin rule goes"; fi
  done < "$USB_RULES"
  if [[ -s "$tmp" ]]; then cat "$tmp" > "$USB_RULES"; else rm -f "$USB_RULES"; fi
  rm -f "$tmp"; udevadm control --reload 2>/dev/null || true
}

# prepare_usb_ports: rewrite LAN_PORT so each USB NIC has its pinned name; with
# --apply, pin and rename it now and install the helper and its udev rule.
prepare_usb_ports() {
  local p out="" name mac
  for p in ${LAN_PORT//,/ }; do
    if is_usb "$p" && [[ "$p" != usblan* ]]; then
      name="$(next_usb_name)"; mac="$(cat "/sys/class/net/$p/address")"
      info "  ${p} is a USB NIC (${mac}): pinned as ${BL}${name}${CL}, USB autosuspend off, rejoins its bond when it reappears (#849)"
      if [[ "$DRY_RUN" != 1 ]]; then
        pve-network-interface-pinning generate --interface "$p" --target-name "$name" >/dev/null \
          || die "could not pin ${p} as ${name} (pve-network-interface-pinning)"
        ip link set "$p" down && ip link set "$p" name "$name" && ip link set "$name" up \
          || die "could not rename ${p} to ${name}"
        install_usb_helper
        grep -qi "ATTR{address}==\"${mac}\"" "$USB_RULES" 2>/dev/null \
          || printf 'ACTION=="add", SUBSYSTEM=="net", ATTR{address}=="%s", RUN+="/usr/bin/systemd-run --no-block --collect %s %s"\n' \
               "$mac" "$USB_HELPER" "$name" >> "$USB_RULES"
        udevadm control --reload 2>/dev/null || true
        "$USB_HELPER" "$name" || true   # autosuspend off now
        PORTS+=("$name")
      fi
      out+="${out:+,}${name}"
    else
      out+="${out:+,}${p}"
    fi
  done
  # A dry run names the port it will be; resolve_lan must accept that name.
  [[ "$DRY_RUN" == 1 ]] && for p in ${out//,/ }; do in_ports "$p" || PORTS+=("$p"); done
  [[ -n "${LAN_PRIMARY}" ]] && for p in ${LAN_PORT//,/ }; do
    [[ "$LAN_PRIMARY" == "$p" ]] && is_usb "$p" && warn "--lan-primary ${p} is the USB NIC: a USB port is better as the backup"
  done
  LAN_PORT="$out"
}

# ── Mode: re-carry a running node's lan bridge (#40) ──────────────────
set_lan() {
  local p wanm cur new gw ok _i
  ip link show lan &>/dev/null || die "--set-lan: this node has no lan bridge — bootstrap it first"
  [[ -n "$LAN_PORT" ]] || die "--set-lan needs --lan-port"
  [[ "$NO_WAN" == 1 && -n "$WAN_PORT" ]] && die "--no-wan and --wan-port are each other's opposite — give one"
  prepare_usb_ports
  resolve_lan
  forget_usb_rules
  if [[ -n "$WAN_PORT" ]]; then
    in_ports "$WAN_PORT" || die "--wan-port ${WAN_PORT}: not a physical port"
    [[ " $LAN_PORTS " == *" ${WAN_PORT} "* ]] && die "--wan-port ${WAN_PORT} is one of the lan ports — take it out of --lan-port first"
    [[ -z "$(ip -o -4 addr show "$WAN_PORT" 2>/dev/null)" ]] || die "--wan-port ${WAN_PORT} has an address of its own — not a free port"
    [[ -n "$(ip -o link show "$WAN_PORT" | grep -oE 'master [^ ]+' | grep -v 'master wan')" ]] \
      && die "--wan-port ${WAN_PORT} is in $(ip -o link show "$WAN_PORT" | grep -oE 'master [^ ]+' | awk '{print $2}') — free it first"
  fi
  wanm=",$(bridge_members wan),"
  if [[ "$NO_WAN" == 1 ]]; then
    # The wan bridge's own guests (the firewall's WAN NIC) would lose their uplink.
    for p in ${wanm//,/ }; do
      is_physical "$p" || die "--no-wan: ${p} is on the wan bridge — a guest uses it (the firewall's WAN?); move it first"
    done
  fi
  for p in $LAN_PORTS; do
    [[ "$NO_WAN" != 1 && "$wanm" == *",${p},"* ]] && die "${p} is the wan bridge's port — it cannot carry lan as well (--no-wan gives it up)"
    [[ -z "$(ip -o -4 addr show "$p" 2>/dev/null)" ]] || die "${p} has an address of its own — not a free port"
  done
  cur="$(cat "$INTERFACES")"
  new="$(lb_set_lan "$LAN_BRIDGE_PORT" "$LAN_STANZA" "$LAN_MTU" <<<"$cur")"
  [[ "$NO_WAN" == 1 ]] && new="$(lb_wan_none <<<"$new")"
  [[ -n "$WAN_PORT" ]] && new="$(lb_wan_port "$WAN_PORT" <<<"$new")"
  info "${BOLD}lan uplink${CL} ← $(lan_desc)$([[ "$NO_WAN" == 1 ]] && echo "; wan ← no port")$([[ -n "$WAN_PORT" ]] && echo "; wan ← ${WAN_PORT}")"
  if [[ "$new" == "$cur" ]]; then
    info "${GN}✓${CL} ${INTERFACES} already says so — nothing to change."
    [[ "$DRY_RUN" == 1 ]] || echo ok > "$SET_LAN_RESULT"
    exit 0
  fi
  diff -u <(printf '%s\n' "$cur") <(printf '%s\n' "$new") | tail -n +3 || true
  if [[ "$DRY_RUN" == 1 ]]; then info "Dry-run: not writing or applying. Re-run with --apply to commit."; exit 0; fi

  BACKUP="${INTERFACES}.tappaas.$(date +%Y%m%d-%H%M%S).bak"
  cp -a "$INTERFACES" "$BACKUP"
  printf '%s\n' "$new" > "$INTERFACES"
  rm -f "$SET_LAN_RESULT"
  info "Backed up → ${BACKUP}; arming a ${ROLLBACK_SECS}s rollback, then applying ..."
  arm_rollback
  apply_network || warn "Apply returned non-zero — checking connectivity."

  # The node's own check: its gateway on lan answers through the new uplink.
  gw="$(awk '/^iface lan /{f=1;next} /^[^ \t]/{f=0} f&&$1=="gateway"{print $2;exit}' "$INTERFACES")"
  gw="${gw:-$FW_IP}"
  ok=0
  for _i in $(seq 1 10); do ping -c1 -W2 "$gw" >/dev/null 2>&1 && { ok=1; break; }; sleep 1; done
  if [[ "$ok" != 1 ]]; then
    echo "fail gateway ${gw} unreachable on the new uplink" > "$SET_LAN_RESULT"
    warn "Gateway ${gw} not reachable on the new uplink — the node reverts to ${BACKUP} within ${ROLLBACK_SECS}s."
    exit 1
  fi
  echo ok > "$SET_LAN_RESULT"
  if [[ "$CONFIRM_EXTERNAL" == 1 ]]; then
    info "${GN}✓${CL} gateway ${gw} answers — waiting for the caller to confirm (touch ${ROLLBACK_OK}) within ${ROLLBACK_SECS}s."
  else
    touch "$ROLLBACK_OK"
    info "${GN}✓${CL} gateway ${gw} answers — change kept."
  fi
}
if [[ "$SET_LAN" == "1" ]]; then set_lan; exit 0; fi

# ── Idempotency: is the node network already built? (early, clean no-op) ──
# Once `lan` holds this node's mgmt IP with both bridges present, the node's
# network model is already in place and a re-run must change nothing. Bail HERE,
# BEFORE role detection: detect_node_role() keys off the presence of a 10.0.0.x
# address, so after a good first-node build it would report "secondary" (correct
# by its own definition) and invert the LAN/WAN planning. Exiting early keeps the
# re-run an unambiguous no-op — no misleading "secondary" banner, no wrong-default
# port prompts. Only reached in the default bridge-build mode (--swap-gateway /
# --drop-upstream returned above). A --dry-run still falls through to preview the
# plan; a genuine rebuild still proceeds if either bridge is missing or the mgmt IP
# differs (partial / mis-config self-heals).
if [[ "$DRY_RUN" != "1" ]] && ip link show lan &>/dev/null && ip link show wan &>/dev/null; then
  want_mgmt="$(node_mgmt_ip)/24"
  cur_lan_ip="$(ip -o -4 addr show lan 2>/dev/null | awk '{print $4; exit}')"
  if [[ "$cur_lan_ip" == "$want_mgmt" ]]; then
    lan_ports="$(bridge_members lan)"; wan_ports="$(bridge_members wan)"
    info "${GN}✓${CL} Node network already configured — nothing to do (idempotent re-run)."
    info "  lan=${BL}${lan_ports:-<none>}${CL} (${cur_lan_ip})   wan=${BL}${wan_ports:-<none>}${CL}"
    exit 0
  fi
fi

valid_port() { local p="$1" x; for x in "${PORTS[@]}"; do [[ "$x" == "$p" ]] && return 0; done; return 1; }
other_port() { local exclude="$1" p; for p in "${PORTS[@]}"; do [[ "$p" == "$exclude" ]] || { echo "$p"; return 0; }; done; return 1; }

# The physical NIC that currently carries the install IP (member of the bridge
# that owns the default route, e.g. vmbr0 on a fresh PVE install).
detect_install_nic() {
  local defbr member m
  defbr="$(ip -o -4 route show default 2>/dev/null | grep -oE 'dev [^ ]+' | awk '{print $2; exit}')"
  [[ -n "$defbr" ]] || defbr="vmbr0"
  for member in "${PORTS[@]}"; do
    m="$(ip -o link show "$member" 2>/dev/null | grep -oE 'master [^ ]+' | awk '{print $2}')"
    [[ "$m" == "$defbr" ]] && { echo "$member"; return 0; }
  done
  for member in "${PORTS[@]}"; do
    [[ "$(cat "/sys/class/net/${member}/operstate" 2>/dev/null)" == "up" ]] && { echo "$member"; return 0; }
  done
  return 1
}

# ── Node role ─────────────────────────────────────────────────────────
# Secondary = already on the TAPPaaS mgmt network (joining an existing cluster):
# our default gateway is the firewall, or we already hold a 10.0.0.x address.
detect_node_role() {
  local gw mgmt
  gw="$(ip -o -4 route show default 2>/dev/null | awk '{print $3; exit}')"
  mgmt="$(ip -o -4 addr show 2>/dev/null | awk '{print $4}' | grep -E "^${MGMT_SUBNET//./\\.}\." | head -1)"
  if [[ "$gw" == "$FW_IP" || -n "$mgmt" ]]; then echo "secondary"; else echo "first"; fi
}

ROLE="$(detect_node_role)"
INSTALL_NIC="$(detect_install_nic || true)"
info "Node role: ${BOLD}${ROLE}${CL}${INSTALL_NIC:+  (install NIC: ${BL}${INSTALL_NIC}${CL})}"

# ── Current install IP / gateway (kept on the wan bridge for the first node) ──
INSTALL_CIDR="$(ip -o -4 addr show 2>/dev/null | awk '/vmbr0|wan|lan/{print $4; exit}')"
INSTALL_GW="${GATEWAY:-$(ip -o -4 route show default 2>/dev/null | awk '{print $3; exit}')}"
LAN_MGMT_IP="$(node_mgmt_ip)/24"

# ── Port assignment by role ──────────────────────────────────────────
# first node : install NIC (upstream internet) → WAN; the other → LAN (switch).
# secondary  : install NIC (already on mgmt net) → LAN; the other → WAN (HA-ready).
if [[ "$ROLE" == "first" ]]; then
  DEFAULT_WAN="$INSTALL_NIC"
  DEFAULT_LAN="$(other_port "$INSTALL_NIC" || true)"
else
  DEFAULT_LAN="$INSTALL_NIC"
  DEFAULT_WAN="$(other_port "$INSTALL_NIC" || true)"
fi
# Ports given for lan are never the WAN default: with two lan ports the "other"
# NIC above may be one of them (#40).
if [[ -n "$LAN_PORT" ]]; then
  _lan_given=" $(lb_ports "$LAN_PORT" 2>/dev/null || true) "
  if [[ "$_lan_given" == *" ${DEFAULT_WAN} "* ]]; then
    DEFAULT_WAN=""
    for _p in "${PORTS[@]}"; do [[ "$_lan_given" == *" ${_p} "* ]] || { DEFAULT_WAN="$_p"; break; }; done
  fi
fi

# ── Port selection (auto-detected defaults; operator may override) ───
pick_port() {
  local title="$1" exclude="${2:-}" default="${3:-}"
  local -a wt=()
  local x
  for x in "${!PORTS[@]}"; do
    [[ "${PORTS[$x]}" == "$exclude" ]] && continue
    wt+=("${PORTS[$x]}" "${PORT_DESCS[$x]}")
  done
  if [[ "$HAVE_WHIPTAIL" == "1" ]]; then
    local -a dflt=(); [[ -n "$default" ]] && dflt=(--default-item "$default")
    whiptail --title "TAPPaaS network" "${dflt[@]}" --menu "$title" 20 78 10 "${wt[@]}" 3>&1 1>&2 2>&3
  else
    echo "$title" >&2
    for x in "${!PORTS[@]}"; do [[ "${PORTS[$x]}" == "$exclude" ]] || echo "  ${PORTS[$x]} — ${PORT_DESCS[$x]}" >&2; done
    local ans prompt="port: "
    [[ -n "$default" ]] && prompt="port [${default}]: "
    read -r -p "$prompt" ans >&2; echo "${ans:-$default}"
  fi
}

if [[ -z "$WAN_PORT" ]]; then
  if [[ "$INTERACTIVE" == "1" ]]; then
    if [[ "$ROLE" == "first" ]]; then
      WAN_TEXT="This is the PRIMARY node.\n\nSelect the WAN port — the NIC connected to your upstream router/switch (internet uplink). The TAPPaaS firewall VM will use this port for outbound traffic."
    else
      WAN_TEXT="This is a SECONDARY node.\n\nSelect the WAN port — a spare NIC reserved for firewall HA failover. This port will remain idle until firewall HA is activated."
    fi
    WAN_PORT="$(pick_port "$WAN_TEXT" "" "$DEFAULT_WAN")"
  else
    WAN_PORT="$DEFAULT_WAN"
    [[ -n "$WAN_PORT" ]] && info "Auto-selected WAN port ${BL}${WAN_PORT}${CL}." \
      || warn "No WAN port (single NIC?) — 'wan' bridge will have no port (attach later for firewall HA)."
  fi
fi
[[ -n "$WAN_PORT" ]] && { valid_port "$WAN_PORT" || die "WAN port '${WAN_PORT}' is not a physical port."; }

if [[ -z "$LAN_PORT" ]]; then
  if [[ "$INTERACTIVE" == "1" ]]; then
    if [[ "$ROLE" == "first" ]]; then
      LAN_TEXT="This is the PRIMARY node.\n\nSelect the LAN port — the NIC connected to your switch for interconnecting LAN of TAPPaaS systems. This port carries VLAN trunks and hosts the management IP."
    else
      LAN_TEXT="This is a SECONDARY node.\n\nSelect the LAN port — the NIC connected to your switch for interconnecting LAN of TAPPaaS systems. This is typically the port you used to reach this node during installation."
    fi
    LAN_PORT="$(pick_port "$LAN_TEXT" "$WAN_PORT" "$DEFAULT_LAN")"
  else
    LAN_PORT="$DEFAULT_LAN"
    [[ -n "$LAN_PORT" ]] || die "No --lan-port given, not interactive, and could not auto-detect the LAN NIC."
    info "Auto-selected LAN port ${BL}${LAN_PORT}${CL}."
  fi
fi
prepare_usb_ports   # a USB lan port is pinned and rejoins its bond (#849), as with --set-lan
resolve_lan
[[ -n "$WAN_PORT" && " $LAN_PORTS " == *" ${WAN_PORT} "* ]] && die "LAN and WAN ports must differ."

# ── Render the new /etc/network/interfaces ───────────────────────────
# first node : wan keeps the install IP + upstream gateway (internet during
#              bootstrap); lan gets the mgmt IP, no gateway yet — the cutover
#              (--swap-gateway) later moves the default route to the firewall.
# secondary  : lan gets the mgmt IP + firewall gateway (already on the mgmt net);
#              wan is wired but IP-less, ready for firewall HA.
render_interfaces() {
  local p
  cat <<EOF
# network interface settings; generated by TAPPaaS config-network.sh
auto lo
iface lo inet loopback

EOF
  for p in "${PORTS[@]}"; do printf 'iface %s inet manual\n' "$p"; done

  if [[ "$ROLE" == "first" ]]; then
    cat <<EOF

auto wan
iface wan inet static
	address ${INSTALL_CIDR:-0.0.0.0/24}
	gateway ${INSTALL_GW:-}
	bridge-ports ${WAN_PORT:-none}
	bridge-stp off
	bridge-fd 0

${LAN_STANZA:+${LAN_STANZA}

}auto lan
iface lan inet static
	address ${LAN_MGMT_IP}
	bridge-ports ${LAN_BRIDGE_PORT}
	bridge-stp off
	bridge-fd 0
	bridge-vlan-aware yes
	bridge-vids 2-4094
EOF
  else
    cat <<EOF

auto wan
iface wan inet manual
	bridge-ports ${WAN_PORT:-none}
	bridge-stp off
	bridge-fd 0

${LAN_STANZA:+${LAN_STANZA}

}auto lan
iface lan inet static
	address ${LAN_MGMT_IP}
	gateway ${FW_IP}
	bridge-ports ${LAN_BRIDGE_PORT}
	bridge-stp off
	bridge-fd 0
	bridge-vlan-aware yes
	bridge-vids 2-4094
EOF
  fi
}

NEW_CONFIG="$(render_interfaces)"

echo ""
info "${BOLD}Planned network configuration (${ROLE} node):${CL}"
if [[ "$ROLE" == "first" ]]; then
  info "  wan  ← port ${BL}${WAN_PORT:-<none>}${CL}   ip ${BL}${INSTALL_CIDR:-?}${CL}  gw ${BL}${INSTALL_GW:-?}${CL}  (upstream uplink + node internet)"
  info "  lan  ← port ${BL}$(lan_desc)${CL}   ip ${BL}${LAN_MGMT_IP}${CL}  (mgmt; gateway set at cutover)  (vlan-aware trunk 2-4094)"
else
  info "  lan  ← port ${BL}$(lan_desc)${CL}   ip ${BL}${LAN_MGMT_IP}${CL}  gw ${BL}${FW_IP}${CL}  (vlan-aware trunk 2-4094)"
  info "  wan  ← port ${BL}${WAN_PORT:-<none>}${CL}   (wired for firewall HA; no IP)"
fi
# The full generated file is useful on a dry-run preview (or when debugging), but
# it's just noise during a normal apply — suppress it there.
if [[ "$DRY_RUN" == "1" || "${TAPPAAS_DEBUG:-0}" == "1" ]]; then
  echo "----------------------------------------------------------------"
  echo "$NEW_CONFIG"
  echo "----------------------------------------------------------------"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  info "Dry-run: not writing or applying. Re-run with --apply to commit."
  exit 0
fi

# ── Guard: management client inside the new lan subnet ───────────────
# If you are connected over SSH from a host INSIDE the management subnet (the one
# about to go on `lan`), bringing `lan` up makes the node treat that subnet as
# link-local: its replies to you leave via `lan` instead of the gateway, and your
# session freezes (the gateway self-check still passes, so it would NOT revert).
# Run the cutover from a client on the install/upstream network, or a console.
mgmt_prefix="${LAN_MGMT_IP%/*}"; mgmt_prefix="${mgmt_prefix%.*}"   # e.g. 10.0.0
ssh_src="${SSH_CLIENT:-}"; ssh_src="${ssh_src%% *}"               # empty when not over SSH (set -u safe)
if [[ -n "$ssh_src" && "$ssh_src" == "${mgmt_prefix}".* ]]; then
  echo ""
  warn "${BOLD}⚠  Your SSH client ${ssh_src} is inside the management subnet ${mgmt_prefix}.0/24.${CL}"
  warn "   When 'lan' comes up the node routes that subnet out 'lan', so THIS SSH"
  warn "   session will freeze (and the gateway self-check won't revert it)."
  warn "   Run from the install/upstream network or the node console instead."
  if [[ "$INTERACTIVE" == "1" ]]; then
    read -r -p "   Continue anyway and risk losing this session? [y/N]: " _cap
    [[ "${_cap,,}" == "y" ]] || { info "Aborted (safe choice)."; exit 0; }
  fi
fi

if [[ "$INTERACTIVE" == "1" ]]; then
  if [[ "$HAVE_WHIPTAIL" == "1" ]]; then
    whiptail --title "TAPPaaS network" --yesno \
      "Apply this network configuration?\n\nrole: ${ROLE}\nlan ← $(lan_desc) (${LAN_MGMT_IP})\nwan ← ${WAN_PORT:-none}\n\nA ${ROLLBACK_SECS}s auto-rollback protects against lockout." 16 72 \
      || { info "Aborted by operator."; exit 0; }
  else
    read -r -p "Apply this configuration? [y/N]: " yn
    [[ "${yn,,}" == "y" ]] || { info "Aborted."; exit 0; }
  fi
fi

# ── Backup + write ───────────────────────────────────────────────────
# The "already configured → no-op" fast path is handled earlier (the idempotency
# guard right after the port inventory, before role detection). Reaching here
# means the config genuinely needs to be (re)built.
BACKUP="${INTERFACES}.tappaas.$(date +%Y%m%d-%H%M%S).bak"
cp -a "$INTERFACES" "$BACKUP"
info "Backed up current config → ${BACKUP}"
printf '%s\n' "$NEW_CONFIG" >"$INTERFACES"

if [[ "$DO_ROLLBACK" == "1" ]]; then
  info "Arming ${ROLLBACK_SECS}s auto-rollback ..."
  arm_rollback
fi

info "Applying network configuration ..."
apply_network || warn "Apply returned non-zero — connectivity may have changed."

if [[ "$DO_ROLLBACK" == "1" ]]; then
  # Confirm by an automatic connectivity self-check, NOT an interactive prompt.
  # The bridge rebuild briefly blips the network, which drops a web (xterm.js)
  # console — so a "type keep" prompt is unreliable (the operator can't answer in
  # time and the node wrongly reverts). Instead the node pings its own gateway,
  # retrying through the blip: reachable → keep; unreachable → the armed timer
  # reverts (e.g. genuinely mis-detected ports).
  selfcheck_gw="$INSTALL_GW"
  [[ "$ROLE" == "secondary" ]] && selfcheck_gw="$FW_IP"
  echo ""
  if [[ -z "$selfcheck_gw" ]]; then
    touch "$ROLLBACK_OK"
    info "${GN}✓${CL} No gateway to self-check against — keeping the change."
  else
    info "Verifying connectivity after the change (ping gateway ${BL}${selfcheck_gw}${CL}, ~40s window)..."
    ok=0
    for _i in $(seq 1 20); do
      ping -c1 -W2 "$selfcheck_gw" >/dev/null 2>&1 && { ok=1; break; }
      sleep 2
    done
    if [[ "$ok" == "1" ]]; then
      touch "$ROLLBACK_OK"
      info "${GN}✓${CL} Gateway reachable — change confirmed and made permanent."
    else
      warn "Gateway ${selfcheck_gw} not reachable after the change."
      warn "The node will auto-revert to ${BACKUP} in ~${ROLLBACK_SECS}s (safety rollback)."
      warn "If the LAN/WAN ports were mis-detected, re-run with --lan-port/--wan-port."
      exit 1
    fi
  fi
fi

info "${GN}Network configuration complete.${CL}"
info "  role=${ROLE}  lan=$(lan_desc) (${LAN_MGMT_IP})  wan=${WAN_PORT:-none}"
