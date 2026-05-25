#!/usr/bin/env bash
#
# TAPPaaS Network Configuration (config-network.sh)  — issue #141
#
# Builds the TAPPaaS node network model on a fresh Proxmox VE host:
#
#   lan : VLAN-aware bridge carrying the management network (untagged) plus
#         every TAPPaaS VLAN (2-4094) as a trunk to the managed switch. Holds
#         this node's management IP. The OPNsense firewall VM and all guest
#         VLAN interfaces attach here.
#   wan : plain bridge for the upstream/ISP uplink (the firewall VM's WAN).
#
# A fresh PVE install creates a single default bridge (vmbr0) holding the
# install-time management IP on whatever NIC was primary. This script lets the
# operator pick which physical port is LAN and which is WAN (from a list that
# shows MAC / link / speed so ports can be told apart), then rewrites
# /etc/network/interfaces accordingly and applies it with an automatic
# rollback so a wrong choice cannot permanently lock the node out.
#
# It is also the script referenced by the firewall "Swap cables" step, and can
# be re-run at any time to re-assign ports.
#
# Usage:
#   config-network.sh [--lan-port <ifname>] [--wan-port <ifname>]
#                     [--mgmt-ip <CIDR>] [--gateway <ip>]
#                     [--no-rollback] [--apply|--dry-run] [--non-interactive]
#                     [-h|--help]
#
# Defaults:
#   --mgmt-ip / --gateway : preserved from the current default bridge if not given.
#   rollback timeout      : 90s (revert unless the operator confirms connectivity).
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

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; /^set -euo/d'; }

# ── Arguments ────────────────────────────────────────────────────────
LAN_PORT="" WAN_PORT="" MGMT_IP="" GATEWAY=""
DO_ROLLBACK=1 INTERACTIVE=1 DRY_RUN=0 ROLLBACK_SECS=90
SWAP_CABLES=0 FW_IP="10.0.0.1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lan-port)        LAN_PORT="${2:-}"; shift 2 ;;
    --wan-port)        WAN_PORT="${2:-}"; shift 2 ;;
    --mgmt-ip)         MGMT_IP="${2:-}"; shift 2 ;;
    --gateway)         GATEWAY="${2:-}"; shift 2 ;;
    --swap-cables)     SWAP_CABLES=1; shift ;;
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

# ── Swap-cables: post-firewall node transition (issue #141) ─────────
# Once the OPNsense firewall is up at FW_IP, point this node at it for routing
# and DNS. Changing only the default route + resolver + /etc/hosts does not drop
# the node's own lan IP, so a management session on the lan subnet is unaffected
# (no rollback needed). corosync is advised, never auto-edited on a live cluster.
swap_cables() {
  local lan_ip host
  lan_ip="$(ip -o -4 addr show lan 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
  host="$(hostname -s)"
  info "Swap-cables: routing + DNS via the firewall (${BL}${FW_IP}${CL})"

  info "  /etc/resolv.conf → nameserver ${FW_IP}"
  cp -a /etc/resolv.conf "/etc/resolv.conf.tappaas.$(date +%Y%m%d-%H%M%S).bak" 2>/dev/null || true
  printf 'search internal mgmt.internal\nnameserver %s\n' "$FW_IP" > /etc/resolv.conf

  if [[ -n "$lan_ip" ]]; then
    info "  /etc/hosts → ${lan_ip} ${host}.mgmt.internal ${host}"
    sed -i -E "/[[:space:]]${host}([[:space:]]|\$)/d" /etc/hosts 2>/dev/null || true
    printf '%s %s.mgmt.internal %s\n' "$lan_ip" "$host" "$host" >> /etc/hosts
  fi

  cp -a "$INTERFACES" "${INTERFACES}.tappaas.$(date +%Y%m%d-%H%M%S).bak"
  if grep -qE '^[[:space:]]*gateway[[:space:]]' "$INTERFACES"; then
    sed -i -E "s|^([[:space:]]*gateway[[:space:]]+).*|\1${FW_IP}|" "$INTERFACES"
  else
    sed -i -E "/^iface lan inet static/,/^[[:space:]]*\$/ s|^([[:space:]]*address[[:space:]].*)|\1\n\tgateway ${FW_IP}|" "$INTERFACES"
  fi
  info "  default gateway → ${FW_IP}; reloading network..."
  ifreload -a 2>/dev/null || systemctl restart networking || warn "network reload returned non-zero"

  if [[ -f /etc/pve/corosync.conf ]]; then
    if [[ -n "$lan_ip" ]] && grep -q "$lan_ip" /etc/pve/corosync.conf 2>/dev/null; then
      info "  ${GN}✓${CL} corosync.conf already references ${lan_ip}"
    else
      warn "  If this node's mgmt IP changed, update ring0_addr in /etc/pve/corosync.conf"
      warn "  to ${lan_ip:-<lan ip>}, bump config_version, then: systemctl restart corosync"
    fi
  fi

  info "${GN}Swap-cables complete.${CL} Verify: ping ${FW_IP}; ping 8.8.8.8; nslookup firewall.mgmt.internal"
}

