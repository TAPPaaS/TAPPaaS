#!/usr/bin/env bash
# TAPPaaS — Test network on a dedicated physical port (issue #225)
#
# Stands up an isolated test network served on a SPARE physical NIC of the
# Proxmox node that runs the firewall VM — separate from the VLAN trunk that
# carries the production zones. The flow:
#
#   1. Locate the node hosting the firewall VM.
#   2. Discover vacant physical ports on that node; ask the operator to pick one
#      (or take --port).
#   3. Create a Linux bridge on the node and enslave the chosen port
#      (persisted in /etc/network/interfaces, applied with ifreload).
#   4. Attach the bridge to the firewall VM as a new virtio NIC.
#   5. Drive the OPNsense side via `test-network-manager`: assign the interface
#      with a static gateway IP, enable DHCP, install the routing/firewall
#      policy (test→internet, mgmt→test, isolate everything else).
#
# --delete reverses every step in order. Default test net: 172.17.3.1/24.
#
# Routing policy:
#   test → internet            : allow (OPNsense automatic outbound NAT covers it)
#   test → internal (RFC1918)  : block (isolation, incl. mgmt)
#   mgmt → test                : allow (return traffic stateful; test→mgmt blocked)

set -euo pipefail

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh

# ── Defaults ─────────────────────────────────────────────────────────
readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"
readonly INTERFACES="/etc/network/interfaces"
readonly MARK_BEGIN="# >>> TAPPaaS test-network (issue #225) >>>"
readonly MARK_END="# <<< TAPPaaS test-network (issue #225) <<<"

BRIDGE="testbr"
SUBNET="172.17.3.1/24"
MGMT_NET="10.0.0.0/24"
PORT=""
VMID=""
ACTION="create"
ASSUME_YES=0
CHECK_MODE=0
FIREWALL_FQDN="firewall.mgmt.internal"

usage() {
    cat <<EOF
Usage: test-network.sh [options]

Create (default) or tear down an isolated test network on a spare physical
port of the node running the firewall VM.

Options:
  --delete            Tear the test network down (reverse order).
  --status            Show current test-network state and exit.
  --port PORT         Physical NIC to use (e.g. enp3s0). Prompted if omitted.
  --bridge NAME       Bridge name on the node (default: ${BRIDGE}).
  --subnet CIDR       Test-net gateway + prefix (default: ${SUBNET}).
  --vmid ID           Firewall VM id (default: read from firewall.json).
  --check-mode        Dry run — report planned changes, make none.
  --yes               Do not prompt for confirmation on destructive steps.
  --debug             Verbose logging.
  -h, --help          This help.
EOF
}

# ── Argument parsing ─────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --delete)     ACTION="delete" ;;
        --status)     ACTION="status" ;;
        --port)       PORT="${2:?--port needs a value}"; shift ;;
        --bridge)     BRIDGE="${2:?--bridge needs a value}"; shift ;;
        --subnet)     SUBNET="${2:?--subnet needs a value}"; shift ;;
        --vmid)       VMID="${2:?--vmid needs a value}"; shift ;;
        --check-mode) CHECK_MODE=1 ;;
        --yes|-y)     ASSUME_YES=1 ;;
        --debug)      OPT_DEBUG=1 ;;
        -h|--help)    usage; exit 0 ;;
        *)            die "Unknown argument: $1 (see --help)" ;;
    esac
    shift
done
debug "Action=${ACTION} bridge=${BRIDGE} subnet=${SUBNET} debug=${OPT_DEBUG}"

# ── Validate operator-supplied input ─────────────────────────────────
# These values are interpolated into `ssh root@node "bash -s"` heredocs and
# `qm set` commands. Validate them against strict allowlists so a stray
# character cannot turn into arbitrary code execution as root on the node.
[[ "${BRIDGE}" =~ ^[a-zA-Z0-9._-]+$ ]] \
    || die "Invalid --bridge '${BRIDGE}' (allowed: letters, digits, . _ -)"
[[ -z "${PORT}" || "${PORT}" =~ ^[a-zA-Z0-9._-]+$ ]] \
    || die "Invalid --port '${PORT}' (allowed: letters, digits, . _ -)"
[[ "${VMID}" =~ ^[0-9]*$ ]] \
    || die "Invalid --vmid '${VMID}' (digits only)"
