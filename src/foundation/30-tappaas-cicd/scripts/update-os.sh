#!/usr/bin/env bash
#
# TAPPaaS OS Update Script
#
# Updates a VM's operating system based on its type (NixOS or Debian/Ubuntu).
# Handles IP detection, SSH setup, and OS-specific update procedures.
#
# Usage: update-os.sh <vmname> <vmid> <node>
#
# Arguments:
#   vmname - Name of the VM
#   vmid   - Proxmox VM ID
#   node   - Proxmox node name (e.g., tappaas1)
#
# For NixOS VMs, expects ./<vmname>.nix to exist in the current directory.
#
# Examples:
#   update-os.sh myvm 610 tappaas1   # Looks for ./myvm.nix if NixOS
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
readonly MGMT="mgmt"

# Color definitions
readonly YW=$'\033[33m'
readonly RD=$'\033[01;31m'
readonly GN=$'\033[1;92m'
readonly DGN=$'\033[32m'
readonly BL=$'\033[36m'
readonly CL=$'\033[m'

info() {
    echo -e "${DGN}$*${CL}"
}

warn() {
    echo -e "${YW}[WARN]${CL} $*"
}

error() {
    echo -e "${RD}[ERROR]${CL} $*" >&2
}

die() {
    error "$@"
    exit 1
}

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} <vmname> <vmid> <node>

Update a VM's operating system based on its type (NixOS or Debian/Ubuntu).

Arguments:
    vmname  Name of the VM
    vmid    Proxmox VM ID
    node    Proxmox node name (e.g., tappaas1)

Examples:
    ${SCRIPT_NAME} myvm 610 tappaas1

The script will:
  - Detect the VM's IP address (via guest agent or DHCP leases)
  - Detect the OS type (NixOS or Debian/Ubuntu)
  - For NixOS: Run nixos-rebuild using ./<vmname>.nix and reboot
  - For Debian/Ubuntu: Run apt update/upgrade
  - Fix DHCP hostname registration
EOF
}

# Get VM IP address via Proxmox guest agent
get_vm_ip_guest_agent() {
    local node="$1"
    local vmid="$2"

    ssh "root@${node}.${MGMT}.internal" "qm guest cmd ${vmid} network-get-interfaces" 2>/dev/null | \
        jq -r '.[] | select(.name | test("^lo$") | not) | ."ip-addresses"[]? | select(."ip-address-type" == "ipv4") | ."ip-address"' 2>/dev/null | \
        head -1
}

# Get VM IP address via DHCP leases on firewall
get_vm_ip_dhcp() {
    local node="$1"
    local vmid="$2"

    # Get the VM's MAC address
    local vm_mac
    vm_mac=$(ssh "root@${node}.${MGMT}.internal" "qm config ${vmid} | grep 'net0' | sed -n 's/.*virtio=\([^,]*\).*/\\1/p'" 2>/dev/null)

    if [[ -z "${vm_mac}" ]]; then
        return 1
    fi

    # Query DHCP leases on firewall
    local mac_lower
    mac_lower=$(echo "${vm_mac}" | tr '[:upper:]' '[:lower:]')
    ssh "root@firewall.${MGMT}.internal" "grep -i '${mac_lower}' /var/db/dnsmasq.leases" 2>/dev/null | awk '{print $3}'
}

# Wait for VM to get IP address using multiple methods
wait_for_vm_ip() {
    local node="$1"
    local vmid="$2"
    local max_attempts="${3:-30}"
    local vm_ip=""

    info "Waiting for VM to get IP address..." >&2

    for ((i=1; i<=max_attempts; i++)); do
        # Try guest agent first
        vm_ip=$(get_vm_ip_guest_agent "${node}" "${vmid}")

        # Fall back to DHCP leases if guest agent doesn't work
        if [[ -z "${vm_ip}" ]]; then
            vm_ip=$(get_vm_ip_dhcp "${node}" "${vmid}")
        fi

        if [[ -n "${vm_ip}" ]]; then
            echo "${vm_ip}"
            return 0
        fi

        echo "  Attempt ${i}/${max_attempts}: waiting for IP address..." >&2
        sleep 10
    done

    return 1
}

# Update SSH known_hosts for an IP
update_ssh_known_hosts() {
    local ip="$1"

    ssh-keygen -R "${ip}" 2>/dev/null || true
    ssh-keyscan -H "${ip}" >> ~/.ssh/known_hosts 2>/dev/null
}

# Wait for SSH to become available (cloud-init may still be setting up keys)
wait_for_ssh() {
    local ip="$1"
    local max_wait="${2:-120}"
    local waited=0

    info "Waiting for SSH to become available on ${ip}..."
    while ! ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new -o BatchMode=yes "tappaas@${ip}" "exit 0" &>/dev/null; do
        sleep 3
        waited=$((waited + 3))
        if [[ $waited -ge $max_wait ]]; then
            warn "SSH not available on ${ip} after ${max_wait}s"
            return 1
        fi
    done
    info "SSH is available on ${ip}"
    return 0
}

