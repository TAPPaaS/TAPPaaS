#!/usr/bin/env bash
#
# TAPPaaS Templates Windows Service - Install
#
# Full lifecycle handler for a freshly cloned Windows Server VM:
#   Phase 1 — Wait for OOBE to complete, confirm SSH access, detach OOBE ISO
#   Phase 2 — Apply generic Windows Server baseline over SSH:
#               - C: disk extension (removes Recovery Partition, fills disk)
#               - VirtIO guest agent verification / install (QEMU-GA)
#               - PSWindowsUpdate + security-only Windows Updates
#               - RDP enable/disable (windows.enableRDP in module JSON)
#               - tappaas account verification + remote PowerShell tips
#
# Called automatically by install-module.sh via the templates:windows dependency.
# Module install.sh handles only app-specific steps after this completes.
#
# Usage: ./install-service.sh <module-name>
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

if [[ -z "${1:-}" ]]; then
    echo "Usage: ${SCRIPT_NAME} <module-name>"
    exit 1
fi

MODULE_NAME="$1"

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "$MODULE_NAME")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0="$(get_config_value 'zone0' 'srv')"
readonly VMNAME VMID NODE ZONE0

VM_HOST="${VMNAME}.${ZONE0}.internal"
readonly VM_HOST

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${VMNAME}.json"

ENABLE_RDP="$(read_module_config "${VMNAME}" | jq -r '.windows.enableRDP // false')"
readonly ENABLE_RDP

readonly SSH_OPTS="-o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes"
readonly SCP_OPTS="-o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes"

# ── Phase 1: OOBE wait + ISO detach ───────────────────────────────────

phase_oobe_wait() {
    local max_wait=1200 retry=15 elapsed=0

    info "Phase 1: Waiting for OOBE on ${VM_HOST} (timeout: $((max_wait / 60)) min)"
    info "  (Windows is running the answer file — tappaas account + SSH are configured automatically)"
    echo ""

    while true; do
        # shellcheck disable=SC2086
        if ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "exit 0" 2>/dev/null; then
            printf "\r%-70s\n" ""
            info "${GN}✓${CL} SSH available on ${VM_HOST}"
            break
        fi
        if [[ ${elapsed} -ge ${max_wait} ]]; then
            printf "\r%-70s\n" ""
            error "Timed out after ${max_wait}s — SSH not available on ${VM_HOST}"
            error "  1. Check OOBE progress : ssh root@${NODE}.mgmt.internal 'qm monitor ${VMID}'"
            error "  2. Verify VM running   : ssh root@${NODE}.mgmt.internal 'qm status ${VMID}'"
            error "  3. Setup log in console: C:\\tappaas-setup.log"
            error "  4. OOBE ISO attached?  : ssh root@${NODE}.mgmt.internal 'qm config ${VMID} | grep ide'"
            error "  5. DNS resolves?       : getent hosts ${VM_HOST}"
            error "  6. VM console          : ssh root@${NODE}.mgmt.internal 'qm screendump ${VMID} > /tmp/s.ppm && base64 /tmp/s.ppm'"
            exit 1
        fi
        printf "\r  Waiting for SSH on %s%s  [%dm %02ds elapsed]  " \
            "${VM_HOST}" \
            "$(printf '%0.s.' $(seq 1 $(( (elapsed / retry) % 4 ))))" \
            $((elapsed / 60)) $((elapsed % 60))
        # Every 5 minutes: check VM is still alive.
        # Three outcomes from the node: "status: running" (good), "status: stopped" (bad),
        # or nothing with non-zero exit (VM deleted — bad). SSH failure = node unreachable,
        # which is transient — skip rather than abort.
        if [[ $((elapsed % 300)) -eq 0 && ${elapsed} -gt 0 ]]; then
            _raw=$(ssh -n -o BatchMode=yes -o ConnectTimeout=5 \
                "root@${NODE}.mgmt.internal" \
                "qm status ${VMID} 2>/dev/null || echo NOT_FOUND" 2>/dev/null) \
                || _raw="SSH_FAIL"
            case "$_raw" in
                *running*)  ;;   # VM running — all good
                "SSH_FAIL") ;;   # Node unreachable — skip this cycle
                *)               # stopped or NOT_FOUND
                    printf "\r%-70s\n" ""
                    error "VM ${VMID} is no longer running — OOBE did not complete."
                    error "  Check: ssh root@${NODE}.mgmt.internal 'qm monitor ${VMID}'"
                    exit 1 ;;
            esac
        fi
        sleep "${retry}"
        elapsed=$((elapsed + retry))
    done

    local oobe_iso="tappaas-oobe-${VMID}.iso"
    local attached
    attached=$(ssh -n -o BatchMode=yes -o ConnectTimeout=5 \
        "root@${NODE}.mgmt.internal" \
        "qm config ${VMID} 2>/dev/null | grep -c '${oobe_iso}' || true" 2>/dev/null) || true

    if [[ "${attached:-0}" -gt 0 ]]; then
        info "Detaching OOBE answer ISO (${oobe_iso})..."
        ssh -n -o BatchMode=yes "root@${NODE}.mgmt.internal" \
            "qm set ${VMID} --delete ide1 2>/dev/null || true" >/dev/null 2>&1 || true
        ssh -n -o BatchMode=yes "root@${NODE}.mgmt.internal" \
            "pvesm free 'local:iso/${oobe_iso}' 2>/dev/null || true" >/dev/null 2>&1 || true
        info "${GN}✓${CL} OOBE ISO detached"
    fi
}

