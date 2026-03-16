#!/usr/bin/env bash
#
# TAPPaaS Backup VM Service - Install
#
# Configures backup for a consuming module's VM.
#
# Usage: install-service.sh <module-name>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

debug "backup:vm install-service called for module: ${1:-unknown} (not yet implemented)"
exit 0
