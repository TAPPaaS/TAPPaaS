#!/usr/bin/env bash
# TAPPaaS Module Installation Template
#
# < Update the following lines to match your project, current code is generic example code that works for many modules >
# install and configure a Module
# It assumes that you are in the install directory
#
# Note: VM creation is handled by the cluster:vm install-service.sh (declared
# via "cluster:vm" in dependsOn), invoked by install-module.sh before this
# script runs. Do NOT source any install-vm.sh helper here — that legacy
# pre-cluster:vm creator no longer exists (issue #166).

# run the update script as all update actions is also needed at install time
. ./update.sh

echo ""
info "${GN}✓${CL} VM installation completed successfully."