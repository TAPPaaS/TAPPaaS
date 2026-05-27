#!/usr/bin/env bash
#
# TAPPaaS Backup Module Update
#
# Keeps the managed PBS backup job consistent: migrates a legacy --all job and
# ensures the alwaysBackup foundation VMs (firewall, tappaas-cicd) are present.
# Per-module membership (dependsOn backup:vm) is maintained by the consuming
# modules' own update via backup:vm update-service.sh. See issue #200.
#
# Usage: update.sh [module-name]
#

set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MODULE_DIR

. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=lib/pbs-job.sh disable=SC1091
. "${MODULE_DIR}/lib/pbs-job.sh"

info "${BOLD}Ensuring alwaysBackup VMs are registered in the managed backup job${CL}"
pbs_ensure_always

# Retrofit the ZFS-mount ordering on already-deployed PBS servers (issue #230);
# idempotent, so this is a no-op once the drop-ins are in place.
pbs_ensure_zfs_ordering

# Retrofit datastore integrity verification (verify-job + verify-new, issue #228)
# on already-deployed PBS servers; idempotent.
pbs_ensure_verify

info "  ${GN}✓${CL} Backup module update completed"
