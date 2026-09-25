#!/usr/bin/env bash
#
# reboot-guest.sh — reboot one module's VM and wait until it can serve (#730).
#
# The driver behind `health-manager reboot <module>`: the same reboot path
# update-os.sh takes after a rebuild (reboot_guest — lock wait, qm reboot, ssh,
# module readiness), on demand. For a guest whose update left a reboot pending
# (automaticReboot=false, a backup lock, a staged release move) without
# updating it again.
#
# The controller is refused: rebooting the VM that runs this would kill the
# command mid-flight (incident 2026-06-09) — reboot it from a node.
#
# Usage: reboot-guest.sh <vmname> <vmid> <node>
# Exit:  0 rebooted and ready, 1 error or refused, 3 locked (not rebooted).

set -euo pipefail

# Functions only: update-os.sh runs its main when executed, not when sourced.
# shellcheck source=update-os.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/update-os.sh"

reboot_usage() {
    cat <<EOF
Usage: $(basename "$0") <vmname> <vmid> <node>

Reboot a module's VM and wait until the module can serve again — the reboot
update-os.sh takes after a rebuild, on demand. Normally run through
'health-manager reboot <module>', which resolves these three for you.
EOF
}

reboot_main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        reboot_usage
        exit 0
    fi
    if [[ $# -ne 3 ]]; then
        reboot_usage >&2
        exit 1
    fi
    local vmname="$1" vmid="$2" node="$3" vm_ip rc=0

    [[ "${vmname}" != "$(hostname)" ]] \
        || die "${vmname} is this controller — reboot it from a node, under supervision: ssh root@${node}.${MGMT}.internal 'qm reboot ${vmid}'"

    vm_ip=$(wait_for_vm_ip "${node}" "${vmid}" 6) || die "no IP address for ${vmname} (VM ${vmid} on ${node}) — is it running?"
    info "Rebooting ${vmname} (VM ${vmid} on ${node}, ${vm_ip})..."
    reboot_guest "${vmname}" "${vmid}" "${node}" "${vm_ip}" || rc=$?
    if (( rc == 3 )); then
        error "${vmname} is locked (${REBOOT_LOCK_HOLDER}) — not rebooted. Try again when it is free."
        exit 3
    fi
    info "${GN}✓${CL} ${vmname} rebooted and ready"
}

reboot_main "$@"