[[ "${SUBNET}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] \
    || die "Invalid --subnet '${SUBNET}' (expected CIDR, e.g. 172.17.3.1/24)"

# Optional --check-mode flag passed through to the controller, as an array so
# it expands to nothing when unset (avoids unquoted word-splitting hacks).
CHECK_FLAG=()
[[ "${CHECK_MODE}" -eq 1 ]] && CHECK_FLAG=(--check-mode)

# ── Cleanup trap ─────────────────────────────────────────────────────
TMP_FILES=()
cleanup() {
    local f
    for f in "${TMP_FILES[@]:-}"; do [[ -n "$f" && -f "$f" ]] && rm -f "$f"; done
}
trap cleanup EXIT INT TERM

# ── Helpers ──────────────────────────────────────────────────────────

confirm() {
    # confirm "message" — returns 0 to proceed, honouring --yes.
    [[ "${ASSUME_YES}" -eq 1 ]] && return 0
    local reply
    read -r -p "$1 [y/N]: " reply
    [[ "${reply,,}" == "y" ]]
}

# Resolve the OPNsense-side CLI (installed wrapper, else module fallback).
resolve_controller() {
    if command -v test-network-manager >/dev/null 2>&1; then
        echo "test-network-manager"
    elif python3 -c "import opnsense_controller.test_network_cli" >/dev/null 2>&1; then
        echo "python3 -m opnsense_controller.test_network_cli"
    else
        die "test-network-manager not found. Rebuild the opnsense-controller package (it exposes the new entry point) and retry."
    fi
}

# Locate the cluster node currently hosting the firewall VM.
resolve_firewall_node() {
    local primary
    primary=$(get_primary_node_fqdn 2>/dev/null || echo "tappaas1.mgmt.internal")
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        root@"${primary}" \
        "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
         | jq -r --arg vmid \"${VMID}\" '.[] | select(.vmid==(\$vmid|tonumber)) | .node'" \
        2>/dev/null | head -1
}

# Print vacant physical ports on the firewall node, one "name<TAB>desc" per line.
# Vacant = physical NIC, not enslaved to a bridge, not referenced as a
# bridge-port in /etc/network/interfaces.
discover_ports() {
    local node_fqdn="$1"
    ssh -o BatchMode=yes root@"${node_fqdn}" 'bash -s' <<'REMOTE'
set -euo pipefail
used="$(grep -hoE 'bridge-ports[[:space:]]+.*' /etc/network/interfaces 2>/dev/null | tr -s ' ' | cut -d' ' -f2- || true)"
for path in /sys/class/net/*; do
    n="${path##*/}"
    [[ -e "${path}/device" ]] || continue            # physical only
    master="$(ip -o link show "$n" 2>/dev/null | grep -oE 'master [^ ]+' | awk '{print $2}')"
    [[ -n "$master" ]] && continue                   # already enslaved
    case " $used " in *" $n "*) continue;; esac      # listed as a bridge-port
    mac="$(cat "$path/address" 2>/dev/null || echo '??')"
    state="$(cat "$path/operstate" 2>/dev/null || echo '?')"
    speed="$(cat "$path/speed" 2>/dev/null || echo '')"
    if [[ -n "$speed" && "$speed" != "-1" ]]; then speed="${speed}Mb/s"; else speed="link-down"; fi
    printf '%s\tmac=%s %s/%s\n' "$n" "$mac" "$state" "$speed"
done
REMOTE
}

# Next free netN index on the firewall VM (over ssh to its node).
next_free_net_index() {
    local node_fqdn="$1" i
    for i in $(seq 0 15); do
        if ! ssh -o BatchMode=yes root@"${node_fqdn}" "qm config ${VMID}" 2>/dev/null \
                | grep -q "^net${i}:"; then
            echo "$i"; return 0
        fi
    done
    return 1
}

# netN index whose NIC is bridged to $BRIDGE on the firewall VM (for teardown).
net_index_for_bridge() {
    local node_fqdn="$1"
    ssh -o BatchMode=yes root@"${node_fqdn}" "qm config ${VMID}" 2>/dev/null \
        | awk -F: -v b="bridge=${BRIDGE}" '/^net[0-9]+:/ && index($0,b){sub(/^net/,"",$1); print $1; exit}'
}

# ── Resolve firewall VM id + node ────────────────────────────────────
if [[ -z "${VMID}" ]]; then
    [[ -f "${FIREWALL_JSON}" ]] || die "firewall.json not found at ${FIREWALL_JSON}; pass --vmid"
    VMID=$(jq -r '.vmid // empty' "${FIREWALL_JSON}")
fi
[[ -n "${VMID}" ]] || die "Could not determine firewall VM id (use --vmid)"

NODE=$(resolve_firewall_node)
[[ -n "${NODE}" ]] || die "Could not locate firewall VM ${VMID} on any cluster node"
NODE_FQDN="${NODE}.mgmt.internal"
info "Firewall VM ${BL}${VMID}${CL} runs on ${BL}${NODE}${CL}"

CONTROLLER=$(resolve_controller)

