#!/usr/bin/env bash
#
# TAPPaaS Test Fixture — dependsOn-delta provider (issue #511)
#
# No-op module installer: this fixture has no VM and no in-VM state. It exists
# only so an already-installed consumer module can gain/lose a dependency on its
# 'probe' service, letting ../../test-dependson-delta-e2e.sh verify that
# update-module.sh runs install-service.sh (added) / delete-service.sh (removed)
# with the correct verb.
#
# Usage: ./install.sh <vmname>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

info "${BOLD}test-depprov: no post-install steps (dependsOn-delta provider fixture)${CL}"
