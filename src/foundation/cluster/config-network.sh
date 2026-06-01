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
#
# Usage:
#   config-network.sh [--lan-port <ifname>] [--wan-port <ifname>]
#                     [--mgmt-ip <CIDR>] [--gateway <ip>] [--fw-ip <ip>]
#                     [--swap-gateway [--admin-route <CIDR>] | --drop-upstream]
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
die()   { error "$*"; exit 1; }

readonly INTERFACES=/etc/network/interfaces
readonly ROLLBACK_BIN=/usr/local/sbin/tappaas-net-rollback.sh
readonly ROLLBACK_OK=/run/tappaas-net-ok
readonly MGMT_SUBNET="10.0.0"   # /24 management network prefix

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; /^set -euo/d'; }

# ── Arguments ────────────────────────────────────────────────────────
LAN_PORT="" WAN_PORT="" MGMT_IP="" GATEWAY="" ADMIN_ROUTE=""
DO_ROLLBACK=1 INTERACTIVE=1 DRY_RUN=0 ROLLBACK_SECS=90
SWAP_GATEWAY=0 DROP_UPSTREAM=0 FW_IP="${MGMT_SUBNET}.1"

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
    --no-rollback)     DO_ROLLBACK=0; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    --apply)           DRY_RUN=0; shift ;;
    --non-interactive) INTERACTIVE=0; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) error "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Must run as root."
command -v ifreload >/dev/null || warn "ifreload not found — will fall back to 'systemctl restart networking'."
HAVE_WHIPTAIL=0; command -v whiptail >/dev/null && HAVE_WHIPTAIL=1
[[ -t 0 && -t 1 ]] || INTERACTIVE=0

# ── Shared helpers ────────────────────────────────────────────────────

# This node's management IP on the lan bridge: 10.0.0.<9+N> for tappaasN.
# TAPPaaS reserves 10.0.0.10-18 for tappaas1-9 (the firewall ships DNS host
# entries + static reservations for exactly those nine). A 10th+ node has no
# reserved mgmt IP / DNS name, so refuse rather than silently mis-assign.
node_mgmt_ip() {
  if [[ -n "$MGMT_IP" ]]; then echo "${MGMT_IP%/*}"; return; fi
  local n; n="$(hostname -s | grep -oE '[0-9]+$' || true)"
  if [[ -n "$n" && "$n" -gt 9 ]]; then
    die "Node number ${n} (tappaas${n}) exceeds the supported 9 nodes (tappaas1-9 → 10.0.0.10-18). Assign manually with --mgmt-ip and add a firewall DNS host entry."
  fi
  if [[ -n "$n" ]]; then echo "${MGMT_SUBNET}.$((9 + n))"; else echo "${MGMT_SUBNET}.10"; fi
}

# Address currently held on bridge $1 (CIDR), empty if none.
bridge_ip() { ip -o -4 addr show "$1" 2>/dev/null | awk '{print $4; exit}'; }

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
    info "Your default route is moving to the firewall (${FW_IP})."
    info "If you manage this node from a network reached via the current upstream"
    info "gateway (${old_gw}) — e.g. an admin/jump LAN — enter it to keep a route to it."
    read -r -p "  Management network/IP to keep via ${old_gw} (CIDR, or blank for none): " ADMIN_ROUTE
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
    info "  corosync ring0_addr already on the mgmt net — no change."
  fi

  # 6. Apply. Additive, so the existing session survives; restart corosync to
  #    rebind to the mgmt IP without a reboot.
  info "  reloading network + restarting corosync (no reboot needed)..."
  ifreload -a 2>/dev/null || systemctl restart networking || warn "network reload returned non-zero"
  systemctl restart corosync pve-cluster 2>/dev/null || warn "corosync/pve-cluster restart returned non-zero"

  info "${GN}Gateway cutover complete.${CL} Node mgmt ${BL}${mgmt_ip}${CL}, routing via the firewall."
  info "  Verify: ping ${FW_IP}; ping 8.8.8.8; pvecm status"
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
    WAN_PORT="$(pick_port "Select the WAN port (upstream/ISP uplink for the firewall).\nFirst node: the NIC connected to your router. Secondary: spare NIC for firewall HA." "" "$DEFAULT_WAN")"
  else
    WAN_PORT="$DEFAULT_WAN"
    [[ -n "$WAN_PORT" ]] && info "Auto-selected WAN port ${BL}${WAN_PORT}${CL}." \
      || warn "No WAN port (single NIC?) — 'wan' bridge will have no port (attach later for firewall HA)."
  fi
