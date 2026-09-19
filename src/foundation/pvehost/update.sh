#!/usr/bin/env bash
# pvehost update — nothing yet, deliberately (ADR-026 D4 stage 1, #665).
#
# A cluster node's OS is patched by the cluster module's update (update-os.sh,
# Step 1), with the cluster's reboot pass; stage 2 moves that behind this script
# so a node and a debianhost are patched by one path with one set of consent
# rules. Until then an update of a node instance changes nothing, and says so.
#
# Usage: update.sh <instance>
set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh
info "  ${1:-node}: OS patching is the cluster module's (update-os.sh) — nothing to do here (ADR-026 D4 stage 1)"
