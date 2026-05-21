#!/usr/bin/env bash
#
# TAPPaaS Test Fixture - HA drift reconciler (issue #193)
#
# No-op module installer: the VM is created by the cluster:vm install-service
# and HA is configured by the cluster:ha install-service. This module exists
# only so ../test.sh --deep can stand up a disposable HA-managed VM, induce
# HA config drift, and verify cluster:ha update-service reconciles it.
#
# Usage: ./install.sh <vmname>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

info "${BOLD}test-hadrift: no post-install steps (HA drift-test fixture)${CL}"
