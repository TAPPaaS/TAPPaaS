#!/usr/bin/env bash
#
# storage install — a virtual module, like cluster (ADR-029 v0.9 D1): registering it
# (config/storage.json) is what lets consumers depend on storage:nfs. There is
# nothing to install on any machine: the shares are declared through storage-manager
# and served by the cluster nodes.
#
# Usage: install.sh <instance>
set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh
info "${BOLD}storage: registered — declare shares with storage-manager (nothing to install)${CL}"
