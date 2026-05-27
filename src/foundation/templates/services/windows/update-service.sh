#!/usr/bin/env bash
#
# TAPPaaS Templates Windows Service - Update
#
# Runs security-only Windows Updates on the VM.
# Automatic Windows Update is disabled between runs; this is the sole update path.
# A Proxmox snapshot is created before rebooting (by update-module.sh).
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

readonly SSH_OPTS="-o ConnectTimeout=30 -o BatchMode=yes -o LogLevel=ERROR"

info "=== Windows Security Update: ${VMNAME} (VMID ${VMID}) ==="

info "  Enabling Windows Update service..."
# shellcheck disable=SC2086
ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "powershell -NoProfile -NonInteractive -Command \"
    Set-Service -Name wuauserv -StartupType Manual
    Start-Service wuauserv
    Write-Output 'Windows Update service started'
\"" || true

info "  Checking for security updates..."
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

info "  ${update_result}"

info "  Disabling Windows Update service..."
# shellcheck disable=SC2086
ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "powershell -NoProfile -NonInteractive -Command \"
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Set-Service -Name wuauserv -StartupType Disabled
    Write-Output 'Windows Update service disabled'
\"" || true

if [[ "${update_result}" == *"REBOOT:True"* ]]; then
    info "  Reboot required after security updates — rebooting VM..."
    ssh "root@${NODE}.mgmt.internal" "qm reboot ${VMID}" || true
    info "  Waiting 120 seconds for VM to restart..."
    sleep 120

    max_wait=300
    waited=0
    info "  Waiting for SSH to become available on ${VM_HOST}..."
    # shellcheck disable=SC2086
    while ! ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "exit 0" &>/dev/null; do
        sleep 10
        waited=$((waited + 10))
        if [[ ${waited} -ge ${max_wait} ]]; then
            error "  SSH not available on ${VM_HOST} after ${max_wait}s"
            exit 1
        fi
    done
    info "  VM is back online after reboot"
elif [[ "${update_result}" == *"UPDATES:0"* ]]; then
    info "  No security updates available — system is up to date"
else
    info "  Updates installed — no reboot required"
fi

info "=== Windows Security Update complete ==="