# Detect OS type on the VM
detect_os_type() {
    local ip="$1"

    # Try to detect NixOS
    if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "tappaas@${ip}" "test -f /etc/NIXOS" 2>/dev/null; then
        echo "nixos"
        return 0
    fi

    # Try to detect Debian/Ubuntu
    if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "tappaas@${ip}" "test -f /etc/debian_version" 2>/dev/null; then
        echo "debian"
        return 0
    fi

    echo "unknown"
}

# Wait for cloud-init to finish (Debian/Ubuntu)
wait_for_cloud_init() {
    local ip="$1"

    info "Waiting for cloud-init to finish..."
    ssh "tappaas@${ip}" "cloud-init status --wait" 2>/dev/null || true
}

# Update NixOS VM
update_nixos() {
    local vmname="$1"
    local vmid="$2"
    local node="$3"
    local vm_ip="$4"

    # Default to ./<vmname>.nix in current directory
    local nix_config="./${vmname}.nix"

    if [[ ! -f "${nix_config}" ]]; then
        die "NixOS configuration file not found: ${nix_config}"
    fi

    info "Using NixOS config: ${nix_config}"
    info "Running nixos-rebuild..."
    nixos-rebuild --target-host "tappaas@${vm_ip}" --use-remote-sudo switch -I "nixos-config=${nix_config}"

    info "Rebooting VM to apply configuration..."
    ssh "root@${node}.${MGMT}.internal" "qm reboot ${vmid}"

    info "Waiting 60 seconds for VM to restart..."
    sleep 60
}

# Update Debian/Ubuntu VM
update_debian() {
    local vm_ip="$1"

    wait_for_cloud_init "${vm_ip}"

    info "Updating package lists..."
    ssh "tappaas@${vm_ip}" "sudo apt-get update"

    info "Upgrading packages..."
    ssh "tappaas@${vm_ip}" "sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y"

    info "Installing/updating QEMU guest agent..."
    ssh "tappaas@${vm_ip}" "sudo apt-get install -y qemu-guest-agent && sudo systemctl enable --now qemu-guest-agent"
}

# Fix DHCP hostname registration
fix_dhcp_hostname() {
    local vmname="$1"
    local vm_ip="$2"

    info "Fixing DHCP hostname registration..."

    local eth_connection
    local eth_device

    eth_connection=$(ssh "tappaas@${vm_ip}" "nmcli -t -f NAME,TYPE connection show 2>/dev/null" | grep ethernet | cut -d: -f1 | head -1) || true
    eth_device=$(ssh "tappaas@${vm_ip}" "nmcli -t -f DEVICE,TYPE device status 2>/dev/null" | grep ethernet | cut -d: -f1 | head -1) || true

    if [[ -n "${eth_connection}" ]] && [[ -n "${eth_device}" ]]; then
        info "  Ethernet connection: ${eth_connection}"
        info "  Ethernet device: ${eth_device}"
        ssh "tappaas@${vm_ip}" "sudo nmcli connection modify '${eth_connection}' ipv4.dhcp-hostname \"\$(hostname)\"" || true
        ssh "tappaas@${vm_ip}" "sudo nmcli device reapply '${eth_device}'" || true
        info "  DHCP hostname updated to: ${vmname}"
    else
        warn "Could not find ethernet connection/device for DHCP fix"
    fi
}

# Main function
main() {
    # Check for help flag
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    # Validate arguments
    if [[ $# -lt 3 ]]; then
        error "Missing required arguments"
        usage
        exit 1
    fi

    local vmname="$1"
    local vmid="$2"
    local node="$3"

    info "=== TAPPaaS OS Update ==="
    info "VM: ${vmname} (VMID: ${vmid}) on ${node}"

    # Wait for VM to get IP address
    local vm_ip
    vm_ip=$(wait_for_vm_ip "${node}" "${vmid}" 30) || die "Could not get VM IP address after 5 minutes"
    info "VM IP address: ${vm_ip}"

    # Wait for SSH to become available (cloud-init may still be setting up keys)
    wait_for_ssh "${vm_ip}" 120 || die "SSH not available on ${vm_ip}"

    # Update SSH known_hosts
    update_ssh_known_hosts "${vm_ip}"

    # Detect OS type
    info "Detecting OS type..."
    local os_type
    os_type=$(detect_os_type "${vm_ip}")
    info "Detected OS: ${BL}${os_type}${CL}"

    # Perform OS-specific update
    case "${os_type}" in
        nixos)
            update_nixos "${vmname}" "${vmid}" "${node}" "${vm_ip}"
            ;;
        debian)
            update_debian "${vm_ip}"
            ;;
        *)
            die "Unknown or unsupported OS type: ${os_type}"
            ;;
    esac

    # Wait for VM to come back up after updates (especially for NixOS reboot)
    if [[ "${os_type}" == "nixos" ]]; then
        info "Waiting for VM to come back up..."
        vm_ip=$(wait_for_vm_ip "${node}" "${vmid}" 12) || die "Could not get VM IP address after reboot"
        info "VM IP address after reboot: ${vm_ip}"
        update_ssh_known_hosts "${vm_ip}"
    fi

    # Fix DHCP hostname registration
    fix_dhcp_hostname "${vmname}" "${vm_ip}"

    echo ""
    info "${GN}=== OS update completed successfully ===${CL}"
    info "VM: ${vmname} (${vm_ip})"
}

main "$@"