# ── PS1 execution helper ────────────────────────────────────────────────
#
# Writes a .ps1 file locally, SCPs it to the VM, executes via -File, cleans up.
# Using -File avoids $VARIABLE expansion by the outer PowerShell SSH shell.

run_ps1() {
    local label="$1"
    local script="$2"
    local filename="tappaas_${label}_$$.ps1"
    local remote_path="C:/Users/tappaas/${filename}"
    local local_tmp exit_code=0
    local_tmp=$(mktemp --suffix=".ps1")

    # Prepend UTF-8 BOM so PowerShell 5.1 reads the file as UTF-8.
    # Without the BOM, PS5.1 defaults to Windows-1252 and misinterprets
    # multi-byte characters (e.g. em dash U+2014 → 0x94 = right double-quote).
    printf '\xef\xbb\xbf%s' "${script}" > "${local_tmp}"
    # shellcheck disable=SC2086
    scp ${SCP_OPTS} "${local_tmp}" "tappaas@${VM_HOST}:~/${filename}"
    rm -f "${local_tmp}"
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ${remote_path}" \
        || exit_code=$?
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "powershell -NoProfile -NonInteractive -Command \"Remove-Item '${remote_path}' -Force -ErrorAction SilentlyContinue\"" \
        2>/dev/null || true

    return ${exit_code}
}

# ── Phase 1.5: Hostname fix + network profile ─────────────────────────
#
# Rename-Computer and Set-NetConnectionProfile don't survive the OOBE oobeSystem
# reset when applied via the guest agent during specialize.  We defer both here:
# Windows is fully booted, SSH is up, so these work reliably and stick.

step_hostname_fix() {
    info ""
    info "Step 0: Hostname + network profile"

    # Fix network profile (Public → Private) so the built-in OpenSSH firewall
    # rule (Private only) also covers this interface, in addition to the
    # TAPPaaS-SSH netsh rule added during OOBE injection.
    run_ps1 "network_profile" '
$ErrorActionPreference = "Continue"
Get-NetConnectionProfile | ForEach-Object {
    Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
}
Set-NetFirewallRule -DisplayName "OpenSSH SSH Server (sshd)" -Profile Any -ErrorAction SilentlyContinue
Write-Output "  Network profile: Private. SSH firewall rule: Any."
' || true  # non-fatal — TAPPaaS-SSH netsh rule is the primary SSH path

    # Check and fix hostname
    # shellcheck disable=SC2086
    local current_host
    current_host=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" 'hostname' 2>/dev/null | tr -d '\r\n' || echo "")
    if [[ "${current_host,,}" == "${VMNAME,,}" ]]; then
        info "  ${GN}✓${CL} Hostname already correct: ${current_host}"
        return 0
    fi

    info "  Renaming: ${current_host} → ${VMNAME} (reboot required)"
    # Rename — don't include Restart-Computer in run_ps1 (connection would drop mid-cleanup)
    if ! run_ps1 "hostname_fix" "Rename-Computer -NewName '${VMNAME}' -Force -ErrorAction Stop; Write-Output '  Rename scheduled.'"; then
        error "  Rename-Computer failed"
        return 1
    fi
    # Reboot separately — connection drop is expected, ignore exit code
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        'powershell -NoProfile -NonInteractive -Command "Start-Sleep 1; Restart-Computer -Force"' \
        2>/dev/null || true

    info "  Waiting for VM to reboot..."
    local elapsed=0 max_wait=300
    while [[ ${elapsed} -lt ${max_wait} ]]; do
        sleep 10; elapsed=$((elapsed + 10))
        # shellcheck disable=SC2086
        if ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "exit 0" 2>/dev/null; then
            info "  ${GN}✓${CL} Hostname set to ${VMNAME}"
            return 0
        fi
    done
    error "  Timed out (${max_wait}s) waiting for VM after hostname reboot"
    return 1
}

