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
    # Tee the live output to a log so the dots stay terse but the REAL error is
    # recoverable on failure. Previously the output was discarded entirely, so a
    # failed nixos-rebuild surfaced only as a generic exit code — the actual
    # stderr that identifies which step exploded was lost (issue #309 ask 1).
    local _log
    _log="$(mktemp /tmp/tappaas-update-os.XXXXXX.log)"
    set +e
    "$@" 2>&1 | tee "${_log}" | while IFS= read -r _; do printf "."; done
    rc=${PIPESTATUS[0]}
    set -e
    echo ""
    if [[ "${rc}" -ne 0 ]]; then
        error "${desc} failed (exit ${rc}) — last 20 lines of output:"
        tail -n 20 "${_log}" | sed 's/^/    /' >&2
        warn "Full output of the failed step saved to ${_log}"
        die "${desc} failed (exit ${rc}); see ${_log}"
    fi
    rm -f "${_log}"
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

# Wait until the VM is actually ready for privileged provisioning: cloud-init
# has finished AND passwordless sudo works for the tappaas user. A VM (especially
# the first in a freshly-activated zone) can accept SSH on port 22 before
# cloud-init has finished laying down /etc/nixos, the tappaas account and its
# NOPASSWD sudoers entry — running nixos-rebuild against that half-set-up target
# is exactly the flaky-first-attempt failure in issue #309. Best-effort: warns
# and proceeds if the deadline passes, so a quirk here never hard-blocks install.
wait_for_provisioning() {
    local ip="$1"
    local max="${2:-150}"
    local waited=0

    info "Waiting for cloud-init to finish on ${ip}..."
    ssh -o BatchMode=yes "tappaas@${ip}" "cloud-init status --wait" >/dev/null 2>&1 || true

    info "Waiting for passwordless sudo on ${ip}..."
    while ! ssh -o BatchMode=yes "tappaas@${ip}" "sudo -n true" 2>/dev/null; do
        sleep 3
        waited=$((waited + 3))
        if [[ ${waited} -ge ${max} ]]; then
            warn "passwordless sudo not ready on ${ip} after ${max}s — proceeding anyway"
            return 0
        fi
    done
    info "  ${GN}✓${CL} cloud-init done and passwordless sudo ready"
}

