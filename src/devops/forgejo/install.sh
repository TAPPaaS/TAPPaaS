#!/usr/bin/env bash
#
# forgejo — install
#
# Thin wrapper: all configuration logic lives in update.sh.
# VM creation is handled by cluster:vm install-service.sh (declared via
# "cluster:vm" in dependsOn) and is invoked by install-module.sh before
# this script runs.
#
# Usage: install.sh <vmname>
#
set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh "${1:-forgejo}"

# Run the update logic — install = first update
. "$(dirname "${BASH_SOURCE[0]}")/update.sh" "${1:-forgejo}"

# No local admin is created (#282): accounts come from Authentik, and members of
# its forgejo-admins group are Forgejo admins. When a local admin is needed —
# Authentik down, the name unpublished, no forgejo-admins member yet — create
# one over SSH from tappaas-cicd: INSTALL.md §Local admin.

echo ""
info "${GN}✓${CL} Forgejo installation completed successfully."
info "  Next: run post-install steps from INSTALL.md §Post-install"