# ── Phase 2: Generic Windows baseline ─────────────────────────────────

step_disk_extend() {
    info ""
    info "Step 1: Extend C: to fill available disk"  # Step 0 is hostname_fix
    run_ps1 "disk_extend" '
$ErrorActionPreference = "Continue"

# Disable Windows Recovery Environment so the recovery partition can be deleted.
# Without this, diskpart "delete partition override" may silently fail or leave the
# VDS in a state that blocks Get-PartitionSupportedSize indefinitely.
$rea = & reagentc /disable 2>&1
Write-Output "  reagentc /disable: exit $LASTEXITCODE"

# Find and remove the Recovery partition (it sits between C: and the unallocated
# space added when Proxmox resized the virtual disk, blocking C: from extending).
$recovery = Get-Partition -DiskNumber 0 -ErrorAction SilentlyContinue |
    Where-Object { $_.Type -eq "Recovery" }
if ($recovery) {
    Write-Output "  Recovery partition $($recovery.PartitionNumber) found — deleting via diskpart..."
    $dpScript = "select disk 0`r`nselect partition $($recovery.PartitionNumber)`r`ndelete partition override`r`nrescan"
    $dpTmp = "$env:TEMP\tappaas_diskpart_$PID.txt"
    [System.IO.File]::WriteAllText($dpTmp, $dpScript)
    & diskpart /s $dpTmp 2>&1 | ForEach-Object { Write-Output "  diskpart: $_" }
    Remove-Item $dpTmp -Force -ErrorAction SilentlyContinue
    # Wait for VDS to process the partition table change before querying supported sizes.
    Start-Sleep -Seconds 5
    Update-Disk -Number 0 -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
} else {
    Write-Output "  No Recovery Partition found — skipping deletion."
}

# Extend C: into adjacent unallocated space.
$supported = Get-PartitionSupportedSize -DriveLetter C -ErrorAction SilentlyContinue
$current   = (Get-Partition -DriveLetter C -ErrorAction SilentlyContinue).Size
if ($supported -and $current -and ($supported.SizeMax -gt $current)) {
    $from = [math]::Round($current / 1GB, 1)
    $to   = [math]::Round($supported.SizeMax / 1GB, 1)
    Resize-Partition -DriveLetter C -Size $supported.SizeMax -ErrorAction Stop
    Write-Output "  C: extended from ${from}GB to ${to}GB."
} else {
    $cur = if ($current) { [math]::Round($current/1GB,1) } else { "?" }
    Write-Output "  C: already at maximum (${cur}GB) — skipping."
}
Write-Output "Disk extend complete. Free: $([math]::Round((Get-PSDrive C).Free/1GB,1))GB"
'
}