# Update NixOS VM
update_nixos() {
    local vmname="$1"
    local vmid="$2"
    local node="$3"
    local vm_ip="$4"

    # Gate on cloud-init done + passwordless sudo before any privileged step
    # (scp install, nixos-generate-config, nixos-rebuild). Stops the flaky
    # first-attempt failure where SSH is up but provisioning isn't (#309 ask 2).
    wait_for_provisioning "${vm_ip}"

    # Resolve NixOS config. For plain deploys: ./<vmname>.nix.
    # For variant deploys (<vmname> = <source>-<variant>): the source module
    # only ships <source>.nix. When <vmname>.nix is absent, read the "variant"
    # field from the installed config and fall back to <source>.nix. Fixes #286.
    local nix_config="./${vmname}.nix"
    local _source_vmname="${vmname}"

    if [[ ! -f "${nix_config}" ]]; then
        local _cfg="${CONFIG_DIR}/${vmname}.json"
        if [[ -f "${_cfg}" ]]; then
            local _variant
            _variant=$(jq -r '.variant // empty' "${_cfg}" 2>/dev/null)
            if [[ -n "${_variant}" ]]; then
                _source_vmname="${vmname%-"${_variant}"}"
                local _fallback_nix="./${_source_vmname}.nix"
                if [[ -f "${_fallback_nix}" ]]; then
                    info "Variant '${_variant}': using ${_fallback_nix} for ${vmname}"
                    nix_config="${_fallback_nix}"
                fi
            fi
        fi
    fi

    if [[ ! -f "${nix_config}" ]]; then
        die "NixOS configuration file not found: ${nix_config} (tried variant fallback)"
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

    # Copy sibling .nix helpers the main .nix imports via pkgs.callPackage.
    # Skips the already-copied main file. Failure is non-fatal. Fixes #286.
    for _sib in ./*.nix; do
        [[ -f "${_sib}" ]] || continue
        local _sib_base
        _sib_base="$(basename "${_sib}")"
        [[ "${_sib_base}" == "${nix_basename}" ]] && continue
        local _sib_remote="/etc/nixos/${_sib_base}"
        scp -o StrictHostKeyChecking=accept-new -o BatchMode=yes "${_sib}" "tappaas@${vm_ip}:/tmp/${_sib_base}" \
            || { warn "failed to scp sibling ${_sib} — continuing"; continue; }
        ssh -o BatchMode=yes "tappaas@${vm_ip}" "sudo install -m 0644 /tmp/${_sib_base} ${_sib_remote} && rm -f /tmp/${_sib_base}" \
            || warn "failed to install sibling ${_sib_remote} — continuing"
    done

    # Copy companion JSON (<source_vmname>.json) to the VM so modules using
    # builtins.readFile ./module.json can evaluate. For variants the installed
    # config (carrying variant-specific values) is normalized to flat format
    # and deployed under the source module's JSON name. Fixes #286.
    local _companion_local="./${_source_vmname}.json"
    local _companion_remote="/etc/nixos/${_source_vmname}.json"
    if [[ -f "${_companion_local}" ]]; then
        local _flat_tmp
        _flat_tmp=$(mktemp)
        local _installed_cfg="${CONFIG_DIR}/${vmname}.json"
        if [[ -f "${_installed_cfg}" ]] && declare -F normalize_module_config >/dev/null 2>&1; then
            normalize_module_config < "${_installed_cfg}" > "${_flat_tmp}" \
                || cp "${_companion_local}" "${_flat_tmp}"
        else
            cp "${_companion_local}" "${_flat_tmp}"
        fi
        info "Copying JSON config to ${vm_ip}:${_companion_remote}"
        scp -o StrictHostKeyChecking=accept-new -o BatchMode=yes "${_flat_tmp}" "tappaas@${vm_ip}:/tmp/${_source_vmname}.json" \
            || { rm -f "${_flat_tmp}"; die "failed to scp JSON config to ${vm_ip}"; }
        ssh -o BatchMode=yes "tappaas@${vm_ip}" "sudo install -m 0644 /tmp/${_source_vmname}.json ${_companion_remote} && rm -f /tmp/${_source_vmname}.json" \
            || { rm -f "${_flat_tmp}"; die "failed to install JSON config on ${vm_ip}"; }
        rm -f "${_flat_tmp}"
    fi

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
        if [[ "$rc" -eq 0 ]]; then
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

    # nixos-rebuild switch already activated the new generation; the reboot
    # applies kernel/bootloader changes. Gated by tappaas.automaticReboot
    # (issue #275) — covers the identity VM and any other NixOS guest. When
    # false the operator reboots manually under supervision.
    if automatic_reboot_enabled; then
        info "Rebooting VM to apply configuration..."
        ssh "root@${node}.${MGMT}.internal" "qm reboot ${vmid}"

        info "Waiting 60 seconds for VM to restart..."
        sleep 60
    else
        warn "automaticReboot=false — skipping reboot of VM ${vmid} (${vmname})."
        warn "  The new NixOS generation is active, but a reboot is needed to apply kernel/bootloader changes."
        warn "  Reboot manually under supervision: ssh root@${node}.${MGMT}.internal 'qm reboot ${vmid}'"
    fi
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

        # Resolve nmcli's absolute path on the target (NixOS:
        # /run/current-system/sw/bin, Debian: /usr/bin) so the detached
        # systemd-run unit below — which runs with a minimal PATH — can find it.
        local nmcli_path
        nmcli_path=$(ssh "tappaas@${vm_ip}" "command -v nmcli" 2>/dev/null) || nmcli_path=nmcli

        # 1. Advertise the hostname. NM sends the *static* hostname by default;
        #    setting ipv4.dhcp-hostname explicitly guarantees option-12 is sent
        #    even when the static hostname is empty (e.g. NixOS hostName="").
        ssh "tappaas@${vm_ip}" "sudo ${nmcli_path} connection modify '${eth_connection}' ipv4.dhcp-hostname \"\$(hostname)\"" || true

        # 2. Force a FULL DHCP re-acquire. A renew / 'nmcli device reapply' does
        #    NOT refresh an existing lease's hostname on NM 1.52 (verified on the
        #    live cluster) — only a disconnect/connect does. Run it DETACHED via
        #    systemd-run: the disconnect drops the link, which would otherwise
        #    kill this SSH session before 'connect' runs and strand the VM.
        ssh "tappaas@${vm_ip}" "sudo systemd-run --collect --quiet /bin/sh -c '${nmcli_path} device disconnect ${eth_device}; sleep 2; ${nmcli_path} device connect ${eth_device}'" || true
        info "  DHCP hostname updated to: ${vmname} (re-acquire scheduled)"
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
