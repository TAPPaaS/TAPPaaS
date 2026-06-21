#!/usr/bin/env bash
#
# rollback-test fixture — install hook (#307).
#
# install-module.sh has already created and booted the VM; this post-install
# hook just stamps the health sentinel (GOOD) into the guest. That GOOD state is
# what the pre-update snapshot captures and what a successful rollback restores.
#
# Usage: ./install.sh <module>   (called by install-module.sh)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../../lib/common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=lib.sh disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

MODULE="${1:-rollback-test}"
readonly MODULE

VMID="$(rbt_vmid "${MODULE}")"
NODE="$(rbt_node "${MODULE}")"
[[ -z "${VMID}" ]] && die "rollback-test: no vmid in installed config"

echo ""
info "${BOLD}rollback-test: stamping health sentinel (GOOD) into guest ${VMID}${CL}"
rbt_write_sentinel "${VMID}" "${NODE}" "GOOD" || die "rollback-test: could not write sentinel"

val="$(rbt_read_sentinel "${VMID}" "${NODE}")"
[[ "${val}" == "GOOD" ]] || die "rollback-test: sentinel verify failed (got '${val}')"
info "  ${GN}✓${CL} sentinel = GOOD — fixture healthy"
