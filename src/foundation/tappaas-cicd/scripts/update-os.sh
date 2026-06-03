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

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

# Run a command quietly (progress dots in place of its output) while preserving
# its REAL exit code, and die on failure. A bare `cmd 2>&1 | while read; do
# printf .; done` pipeline reports the while-loop's exit status (always 0), so
# a failure of <cmd> is silently swallowed — which let a failed nixos-rebuild
# look like success (issue #201). PIPESTATUS[0] recovers the true code; `set
# +e` keeps the pipeline from aborting before we can read it.
#   run_quiet <description> <command> [args...]
run_quiet() {
    local desc="$1" rc
    shift
    set +e
    "$@" 2>&1 | while IFS= read -r _; do printf "."; done
    rc=${PIPESTATUS[0]}
    set -e
    echo ""
    [[ "${rc}" -eq 0 ]] || die "${desc} failed (exit ${rc})"
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
    # Best-effort: if the VM's sshd is mid-restart, ssh-keyscan returns non-zero
    # and the next wait_for_ssh/rebuild attempt will retry. Don't let a transient
    # failure here trip set -e and abort the retry loop.
    ssh-keyscan -H "${ip}" >> ~/.ssh/known_hosts 2>/dev/null || true
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
    info "Running nixos-rebuild ON the target VM (not --target-host)..."
    # Build LOCALLY on the target VM so the module's
    # `imports = [ /etc/nixos/hardware-configuration.nix ]` resolves to the
    # VM's OWN hw-config (right disk UUIDs / boot device), not the cicd's.
    # The previous --target-host path built locally on cicd → wrong hw-config
    # → activation broke sshd/qemu-agent on the target every time. See the
    # automated-install-state memory note ("Latent issue NOT yet fixed").
    #
    # Mechanics: scp the .nix into /etc/nixos/<vmname>.nix on the VM, then
    # ssh in and run `nixos-rebuild switch` locally. nixos-rebuild on the VM
    # uses its own nixpkgs channel + can pull from cache.nixos.org via the
    # firewall — no closure-copying over the slow ssh path.
    local nix_basename remote_nix_path
    nix_basename="$(basename "${nix_config}")"
    remote_nix_path="/etc/nixos/${nix_basename}"

    info "Copying ${nix_config} to ${vm_ip}:${remote_nix_path}"
    scp -o StrictHostKeyChecking=accept-new -o BatchMode=yes "${nix_config}" "tappaas@${vm_ip}:/tmp/${nix_basename}" \
        || die "failed to scp ${nix_config} to ${vm_ip}"
    ssh -o BatchMode=yes "tappaas@${vm_ip}" "sudo install -m 0644 /tmp/${nix_basename} ${remote_nix_path} && rm -f /tmp/${nix_basename}" \
        || die "failed to install ${remote_nix_path} on ${vm_ip}"

    # The prebuilt NixOS template ships without /etc/nixos/hardware-configuration.nix
    # — generate it on-demand so the module's `imports = [ /etc/nixos/hardware-configuration.nix ]`
    # resolves on the FIRST rebuild. Idempotent: install1.sh follows the same
    # pattern for tappaas-cicd; we extend the convention to every module install.
    info "Ensuring /etc/nixos/hardware-configuration.nix exists on ${vm_ip}"
    ssh -o BatchMode=yes "tappaas@${vm_ip}" '
        test -f /etc/nixos/hardware-configuration.nix && exit 0
        sudo nixos-generate-config --show-hardware-config 2>/dev/null \
          | sudo tee /etc/nixos/hardware-configuration.nix >/dev/null
    ' || die "failed to generate /etc/nixos/hardware-configuration.nix on ${vm_ip}"

    # Reproducible nixpkgs pin: build every module VM against the EXACT nixpkgs
    # revision pinned for the NixOS template (templates/flake.lock), overriding
    # whatever channel the VM happens to carry in its imperative `nix-channel`.
    # This makes module rebuilds deterministic and version-controlled in git, and
    # keeps every TAPPaaS NixOS VM on the same release as the template (currently
    # 25.11) regardless of when the VM was provisioned. -I nixpkgs=<tarball> takes
    # precedence over NIX_PATH, so the VM's channel no longer determines the build.
    local flake_lock="/home/tappaas/TAPPaaS/src/foundation/templates/flake.lock"
    local nixpkgs_arg="" pinned_rev=""
    if [[ -f "${flake_lock}" ]]; then
        pinned_rev="$(jq -r '.nodes.nixpkgs.locked.rev // empty' "${flake_lock}" 2>/dev/null)"
    fi
    if [[ -n "${pinned_rev}" ]]; then
        nixpkgs_arg="-I nixpkgs=https://github.com/NixOS/nixpkgs/archive/${pinned_rev}.tar.gz"
        info "Pinning nixpkgs to template rev ${pinned_rev:0:12} (reproducible — not the VM's channel)"
    else
        warn "Could not read pinned nixpkgs rev from ${flake_lock} — falling back to the VM's nix-channel"
    fi

    # Retry: even with local builds, a freshly-cloned VM can hiccup on its
    # first activation (services restart while sshd reloads, cloud-init
    # finishing, growPartition). The build itself is idempotent (resumable
    # via the nix store), so re-trying after a settle window recovers.
    local attempt rebuilt=0 rc
    for attempt in 1 2 3; do
        rc=0
        # Wrap in a subshell so run_quiet's die() (exit 1) only kills the
        # subshell — set -e in the parent would otherwise terminate before we
        # reach the retry. Capture rc with || so set -e doesn't fire here.
        if [[ "${OPT_DEBUG:-0}" -eq 1 ]]; then
            ( ssh -o BatchMode=yes "tappaas@${vm_ip}" "sudo nixos-rebuild switch ${nixpkgs_arg} -I nixos-config=${remote_nix_path}" ) || rc=$?
        else
            ( run_quiet "nixos-rebuild on ${vm_ip} (attempt ${attempt}/3)" \
                ssh -o BatchMode=yes "tappaas@${vm_ip}" "sudo nixos-rebuild switch ${nixpkgs_arg} -I nixos-config=${remote_nix_path}" ) || rc=$?
        fi
        # Exit code 4 means switch-to-configuration reported service activation
        # failures but the build itself succeeded. This is expected on first
        # deploy — services like nextcloud-setup fail because the application
        # is not yet initialized; install.sh completes setup afterwards.
        if [[ "$rc" -eq 0 || "$rc" -eq 4 ]]; then
            [[ "$rc" -eq 4 ]] && warn "nixos-rebuild: some services failed activation (exit 4) — expected on first deploy, install.sh will complete setup"
            rebuilt=1; break
        fi
        [[ "$attempt" -lt 3 ]] || break
        warn "nixos-rebuild attempt ${attempt} failed (exit ${rc}) — re-syncing host key and waiting for sshd..."
        sleep 15  # let any in-flight reboot settle
        update_ssh_known_hosts "${vm_ip}"
        # Give sshd up to 90 s to come back before attempting the next rebuild.
        wait_for_ssh "${vm_ip}" 90 || warn "ssh still unreachable after 90 s — trying nixos-rebuild anyway"
    done
    [[ "$rebuilt" == "1" ]] || die "nixos-rebuild failed after 3 attempts"

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
    if [[ "${OPT_DEBUG:-0}" -eq 1 ]]; then
        ssh "tappaas@${vm_ip}" "sudo apt-get update" || die "apt-get update failed"
    else
        run_quiet "apt-get update" ssh "tappaas@${vm_ip}" "sudo apt-get update"
    fi

    info "Upgrading packages..."
    if [[ "${OPT_DEBUG:-0}" -eq 1 ]]; then
        ssh "tappaas@${vm_ip}" "sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y" || die "apt-get upgrade failed"
    else
        run_quiet "apt-get upgrade" ssh "tappaas@${vm_ip}" "sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y"
    fi

    info "Installing/updating QEMU guest agent..."
    if [[ "${OPT_DEBUG:-0}" -eq 1 ]]; then
        ssh "tappaas@${vm_ip}" "sudo apt-get install -y qemu-guest-agent && sudo systemctl enable --now qemu-guest-agent" || die "qemu-guest-agent install failed"
    else
        run_quiet "qemu-guest-agent install" ssh "tappaas@${vm_ip}" "sudo apt-get install -y qemu-guest-agent && sudo systemctl enable --now qemu-guest-agent"
    fi
}

