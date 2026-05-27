#!/usr/bin/env bash
#
# TAPPaaS Templates Windows Service - Test
#
# Verifies the Windows VM baseline is correctly applied.
#
# Checks:
#   1. SSH connectivity
#   2. VirtIO guest agent (QEMU-GA) running
#   3. tappaas account exists, is enabled, and is local admin
#   4. RDP state matches windows.enableRDP in module JSON
#
# Usage: test-service.sh <module-name>
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed
#   2  Fatal error
#

set -euo pipefail

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    echo "Usage: $0 <module-name>"
    exit 2
fi

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"

if [[ ! -f "${MODULE_JSON}" ]]; then
    error "Module config not found: ${MODULE_JSON}"
    exit 2
fi

VMNAME=$(jq -r '.vmname // empty' "${MODULE_JSON}")
ZONE0=$(jq -r '.zone0 // "srv"' "${MODULE_JSON}")
VM_HOST="${VMNAME}.${ZONE0}.internal"
ENABLE_RDP=$(jq -r '.windows.enableRDP // false' "${MODULE_JSON}")

PASS=0
FAIL=0

readonly SSH_OPTS="-o ConnectTimeout=30 -o BatchMode=yes -o LogLevel=ERROR"

pass() { info "    ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "    ✗ $1"; FAIL=$((FAIL + 1)); }

run_ps() {
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "powershell -NoProfile -NonInteractive -Command \"$1\"" 2>/dev/null
}

info "  ${BOLD}templates:windows tests for ${BL}${MODULE}${CL}"
info "    VM: ${VM_HOST}"

# ── Check 1: SSH connectivity ──────────────────────────────────────────

info "  Check 1: SSH connectivity"
# shellcheck disable=SC2086
if ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "exit 0" &>/dev/null; then
    pass "SSH connection successful (tappaas@${VM_HOST})"
else
    fail "SSH connection failed to tappaas@${VM_HOST}"
    error "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
    exit 1
fi

# ── Check 2: VirtIO guest agent ───────────────────────────────────────

info "  Check 2: VirtIO guest agent (QEMU-GA)"
qemu_result=$(run_ps '
    $svc = Get-Service -Name QEMU-GA -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") { Write-Output "RUNNING" }
    elseif ($svc) { Write-Output "STOPPED" }
    else { Write-Output "NOTFOUND" }
') || true

if [[ "${qemu_result}" == "RUNNING" ]]; then
    pass "QEMU-GA service is running"
else
    fail "QEMU-GA service not running (${qemu_result:-no response}) — Proxmox integration may be impaired"
fi

# ── Check 3: tappaas account ──────────────────────────────────────────

info "  Check 3: tappaas local account"
account_result=$(run_ps '
    $user = Get-LocalUser -Name "tappaas" -ErrorAction SilentlyContinue
    if (-not $user) { Write-Output "NOTFOUND"; exit 0 }
    if ($user.Enabled -eq $false) { Write-Output "DISABLED"; exit 0 }

    $adminSid  = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
    $adminName = $adminSid.Translate([System.Security.Principal.NTAccount]).Value.Split("\")[1]
    $isMember  = Get-LocalGroupMember -Group $adminName -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -like "*tappaas" }
    if (-not $isMember) { Write-Output "NOTADMIN"; exit 0 }

    Write-Output "OK"
') || true

if [[ "${account_result}" == "OK" ]]; then
    pass "tappaas account exists, enabled, and is local admin"
elif [[ "${account_result}" == "NOTFOUND" ]]; then
    fail "tappaas account does not exist (OOBE may have failed)"
elif [[ "${account_result}" == "DISABLED" ]]; then
    fail "tappaas account is disabled"
elif [[ "${account_result}" == "NOTADMIN" ]]; then
    fail "tappaas account is not in local Administrators group"
else
    fail "tappaas account check failed (${account_result:-no response})"
fi

# ── Check 4: RDP state ────────────────────────────────────────────────

info "  Check 4: RDP state (expected: ${ENABLE_RDP})"
rdp_result=$(run_ps '
    $val = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server").fDenyTSConnections
    if ($val -eq 0) { Write-Output "ENABLED" } else { Write-Output "DISABLED" }
') || true

if [[ "${ENABLE_RDP}" == "true" ]]; then
    expected_rdp_state="ENABLED"
else
    expected_rdp_state="DISABLED"
fi

if [[ "${rdp_result}" == "${expected_rdp_state}" ]]; then
    pass "RDP is ${rdp_result} (matches windows.enableRDP=${ENABLE_RDP})"
else
    fail "RDP is ${rdp_result:-unknown} but windows.enableRDP=${ENABLE_RDP} expects ${expected_rdp_state}"
fi

# ── Summary ───────────────────────────────────────────────────────────

info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
exit 0
