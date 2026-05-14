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

echo ""
info "${GN}✓${CL} VM installation completed successfully."