# Fix DHCP hostname registration
fix_dhcp_hostname() {
    local vmname="$1"
    local vm_ip="$2"

    info "Fixing DHCP hostname registration..."

    # Method 1: Try NetworkManager (nmcli)
    local eth_connection
    local eth_device

    eth_connection=$(ssh "tappaas@${vm_ip}" "nmcli -t -f NAME,TYPE connection show 2>/dev/null" | grep ethernet | cut -d: -f1 | head -1) || true
    eth_device=$(ssh "tappaas@${vm_ip}" "nmcli -t -f DEVICE,TYPE device status 2>/dev/null" | grep ethernet | cut -d: -f1 | head -1) || true

    if [[ -n "${eth_connection}" ]] && [[ -n "${eth_device}" ]]; then
        info "  Using NetworkManager for DHCP hostname fix"
        info "  Ethernet connection: ${eth_connection}"
        info "  Ethernet device: ${eth_device}"
        ssh "tappaas@${vm_ip}" "sudo nmcli connection modify '${eth_connection}' ipv4.dhcp-hostname \"\$(hostname)\"" || true
        ssh "tappaas@${vm_ip}" "sudo nmcli device reapply '${eth_device}'" || true
        info "  DHCP hostname updated to: ${vmname}"
        return 0
    fi

    # Method 2: Try systemd-networkd (netplan/networkd)
    local networkd_active
    networkd_active=$(ssh "tappaas@${vm_ip}" "systemctl is-active systemd-networkd 2>/dev/null") || true

    if [[ "${networkd_active}" == "active" ]]; then
        info "  Using systemd-networkd for DHCP hostname fix"
        # Find the .network file for the primary ethernet interface
        local network_file
        network_file=$(ssh "tappaas@${vm_ip}" "ls /run/systemd/network/*.network /etc/systemd/network/*.network 2>/dev/null | head -1") || true

        if [[ -n "${network_file}" ]]; then
            local network_basename
            network_basename=$(basename "${network_file}")
            local dropin_dir="/etc/systemd/network/${network_basename}.d"

            info "  Creating drop-in for ${network_basename}"
            ssh "tappaas@${vm_ip}" "sudo mkdir -p '${dropin_dir}' && printf '[DHCPv4]\nSendHostname=yes\nHostname=${vmname}\n' | sudo tee '${dropin_dir}/hostname.conf' >/dev/null" || true
            ssh "tappaas@${vm_ip}" "sudo systemctl restart systemd-networkd" || true
            info "  DHCP hostname updated to: ${vmname}"
            return 0
        fi
    fi

    warn "Could not find ethernet connection/device for DHCP fix"
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

    # Update SSH known_hosts
    update_ssh_known_hosts "${vm_ip}"

    # Wait for SSH to become available (cloud-init may still be setting up keys)
    wait_for_ssh "${vm_ip}" 120 || die "SSH not available on ${vm_ip}"

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
