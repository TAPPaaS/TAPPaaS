#!/usr/bin/env bash
#
# TAPPaaS Templates Debian Service - Update
#
# Runs OS-level updates on a consuming module's Debian/Ubuntu VM.
# Reads the module's JSON config to determine VM details and calls update-os.sh.
#
# Usage: update-service.sh <module-name>
#

set -euo pipefail

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <module-name>"
    echo "Updates the Debian/Ubuntu configuration for the specified module."
    exit 1
fi

MODULE_NAME="$1"

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "$MODULE_NAME")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"

# Run OS-specific update (auto-detects NixOS vs Debian). TAPPAAS_OS_AS_DEBUG=1
# routes update-os.sh's [Info] narration to [Debug] — as a module-update sub-step
# the parent already announced this call, so only the progress dots and any
# warnings/errors need to surface. Detail stays available with TAPPAAS_DEBUG=1.
# Guarded, not bare (#711): as the last command its exit status was the whole
# of what the caller learned, so a failure reached reconcile.ts as a number and
# the operator as "✗ templates:debian re-apply failed" with nothing to chase.
# Name the VM and the status here, where both are known.
rc=0
TAPPAAS_OS_AS_DEBUG=1 /home/tappaas/bin/update-os.sh "${VMNAME}" "${VMID}" "${NODE}" || rc=$?
if (( rc != 0 )); then
    error "OS update of ${VMNAME} (vmid ${VMID}, node ${NODE}) failed: update-os.sh exited ${rc}"
    error "  re-run with TAPPAAS_DEBUG=1 to see its per-step narration"
    exit "${rc}"
fi