fi
[[ -n "$WAN_PORT" ]] && { valid_port "$WAN_PORT" || die "WAN port '${WAN_PORT}' is not a physical port."; }

if [[ -z "$LAN_PORT" ]]; then
  if [[ "$INTERACTIVE" == "1" ]]; then
    LAN_PORT="$(pick_port "Select the LAN port (VLAN trunk + management IP, → downstream switch)." "$WAN_PORT" "$DEFAULT_LAN")"
  else
    LAN_PORT="$DEFAULT_LAN"
    [[ -n "$LAN_PORT" ]] || die "No --lan-port given, not interactive, and could not auto-detect the LAN NIC."
    info "Auto-selected LAN port ${BL}${LAN_PORT}${CL}."
  fi
fi
valid_port "$LAN_PORT" || die "LAN port '${LAN_PORT}' is not a physical port."
[[ -n "$WAN_PORT" && "$WAN_PORT" == "$LAN_PORT" ]] && die "LAN and WAN ports must differ."

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

auto lan
iface lan inet static
	address ${LAN_MGMT_IP}
	bridge-ports ${LAN_PORT}
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

auto lan
iface lan inet static
	address ${LAN_MGMT_IP}
	gateway ${FW_IP}
	bridge-ports ${LAN_PORT}
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
  info "  lan  ← port ${BL}${LAN_PORT}${CL}   ip ${BL}${LAN_MGMT_IP}${CL}  (mgmt; gateway set at cutover)  (vlan-aware trunk 2-4094)"
else
  info "  lan  ← port ${BL}${LAN_PORT}${CL}   ip ${BL}${LAN_MGMT_IP}${CL}  gw ${BL}${FW_IP}${CL}  (vlan-aware trunk 2-4094)"
  info "  wan  ← port ${BL}${WAN_PORT:-<none>}${CL}   (wired for firewall HA; no IP)"
fi
echo "----------------------------------------------------------------"
echo "$NEW_CONFIG"
echo "----------------------------------------------------------------"

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
      "Apply this network configuration?\n\nrole: ${ROLE}\nlan ← ${LAN_PORT} (${LAN_MGMT_IP})\nwan ← ${WAN_PORT:-none}\n\nA ${ROLLBACK_SECS}s auto-rollback protects against lockout." 16 72 \
      || { info "Aborted by operator."; exit 0; }
  else
    read -r -p "Apply this configuration? [y/N]: " yn
    [[ "${yn,,}" == "y" ]] || { info "Aborted."; exit 0; }
  fi
fi

# ── Backup + write ───────────────────────────────────────────────────
# Check if the network is already configured correctly (skip apply if so).
# We check if the lan bridge exists with the correct IP rather than comparing
# config files, since role detection can change between runs.
CURRENT_LAN_IP="$(ip -o -4 addr show lan 2>/dev/null | awk '{print $4}' | head -1)"
if [[ "$CURRENT_LAN_IP" == "$LAN_MGMT_IP" ]] && ip link show lan &>/dev/null && ip link show wan &>/dev/null; then
  info "${GN}✓${CL} Network already configured (lan=${CURRENT_LAN_IP}, bridges exist) — skipping apply."
  info "  role=${ROLE}  lan=${LAN_PORT} (${LAN_MGMT_IP})  wan=${WAN_PORT:-none}"
  exit 0
fi

BACKUP="${INTERFACES}.tappaas.$(date +%Y%m%d-%H%M%S).bak"
cp -a "$INTERFACES" "$BACKUP"
info "Backed up current config → ${BACKUP}"
printf '%s\n' "$NEW_CONFIG" >"$INTERFACES"

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
  ifreload -a 2>/dev/null || systemctl restart networking
fi
rm -f "${ROLLBACK_BIN}"
EOF
  chmod 755 "$ROLLBACK_BIN"
  systemd-run --on-active="${ROLLBACK_SECS}" /bin/sh "$ROLLBACK_BIN" >/dev/null 2>&1 \
    || warn "Could not arm systemd rollback timer (proceeding without auto-rollback)."
}

apply_network() { ifreload -a 2>/dev/null || systemctl restart networking; }

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
info "  role=${ROLE}  lan=${LAN_PORT} (${LAN_MGMT_IP})  wan=${WAN_PORT:-none}"
