#!/usr/bin/env bash
#
# TAPPaaS HomeAssistant Module Installation
#
# HAOS is self-managing. VM creation (sata0, efidisk0, boot order, no cloud-init)
# is fully handled by Create-TAPPaaS-VM.sh via bios:ovmf and cloudInit:false in JSON.

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

. ./update.sh

echo ""
info "${GN}✓${CL} VM installation completed successfully."
