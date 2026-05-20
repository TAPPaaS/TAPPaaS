#!/usr/bin/env bash
#
# TAPPaaS Test Fixture - VM drift reconciler (issue #192)
#
# No-op module installer: the VM itself is created by the cluster:vm
# install-service. This module exists only so ../test.sh --deep can stand up a
# disposable VM, induce config drift, and verify cluster:vm update-service.
#
# Usage: ./install.sh <vmname>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

info "${BOLD}test-vmdrift: no post-install steps (drift-test fixture)${CL}"