if [[ "$SWAP_CABLES" == "1" ]]; then
  swap_cables
  exit 0
fi

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

# ── Derive current management IP / gateway (defaults) ────────────────
# Prefer the source IP of the default route; fall back to the first bridge IP.
if [[ -z "$MGMT_IP" ]]; then
  cur_ip="$(ip -o -4 addr show 2>/dev/null | awk '/vmbr0|lan/{print $4; exit}')"
  MGMT_IP="${cur_ip:-10.0.0.10/24}"
fi
[[ "$MGMT_IP" == */* ]] || MGMT_IP="${MGMT_IP}/24"
if [[ -z "$GATEWAY" ]]; then
  GATEWAY="$(ip -o -4 route show default 2>/dev/null | awk '{print $3; exit}')"
  GATEWAY="${GATEWAY:-10.0.0.1}"
fi

# ── Port selection ───────────────────────────────────────────────────
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

# ── Auto-detect sensible LAN/WAN defaults ────────────────────────────
# LAN = the physical NIC that currently carries the management IP, i.e. the
# member of the bridge that owns the default route (vmbr0 on a fresh PVE
# install). Keeping the mgmt IP on this port preserves the operator's session
# across the bridge rebuild — so it is the safe default.
detect_lan_port() {
  local defbr member m
  defbr="$(ip -o -4 route show default 2>/dev/null | grep -oE 'dev [^ ]+' | awk '{print $2; exit}')"
  [[ -n "$defbr" ]] || defbr="vmbr0"
  for member in "${PORTS[@]}"; do
    m="$(ip -o link show "$member" 2>/dev/null | grep -oE 'master [^ ]+' | awk '{print $2}')"
    [[ "$m" == "$defbr" ]] && { echo "$member"; return 0; }
  done
  # Fallback: first physical port whose link is up.
  for member in "${PORTS[@]}"; do
    [[ "$(cat "/sys/class/net/${member}/operstate" 2>/dev/null)" == "up" ]] && { echo "$member"; return 0; }
  done
  return 1
}

# WAN = the sole remaining physical NIC (only unambiguous with exactly two).
detect_wan_port() {
  local lan="$1" only="" cnt=0 p
  for p in "${PORTS[@]}"; do
    [[ "$p" == "$lan" ]] && continue
    only="$p"; cnt=$((cnt + 1))
  done
  [[ "$cnt" == "1" ]] && { echo "$only"; return 0; }
  return 1
}

DEFAULT_LAN="$(detect_lan_port || true)"
[[ -n "$DEFAULT_LAN" ]] && info "Detected management NIC (default LAN port): ${BL}${DEFAULT_LAN}${CL}"

if [[ -z "$LAN_PORT" ]]; then
  if [[ "$INTERACTIVE" == "1" ]]; then
    LAN_PORT="$(pick_port "Select the LAN port (VLAN trunk + management IP ${MGMT_IP}).\nThis connects to the managed switch." "" "$DEFAULT_LAN")"
  else
    LAN_PORT="$DEFAULT_LAN"
    [[ -n "$LAN_PORT" ]] || die "No --lan-port given, not interactive, and could not auto-detect the management NIC."
    info "Auto-selected LAN port ${BL}${LAN_PORT}${CL} (member of the management bridge)."
  fi
fi
valid_port "$LAN_PORT" || die "LAN port '${LAN_PORT}' is not a physical port."

DEFAULT_WAN="$(detect_wan_port "$LAN_PORT" || true)"

if [[ -z "$WAN_PORT" ]]; then
  if [[ "$INTERACTIVE" == "1" ]]; then
    WAN_PORT="$(pick_port "Select the WAN port (upstream/ISP uplink for the firewall).\nMust differ from LAN (${LAN_PORT})." "$LAN_PORT" "$DEFAULT_WAN")"
  elif [[ -n "$DEFAULT_WAN" ]]; then
    WAN_PORT="$DEFAULT_WAN"
    info "Auto-selected WAN port ${BL}${WAN_PORT}${CL} (sole remaining NIC)."
  else
    warn "No --wan-port given — creating 'wan' bridge with no port (attach later)."
  fi
fi
if [[ -n "$WAN_PORT" ]]; then
  valid_port "$WAN_PORT" || die "WAN port '${WAN_PORT}' is not a physical port."
  [[ "$WAN_PORT" == "$LAN_PORT" ]] && die "LAN and WAN ports must differ."
fi

# ── Render the new /etc/network/interfaces ───────────────────────────
render_interfaces() {
  local p
  cat <<EOF
# network interface settings; generated by TAPPaaS config-network.sh
auto lo
iface lo inet loopback

EOF
  for p in "${PORTS[@]}"; do printf 'iface %s inet manual\n' "$p"; done
  cat <<EOF

auto wan
iface wan inet manual
	bridge-ports ${WAN_PORT:-none}
	bridge-stp off
	bridge-fd 0

auto lan
iface lan inet static
	address ${MGMT_IP}
	gateway ${GATEWAY}
	bridge-ports ${LAN_PORT}
	bridge-stp off
	bridge-fd 0
	bridge-vlan-aware yes
	bridge-vids 2-4094
EOF
}

NEW_CONFIG="$(render_interfaces)"

echo ""
info "${BOLD}Planned network configuration:${CL}"
info "  lan  ← port ${BL}${LAN_PORT}${CL}   ip ${BL}${MGMT_IP}${CL}  gw ${BL}${GATEWAY}${CL}  (vlan-aware trunk 2-4094)"
info "  wan  ← port ${BL}${WAN_PORT:-<none>}${CL}"
echo "----------------------------------------------------------------"
echo "$NEW_CONFIG"
echo "----------------------------------------------------------------"

if [[ "$DRY_RUN" == "1" ]]; then
  info "Dry-run: not writing or applying. Re-run with --apply to commit."
  exit 0
fi

if [[ "$INTERACTIVE" == "1" ]]; then
  if [[ "$HAVE_WHIPTAIL" == "1" ]]; then
    whiptail --title "TAPPaaS network" --yesno \
      "Apply this network configuration?\n\nlan ← ${LAN_PORT} (${MGMT_IP})\nwan ← ${WAN_PORT:-none}\n\nA ${ROLLBACK_SECS}s auto-rollback protects against lockout." 16 72 \
      || { info "Aborted by operator."; exit 0; }
  else
    read -r -p "Apply this configuration? [y/N]: " yn
    [[ "${yn,,}" == "y" ]] || { info "Aborted."; exit 0; }
  fi
fi

# ── Backup + write ───────────────────────────────────────────────────
BACKUP="${INTERFACES}.tappaas.$(date +%Y%m%d-%H%M%S).bak"
cp -a "$INTERFACES" "$BACKUP"
info "Backed up current config → ${BACKUP}"
printf '%s\n' "$NEW_CONFIG" >"$INTERFACES"

# ── Auto-rollback guard (prevents permanent lockout) ─────────────────
# A one-shot timer restores the backup unless the operator confirms
# connectivity (which removes the guard). If applying the new config drops
# the operator's session, the node self-heals back to the working config.
arm_rollback() {
  rm -f "$ROLLBACK_OK"
  cat >"$ROLLBACK_BIN" <<EOF
#!/bin/sh
# Cancellation is by sentinel file, not by unit name: the operator confirming
# the change (touch ${ROLLBACK_OK}) makes this a no-op even though the timer
# still fires.
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
  # Invoke explicitly via /bin/sh: systemd-run with a *bare script path* as
  # ExecStart was observed to never actually execute the script body (the
  # transient service just sat "running"), silently leaving the node
  # unprotected. Passing the interpreter explicitly runs it reliably.
  # No --unit: let systemd-run auto-generate a unique transient unit name so
  # repeated runs never collide with a lingering unit from a previous arm.
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
  echo ""
  warn "${BOLD}Verify you still have connectivity to this node NOW.${CL}"
  warn "If you do nothing, the node auto-reverts in ~${ROLLBACK_SECS}s."
  CONFIRM=""
  if [[ "$INTERACTIVE" == "1" ]]; then
    read -r -t "$((ROLLBACK_SECS - 10))" -p "Type 'keep' to make the change permanent: " CONFIRM || true
  fi
  if [[ "$CONFIRM" == "keep" ]]; then
    # The sentinel cancels the pending revert: when the timer fires it will see
    # the file and skip (and clean itself up).
    touch "$ROLLBACK_OK"
    info "${GN}✓${CL} Network change confirmed and made permanent."
  else
    warn "Not confirmed — the node will auto-revert to ${BACKUP}."
    warn "If you got disconnected, reconnect via the previous network or console."
    exit 1
  fi
fi

info "${GN}Network configuration complete.${CL}"
info "  lan=${LAN_PORT} (${MGMT_IP})  wan=${WAN_PORT:-none}"
