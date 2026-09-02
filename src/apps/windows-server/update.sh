#!/usr/bin/env bash
#
# TAPPaaS Windows Server Module - Update
#
# Applies security-only Windows Updates.
# Called by update-module.sh (which creates a Proxmox snapshot first).
#
# Usage: ./update.sh <vmname>
#

set -euo pipefail

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh

MODULE_NAME="${1:-windows-server}"

WINDOWS_UPDATE="$(get_module_dir 'templates')/services/windows/update-service.sh"
[[ -x "${WINDOWS_UPDATE}" ]] || chmod +x "${WINDOWS_UPDATE}"
"${WINDOWS_UPDATE}" "${MODULE_NAME}"
