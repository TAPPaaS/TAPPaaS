#!/usr/bin/env bash
#
# TAPPaaS hass Module Installation
#
# HAOS is self-managing. VM creation (sata0, efidisk0, boot order, no cloud-init)
# is fully handled by Create-TAPPaaS-VM.sh via bios:ovmf and cloudInit:false in JSON.

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

. ./update.sh

# Apply TAPPaaS-native HAOS configuration (trusted_proxies, external_url, LLAT bootstrap)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "${SCRIPT_DIR}/services/config/install-service.sh" ]]; then
    info "Running hass:config service..."
    bash "${SCRIPT_DIR}/services/config/install-service.sh" "${1:-hass}"
fi

echo ""
info "${GN}✓${CL} VM installation completed successfully."