# =====================================================================
# STATUS
# =====================================================================
if [[ "${ACTION}" == "status" ]]; then
    NIDX=$(net_index_for_bridge "${NODE_FQDN}" || true)
    if [[ -n "${NIDX}" ]]; then
        info "Test bridge ${BL}${BRIDGE}${CL} attached to firewall as net${NIDX} (device vtnet${NIDX})"
        # shellcheck disable=SC2086
        ${CONTROLLER} status --device "vtnet${NIDX}" --no-ssl-verify --firewall "${FIREWALL_FQDN}"
    else
        info "No test-network NIC (bridge ${BRIDGE}) attached to firewall VM ${VMID}"
    fi
    exit 0
fi

# =====================================================================
# DELETE  (reverse order: OPNsense → VM NIC → node bridge)
# =====================================================================
if [[ "${ACTION}" == "delete" ]]; then
    NIDX=$(net_index_for_bridge "${NODE_FQDN}" || true)
    if [[ -z "${NIDX}" ]]; then
        warn "No firewall NIC bridged to ${BRIDGE}; will still clean node bridge if present."
    fi

    if [[ "${CHECK_MODE}" -eq 0 ]]; then
        confirm "Tear down test network (bridge ${BRIDGE}, firewall net${NIDX:-?})?" \
            || { info "Aborted."; exit 0; }
    fi

    # 1. OPNsense teardown
    if [[ -n "${NIDX}" ]]; then
        info "Removing OPNsense interface/DHCP/rules for vtnet${NIDX}"
        # shellcheck disable=SC2086
        ${CONTROLLER} delete --device "vtnet${NIDX}" --no-ssl-verify \
            --firewall "${FIREWALL_FQDN}" "${CHECK_FLAG[@]}"
    fi

    # 2. Detach the NIC from the firewall VM
    if [[ -n "${NIDX}" && "${CHECK_MODE}" -eq 0 ]]; then
        info "Detaching net${NIDX} from firewall VM ${VMID}"
        ssh -o BatchMode=yes root@"${NODE_FQDN}" "qm set ${VMID} --delete net${NIDX}" >/dev/null \
            || warn "qm set --delete net${NIDX} returned non-zero"
    fi

    # 3. Remove the node bridge stanza
    info "Removing bridge ${BRIDGE} from ${NODE_FQDN}:${INTERFACES}"
    if [[ "${CHECK_MODE}" -eq 0 ]]; then
        # MARK_*/INTERFACES are intentionally expanded client-side; the date
        # subshell is escaped to run on the node.
        # shellcheck disable=SC2087
        ssh -o BatchMode=yes root@"${NODE_FQDN}" "bash -s" <<REMOTE || warn "Bridge removal returned non-zero"
set -euo pipefail
if grep -qF "${MARK_BEGIN}" "${INTERFACES}"; then
    cp -a "${INTERFACES}" "${INTERFACES}.tappaas.\$(date +%Y%m%d-%H%M%S).bak"
    sed -i "/^${MARK_BEGIN}\$/,/^${MARK_END}\$/d" "${INTERFACES}"
    ifreload -a 2>/dev/null || systemctl restart networking
fi
REMOTE
    fi

    info "${GN}✓${CL} Test network removed."
    exit 0
fi

# =====================================================================
# CREATE
# =====================================================================

# 1. Pick a physical port
if [[ -z "${PORT}" ]]; then
    info "Discovering vacant physical ports on ${NODE}..."
    mapfile -t AVAIL < <(discover_ports "${NODE_FQDN}")
    [[ "${#AVAIL[@]}" -gt 0 ]] || die "No vacant physical ports found on ${NODE}."
    echo "Vacant ports on ${NODE}:"
    i=1
    for line in "${AVAIL[@]}"; do
        printf "  %d) %s\n" "$i" "$(echo "$line" | tr '\t' ' ')"
        i=$((i + 1))
    done
    read -r -p "Select a port for the test network [1-${#AVAIL[@]}]: " sel
    [[ "${sel}" =~ ^[0-9]+$ && "${sel}" -ge 1 && "${sel}" -le "${#AVAIL[@]}" ]] \
        || die "Invalid selection."
    PORT="$(echo "${AVAIL[$((sel - 1))]}" | cut -f1)"
fi
info "Using physical port ${BL}${PORT}${CL} for test network ${BL}${SUBNET}${CL}"

if [[ "${CHECK_MODE}" -eq 0 ]]; then
    confirm "Create test network on ${NODE}:${PORT} via bridge ${BRIDGE}?" \
        || { info "Aborted."; exit 0; }
fi

