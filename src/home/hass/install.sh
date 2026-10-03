#!/usr/bin/env bash
#
# TAPPaaS hass Module Installation
#
# HAOS is self-managing. VM creation (sata0, efidisk0, boot order, no cloud-init)
# is fully handled by Create-TAPPaaS-VM.sh via bios:ovmf and cloudInit:false in JSON.

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Install steps live in lib/ (module-local helpers — NOT TAPPaaS services: hass
# has provides:[] and nothing dependsOn them; they are called directly here).

# Appliance SSH (HAOS): attach the CONFIG key disk (root@22222) + QGA freeze-fs,
# then cold stop/start. Runs FIRST — cloud-init is ignored by HAOS, so this is
# how the tappaas key reaches the appliance. Module-local (no engine change).
if [[ -x "${SCRIPT_DIR}/lib/appliance-ssh.sh" ]]; then
    info "Running hass appliance-ssh setup..."
    bash "${SCRIPT_DIR}/lib/appliance-ssh.sh" "${1:-hass}"
fi

. ./update.sh

# Apply TAPPaaS-native HAOS configuration (trusted_proxies, external_url, LLAT bootstrap)
if [[ -x "${SCRIPT_DIR}/lib/config.sh" ]]; then
    info "Running hass config setup..."
    bash "${SCRIPT_DIR}/lib/config.sh" "${1:-hass}"
fi

echo ""
info "${GN}✓${CL} VM installation completed successfully."
