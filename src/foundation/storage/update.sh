#!/usr/bin/env bash
#
# storage update — make the Site match config/shares.json (ADR-029 v0.9 D17): every
# share's server builds it through its hook, and every share alias follows its
# server. What `storage-manager nfs converge` does, run by the sweep. Consumers are
# not told from here: their own updates run in the same sweep.
#
# Usage: update.sh <instance>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. /home/tappaas/bin/common-install-routines.sh
[[ -f "${CONFIG_DIR}/shares.json" ]] || { debug "  storage: no config/shares.json — no shares declared"; exit 0; }
"${HERE}/lib/nfs-converge.sh" all