step_virtio_agent() {
    info ""
    info "Step 2: VirtIO guest agent (QEMU-GA)"
    run_ps1 "virtio_agent" '
$ErrorActionPreference = "Stop"
$svc = Get-Service -Name QEMU-GA -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") { Write-Output "  QEMU-GA already running."; exit 0 }
if ($svc) {
    Start-Service QEMU-GA -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $svc = Get-Service -Name QEMU-GA -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") { Write-Output "  QEMU-GA started."; exit 0 }
}
Write-Output "  Downloading VirtIO guest tools ..."
$url = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win-guest-tools.exe"
$out = "$env:TEMP\virtio-win-guest-tools.exe"
& curl.exe -L -s -S -f -o $out $url
if ($LASTEXITCODE -ne 0) { Write-Error "curl.exe failed (exit $LASTEXITCODE)"; exit 1 }
$proc = Start-Process -Wait -PassThru -NoNewWindow -FilePath $out -ArgumentList "/S"
Remove-Item $out -Force -ErrorAction SilentlyContinue
if ($proc.ExitCode -notin @(0, 3010)) { Write-Error "Installer exited $($proc.ExitCode)"; exit 1 }
Start-Sleep -Seconds 5
$svc = Get-Service -Name QEMU-GA -ErrorAction SilentlyContinue
if (-not ($svc -and $svc.Status -eq "Running")) { Write-Error "QEMU-GA not running after install"; exit 1 }
Write-Output "  VirtIO guest agent installed and running."
'
}

