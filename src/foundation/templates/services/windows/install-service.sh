#!/usr/bin/env bash
#
# TAPPaaS Templates Windows Service - Install
#
# Full lifecycle handler for a freshly cloned Windows Server VM:
#   Phase 1 — Wait for OOBE to complete, confirm SSH access, detach OOBE ISO
#             (install-only: genuinely first-boot work)
#   Phase 2 — Apply generic Windows Server baseline over SSH. These steps are
#             CONVERGENT and now live in windows-baseline.sh, shared with
#             update-service.sh so they also run on update and on
#             `reconcile --apply` (#495):
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

    debug "Phase 1: Waiting for OOBE on ${VM_HOST} (timeout: $((max_wait / 60)) min)"
    debug "  (Windows is running the answer file — tappaas account + SSH are configured automatically)"
    echo ""

    while true; do
        # shellcheck disable=SC2086
        if ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "exit 0" 2>/dev/null; then
            printf "\r%-70s\n" ""
            debug "${GN}✓${CL} SSH available on ${VM_HOST}"
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
        debug "Detaching OOBE answer ISO (${oobe_iso})..."
        ssh -n -o BatchMode=yes "root@${NODE}.mgmt.internal" \
            "qm set ${VMID} --delete ide1 2>/dev/null || true" >/dev/null 2>&1 || true
        ssh -n -o BatchMode=yes "root@${NODE}.mgmt.internal" \
            "pvesm free 'local:iso/${oobe_iso}' 2>/dev/null || true" >/dev/null 2>&1 || true
        debug "${GN}✓${CL} OOBE ISO detached"
    fi
}

# ── Shared, convergent baseline steps ─────────────────────────────────
# run_ps1 + step_hostname_fix / disk_extend / virtio_agent / windows_update /
# rdp_setup / tappaas_account now live in windows-baseline.sh so update-service.sh
# runs exactly the same steps (#495). phase_oobe_wait above stays install-only.
_WIN_SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=windows-baseline.sh disable=SC1091
. "${_WIN_SVC_DIR}/windows-baseline.sh"

# ── Main ──────────────────────────────────────────────────────────────

main() {
    debug "=== Windows Service: ${VMNAME} (VMID ${VMID}) ==="
    debug "RDP: ${ENABLE_RDP}"

    phase_oobe_wait

    debug ""
    debug "Phase 2: Generic Windows baseline"

    local -a steps=(hostname_fix disk_extend virtio_agent windows_update rdp_setup tappaas_account)
    local -a failed=()

    for step in "${steps[@]}"; do
        if "step_${step}"; then
            debug "  ✓ ${step}"
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
    debug "=== Windows baseline complete. SSH: tappaas@${VM_HOST} ==="
}

main "$@"
