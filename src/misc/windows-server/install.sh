#!/usr/bin/env bash
#
# TAPPaaS Windows Server Module - Install
#
# The cluster:vm dependency clones the template and runs OOBE.
# templates:windows (services/windows/install-service.sh) then applies the
# full baseline: disk extension, VirtIO agent, security updates, RDP, tappaas account.
#
# This script is called AFTER those dependencies complete, so no extra steps
# are needed for a barebone Windows Server VM.
#
# Usage: ./install.sh <vmname>
# Example: ./install.sh windows-server
#

set -euo pipefail

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh

MODULE_NAME="${1:-windows-server}"
VMNAME="$(get_config_value 'vmname' "$MODULE_NAME")"
ZONE0="$(get_config_value 'zone0' 'srv')"

info "${GN}✓${CL} Windows Server installation completed."
info "  Access via SSH: ssh tappaas@${VMNAME}.${ZONE0}.internal"
