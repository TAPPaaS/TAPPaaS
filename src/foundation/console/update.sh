#!/usr/bin/env bash
#
# console update — nothing of its own: the service is rebuilt with the control
# plane (tappaas-cicd/ui/install.sh) and its route is reconciled by its services.
#
# Usage: update.sh <instance>
set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh
debug "  console: the service is updated with the control plane; nothing to do here"
