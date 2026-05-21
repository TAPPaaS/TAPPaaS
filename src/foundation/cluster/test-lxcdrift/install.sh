#!/usr/bin/env bash
#
# TAPPaaS Test Fixture - LXC provisioner + drift reconciler (issue #203)
#
# No-op module installer: the container is created by the cluster:lxc
# install-service. This module exists only so ../test.sh --deep can stand up a
# disposable plain-Debian container (no GPU), verify cluster:lxc create/net/DNS,
# induce config drift, and verify cluster:lxc update-service reconciles it.
#
# Usage: ./install.sh <vmname>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

info "${BOLD}test-lxcdrift: no post-install steps (LXC drift-test fixture)${CL}"
