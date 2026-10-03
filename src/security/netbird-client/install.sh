#!/usr/bin/env bash
# TAPPaaS Module: netbird-client — Installation
#
# TAPPaaS NetBird Client — a per-user VPN client VM for home/business users to
# reach their solution's zones (distinct from the mgmt admin-vpn tunnel).
#
# VM creation is handled by cluster:vm and HA registration by cluster:ha — both
# declared in dependsOn and run by install-module.sh BEFORE this script. Do NOT
# source the legacy install-vm.sh or call update-HA.sh; neither exists anymore
# (removed by #166 and ADR-007 respectively).
#
# The NetBird package install is still manual — see INSTALL.md (Post-install).
#
# Usage: ./install.sh <vmname>
# Example: ./install.sh netbird-client

. /home/tappaas/bin/common-install-routines.sh

# run the update script as all update actions are also needed at install time
. ./update.sh

echo ""
info "${GN}✓${CL} netbird-client installation completed successfully."