# Create is not transactional: once the bridge/NIC exist, a later failure
# (e.g. OPNsense unreachable) leaves partial state. Surface the recovery path.
partial_create_hint() {
    error "Create failed partway through — node bridge and/or firewall NIC may exist."
    error "Clean up with:  test-network.sh --delete --bridge ${BRIDGE}"
}
trap partial_create_hint ERR

# 2. Create the node bridge (idempotent, persisted, backed up)
info "Creating bridge ${BRIDGE} (port ${PORT}) on ${NODE_FQDN}"
if [[ "${CHECK_MODE}" -eq 0 ]]; then
    # PORT/BRIDGE/MARK_*/INTERFACES expand client-side; date subshell is
    # escaped to run on the node.
    # shellcheck disable=SC2087
    ssh -o BatchMode=yes root@"${NODE_FQDN}" "bash -s" <<REMOTE || die "Bridge creation failed"
set -euo pipefail
[[ -e "/sys/class/net/${PORT}/device" ]] || { echo "Port ${PORT} is not a physical NIC" >&2; exit 1; }
# Refuse a port that is in use — guards against enslaving the node's mgmt NIC
# and locking it out (no auto-rollback timer here, unlike config-network.sh).
if ip -o link show "${PORT}" 2>/dev/null | grep -qoE 'master [^ ]+'; then
    echo "Port ${PORT} is already enslaved to a bridge/bond — refusing" >&2; exit 1
fi
if ip -o -4 addr show "${PORT}" 2>/dev/null | grep -q 'inet '; then
    echo "Port ${PORT} has an IPv4 address configured — refusing" >&2; exit 1
fi
if ip route show default 2>/dev/null | grep -qE "dev ${PORT}( |\$)"; then
    echo "Port ${PORT} carries the default route — refusing" >&2; exit 1
fi
if ! grep -qF "${MARK_BEGIN}" "${INTERFACES}"; then
    cp -a "${INTERFACES}" "${INTERFACES}.tappaas.\$(date +%Y%m%d-%H%M%S).bak"
    {
        echo ""
        echo "${MARK_BEGIN}"
        echo "iface ${PORT} inet manual"
        echo ""
        echo "auto ${BRIDGE}"
        echo "iface ${BRIDGE} inet manual"
        printf '\tbridge-ports %s\n' "${PORT}"
        printf '\tbridge-stp off\n'
        printf '\tbridge-fd 0\n'
        echo "${MARK_END}"
    } >> "${INTERFACES}"
    ifreload -a 2>/dev/null || systemctl restart networking
else
    echo "test-network bridge stanza already present — leaving as-is"
fi
REMOTE
fi

# 3. Attach the bridge to the firewall VM as a new virtio NIC
NIDX=$(net_index_for_bridge "${NODE_FQDN}" || true)
if [[ -z "${NIDX}" ]]; then
    NIDX=$(next_free_net_index "${NODE_FQDN}") || die "No free netN slot on firewall VM"
    info "Attaching bridge ${BRIDGE} to firewall VM ${VMID} as net${NIDX} (→ vtnet${NIDX})"
    if [[ "${CHECK_MODE}" -eq 0 ]]; then
        ssh -o BatchMode=yes root@"${NODE_FQDN}" \
            "qm set ${VMID} --net${NIDX} virtio,bridge=${BRIDGE}" >/dev/null \
            || die "qm set --net${NIDX} failed"
    fi
else
    info "Firewall already has net${NIDX} on bridge ${BRIDGE} (→ vtnet${NIDX})"
fi
DEVICE="vtnet${NIDX}"

# 4. OPNsense: assign interface, DHCP, firewall rules
info "Configuring OPNsense on ${DEVICE} (${SUBNET})"
# shellcheck disable=SC2086
${CONTROLLER} create --device "${DEVICE}" --cidr "${SUBNET}" \
    --mgmt-net "${MGMT_NET}" --no-ssl-verify --firewall "${FIREWALL_FQDN}" \
    "${CHECK_FLAG[@]}"

# 5. Regenerate OPNsense auto-rules so DHCP works on the new interface
#    (mirrors firewall/update.sh — /api/firewall/filter/apply does NOT
#    re-render anti-lockout/bootp pass rules for freshly assigned interfaces).
if [[ "${CHECK_MODE}" -eq 0 ]]; then
    info "Reloading OPNsense filter to regenerate auto-rules for ${DEVICE}"
    ssh -o BatchMode=yes root@"${FIREWALL_FQDN}" "configctl filter reload" >/dev/null 2>&1 \
        || warn "configctl filter reload returned non-zero (continuing)"
fi

trap - ERR   # past the point where partial state can be created

info "${GN}✓${CL} Test network ${BL}${SUBNET}${CL} ready on ${NODE}:${PORT} (firewall ${DEVICE})."
info "  Tear down with: test-network.sh --delete --bridge ${BRIDGE}"
