#!/usr/bin/env bash
# TAPPaaS Module Installation Template
#
# Install and configure a module. It assumes that you are in the install
# directory.
#
# Note: VM creation is handled by the cluster:vm install-service.sh (declared
# via "cluster:vm" in dependsOn), invoked by install-module.sh before this
# script runs. Do NOT source any install-vm.sh helper here — that legacy
# pre-cluster:vm creator no longer exists (issue #166).
#
# The generic body below works for many modules: everything an install needs is
# also needed at update time, so install runs update.
#
# ── REPLACE THE WARNING BELOW WITH THIS MODULE'S OWN INSTALL STEPS ───────
# Anything that happens once, at install: creating the application's data
# store, its first-run configuration, its secrets. Delete the warning when you
# write them — while it is here, this module installs nothing of its own.
# ─────────────────────────────────────────────────────────────────────────

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

warn "install.sh has not been implemented for this module — it is a template stub, so nothing module-specific was installed. Please contact the module's developer."

# run the update script as all update actions are also needed at install time
. ./update.sh

echo ""
info "${GN}✓${CL} VM installation completed successfully."
