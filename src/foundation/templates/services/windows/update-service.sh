#!/usr/bin/env bash
#
# TAPPaaS Templates Windows Service - Update (the converge)
#
# The provider-side converge for an already-provisioned Windows VM, invoked by
# both `module modify` and `module reconcile --apply`. Two parts:
#   1. The shared convergent baseline (windows-baseline.sh): hostname/network
#      profile, C: extended to the configured disk, VirtIO guest agent, RDP set
#      to windows.enableRDP, tappaas account. These used to run on INSTALL ONLY
#      (#495), so flipping windows.enableRDP or growing diskSize never took
#      effect on an existing VM.
#   2. Security-only Windows Updates + the reboot/wait flow this script owns.
#      Automatic Windows Update is disabled between runs; this is the sole
#      update path. A Proxmox snapshot is created before rebooting (by
#      update-module.sh) — reconcile deliberately takes no snapshot.
#
# Usage: update-service.sh <module-name>
#

set -euo pipefail

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <module-name>"
    exit 1
fi

MODULE_NAME="$1"

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "$MODULE_NAME")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0="$(get_config_value 'zone0' 'srv')"
VM_HOST="${VMNAME}.${ZONE0}.internal"

# Same ssh/scp options install-service.sh uses against this host — the shared
# baseline steps below rely on both, and a recreated VM presents a new host key.
readonly SSH_OPTS="-o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes"
readonly SCP_OPTS="${SSH_OPTS}"

ENABLE_RDP="$(read_module_config "${VMNAME}" | jq -r '.windows.enableRDP // false')"
readonly ENABLE_RDP

# ── Part 1: the shared convergent baseline ────────────────────────────
_WIN_SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=windows-baseline.sh disable=SC1091
. "${_WIN_SVC_DIR}/windows-baseline.sh"

debug "=== Windows baseline converge: ${VMNAME} (VMID ${VMID}) ==="
debug "RDP: ${ENABLE_RDP}"

# step_windows_update is deliberately NOT in this list: the security-update +
# reboot flow below is this script's own, and is more complete for the update case.
_baseline_failed=()
for _step in hostname_fix disk_extend virtio_agent rdp_setup tappaas_account; do
    if "step_${_step}"; then
        debug "  ✓ ${_step}"
    else
        error "  ✗ ${_step} failed"
        _baseline_failed+=("${_step}")
    fi
done
if [[ ${#_baseline_failed[@]} -gt 0 ]]; then
    error "Windows baseline converge FAILED: ${_baseline_failed[*]}"
    exit 1
fi

# ── Part 2: security-only Windows Updates ─────────────────────────────
debug "=== Windows Security Update: ${VMNAME} (VMID ${VMID}) ==="

debug "  Enabling Windows Update service..."
# shellcheck disable=SC2086
ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "powershell -NoProfile -NonInteractive -Command \"
    Set-Service -Name wuauserv -StartupType Manual
    Start-Service wuauserv
    Write-Output 'Windows Update service started'
\"" || true

debug "  Checking for security updates..."
# shellcheck disable=SC2086
update_result=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "powershell -NoProfile -NonInteractive -Command \"
    \$psWU = Get-Module -ListAvailable -Name PSWindowsUpdate -ErrorAction SilentlyContinue
    if (-not \$psWU) {
        Install-PackageProvider -Name NuGet -Force -Scope AllUsers | Out-Null
        Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers -AllowClobber | Out-Null
    }
    Import-Module PSWindowsUpdate
    \$available = Get-WindowsUpdate -Category 'Security Updates' -IgnoreReboot -ErrorAction SilentlyContinue
    if (-not \$available -or \$available.Count -eq 0) {
        Write-Output 'UPDATES:0|REBOOT:False'
        exit 0
    }
    Write-Output \"Found \$(\$available.Count) security update(s):\"
    foreach (\$u in \$available) { Write-Output \"  - \$(\$u.Title)\" }
    \$installed = Get-WindowsUpdate -Category 'Security Updates' -AcceptAll -Install -IgnoreReboot -ErrorAction Stop
    \$rebootStatus = Get-WURebootStatus -Silent -ErrorAction SilentlyContinue
    \$rebootNeeded = if (\$rebootStatus) { \$rebootStatus.RebootRequired } else { \$false }
    Write-Output \"UPDATES:\$(\$installed.Count)|REBOOT:\$rebootNeeded\"
\"" 2>/dev/null) || true

debug "  ${update_result}"

debug "  Disabling Windows Update service..."
# shellcheck disable=SC2086
ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "powershell -NoProfile -NonInteractive -Command \"
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Set-Service -Name wuauserv -StartupType Disabled
    Write-Output 'Windows Update service disabled'
\"" || true

if [[ "${update_result}" == *"REBOOT:True"* ]]; then
    debug "  Reboot required after security updates — rebooting VM..."
    ssh "root@${NODE}.mgmt.internal" "qm reboot ${VMID}" || true
    debug "  Waiting 120 seconds for VM to restart..."
    sleep 120

    max_wait=300
    waited=0
    debug "  Waiting for SSH to become available on ${VM_HOST}..."
    # shellcheck disable=SC2086
    while ! ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "exit 0" &>/dev/null; do
        sleep 10
        waited=$((waited + 10))
        if [[ ${waited} -ge ${max_wait} ]]; then
            error "  SSH not available on ${VM_HOST} after ${max_wait}s"
            exit 1
        fi
    done
    debug "  VM is back online after reboot"
elif [[ "${update_result}" == *"UPDATES:0"* ]]; then
    debug "  No security updates available — system is up to date"
else
    debug "  Updates installed — no reboot required"
fi

debug "=== Windows Security Update complete ==="