step_windows_update() {
    info ""
    info "Step 3: Security-only Windows Updates  (timeout: 30 min — be patient)"
    # PSWindowsUpdate requires SYSTEM/elevation — SSH sessions don't get UAC.
    # Workaround: create a one-shot Scheduled Task that runs as SYSTEM, wait for it.
    run_ps1 "windows_update" '
$ErrorActionPreference = "Stop"
$logFile = "C:\tappaas-wu.log"
$psWU = Get-Module -ListAvailable -Name PSWindowsUpdate -ErrorAction SilentlyContinue
if (-not $psWU) {
    Install-PackageProvider -Name NuGet -Force -Scope AllUsers | Out-Null
    Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers -AllowClobber | Out-Null
    Write-Output "  PSWindowsUpdate installed."
}
$taskScript = @"
Import-Module PSWindowsUpdate
Set-Service -Name wuauserv -StartupType Manual -ErrorAction SilentlyContinue
Start-Service wuauserv -ErrorAction SilentlyContinue
# Scan all important updates (security, cumulative, critical) but skip drivers
# and optional features.  -Category "Security Updates" alone misses cumulative
# quality updates that bundle security fixes — use NotCategory to exclude only
# driver and optional updates instead.
`$available = Get-WindowsUpdate -NotCategory "Drivers","Optional Features","Preview" -NotTitle "Preview" -IgnoreReboot -ErrorAction SilentlyContinue
if (-not `$available -or `$available.Count -eq 0) {
    Add-Content "$logFile" "  No security updates available."
} else {
    Add-Content "$logFile" "  Installing `$(`$available.Count) update(s)..."
    Get-WindowsUpdate -NotCategory "Drivers","Optional Features","Preview" -NotTitle "Preview" -AcceptAll -Install -IgnoreReboot -ErrorAction SilentlyContinue | Out-Null
    Add-Content "$logFile" "  Updates installed."
}
Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
Set-Service -Name wuauserv -StartupType Disabled -ErrorAction SilentlyContinue
`$auPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
if (-not (Test-Path `$auPath)) { New-Item -Path `$auPath -Force | Out-Null }
Set-ItemProperty -Path `$auPath -Name NoAutoUpdate -Value 1 -Type DWord | Out-Null
Add-Content "$logFile" "  Windows Update disabled (TAPPaaS-managed)."
"@
$taskScriptFile = "C:\tappaas-wu-task.ps1"
[System.IO.File]::WriteAllText($taskScriptFile, $taskScript)
$action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File $taskScriptFile"
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$task      = New-ScheduledTask -Action $action -Principal $principal
Register-ScheduledTask -TaskName "TAPPaaS-WU" -InputObject $task -Force | Out-Null
Start-ScheduledTask -TaskName "TAPPaaS-WU"
$timeout = 1800; $elapsed = 0
do {
    Start-Sleep -Seconds 15; $elapsed += 15
    $state = (Get-ScheduledTask "TAPPaaS-WU" -ErrorAction SilentlyContinue).State
    $mins = [math]::Floor($elapsed / 60); $secs = $elapsed % 60
    Write-Output "  Waiting for updates... [${mins}m ${secs}s elapsed]  task: $state"
} while ($state -ne "Ready" -and $elapsed -lt $timeout)
Unregister-ScheduledTask -TaskName "TAPPaaS-WU" -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item $taskScriptFile -Force -ErrorAction SilentlyContinue
if (Test-Path $logFile) { Get-Content $logFile | ForEach-Object { Write-Output $_ }; Remove-Item $logFile -Force }
Write-Output "  Windows Update complete."
'
}

step_rdp_setup() {
    info ""
    local action
    if [[ "${ENABLE_RDP}" == "true" ]]; then
        action="enable"; info "Step 4: Enabling RDP"
    else
        action="disable"; info "Step 4: Disabling RDP"
    fi
    local ps1
    ps1=$(cat <<'PS'
$ErrorActionPreference = "Stop"
if ('%%ACTION%%' -eq 'enable') {
    Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" fDenyTSConnections 0 -Type DWord
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
    Set-Service TermService -StartupType Automatic; Start-Service TermService -ErrorAction SilentlyContinue
    Write-Output "  RDP enabled."
} else {
    Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" fDenyTSConnections 1 -Type DWord
    Disable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
    Stop-Service TermService -Force -ErrorAction SilentlyContinue
    Set-Service TermService -StartupType Disabled -ErrorAction SilentlyContinue
    Write-Output "  RDP disabled."
}
PS
)
    ps1="${ps1//%%ACTION%%/${action}}"
    run_ps1 "rdp_setup" "${ps1}"
}

step_tappaas_account() {
    info ""
    info "Step 5: tappaas account verification"
    run_ps1 "tappaas_account" '
$ErrorActionPreference = "Stop"
$user = Get-LocalUser -Name "tappaas" -ErrorAction SilentlyContinue
if (-not $user) { Write-Error "tappaas account missing — OOBE may not have completed"; exit 1 }
if ($user.Enabled -eq $false) { Enable-LocalUser -Name "tappaas" }
$adminSid  = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
$adminName = $adminSid.Translate([System.Security.Principal.NTAccount]).Value.Split("\")[1]
$isMember  = Get-LocalGroupMember -Group $adminName -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -like "*tappaas" }
if (-not $isMember) { Add-LocalGroupMember -Group $adminName -Member "tappaas" -ErrorAction SilentlyContinue }
# Admin users use administrators_authorized_keys (sshd_config Match Group administrators).
# C:\Users\tappaas\.ssh\authorized_keys is ignored for members of the Administrators group.
$keys = "C:\ProgramData\ssh\administrators_authorized_keys"
$keyCount = if (Test-Path $keys) { (Get-Content $keys | Measure-Object -Line).Lines } else { 0 }
Write-Output "  tappaas: enabled, local admin, $keyCount SSH key(s) configured."
'
    info ""
    info "  SSH:    ssh tappaas@${VM_HOST}"
    info "  PS run: ssh tappaas@${VM_HOST} 'powershell -NoProfile -Command \"<command>\"'"
    info "  PS file: scp script.ps1 tappaas@${VM_HOST}:~/ && ssh tappaas@${VM_HOST} 'powershell -ExecutionPolicy Bypass -File C:/Users/tappaas/script.ps1'"
}

# ── Main ──────────────────────────────────────────────────────────────

main() {
    info "=== Windows Service: ${VMNAME} (VMID ${VMID}) ==="
    info "RDP: ${ENABLE_RDP}"

    phase_oobe_wait

    info ""
    info "Phase 2: Generic Windows baseline"

    local -a steps=(hostname_fix disk_extend virtio_agent windows_update rdp_setup tappaas_account)
    local -a failed=()

    for step in "${steps[@]}"; do
        if "step_${step}"; then
            info "  ✓ ${step}"
        else
            error "  ✗ ${step} failed"
            failed+=("${step}")
        fi
    done

    echo ""
    if [[ ${#failed[@]} -gt 0 ]]; then
        error "=== Completed WITH FAILURES: ${failed[*]} ==="
        exit 1
    fi
    info "=== Windows baseline complete. SSH: tappaas@${VM_HOST} ==="
}

main "$@"
