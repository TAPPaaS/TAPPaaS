#!/usr/bin/env bash
# TAPPaaS logging Module Installation
#
# Install and configure the centralized logging VM (Loki + Grafana + Promtail).
# It assumes that you are in the install directory.
#
# VM creation happens via the cluster:vm service hook; this script only runs
# post-install configuration via update.sh.

# run the update script as all update actions is also needed at install time
. ./update.sh

# Install-only guidance (VMNAME/ZONE0NAME are set by the sourced update.sh).
# Lives here rather than in update.sh so a plain update does not repeat it.
info "${BOLD}Next steps${CL}"
info "  - Retrieve the initial Grafana admin password:"
info "      ssh tappaas@${VMNAME}.${ZONE0NAME}.internal -- sudo cat /root/grafana-admin-password.initial"
info "      Then change it in the UI and:"
info "      ssh tappaas@${VMNAME}.${ZONE0NAME}.internal -- sudo rm /root/grafana-admin-password.initial"
info "  - Other VMs: install a Promtail client pointing at http://${VMNAME}.${ZONE0NAME}.internal:3100"

info "${GN}✓${CL} VM installation completed successfully."
