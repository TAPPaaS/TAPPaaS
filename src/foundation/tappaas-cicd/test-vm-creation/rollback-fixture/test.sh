#!/usr/bin/env bash
#
# rollback-test fixture — health check (#307).
#
# Reads the guest sentinel and reports health. This is a REAL health check: it
# knows nothing about the update mode. A broken sentinel returns exit 2 (FATAL)
# so test-module.sh marks the run fatal and update-module.sh rolls back — the
# exact contract the firewall post-update test relies on.
#
#   GOOD          -> exit 0 (healthy)
#   anything else -> exit 2 (fatal -> rollback)
#
# Usage: ./test.sh <module>   (called by test-module.sh)
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

# test-module.sh may inject a vmid override; otherwise read it from config.
VMID="${TAPPAAS_VMID_OVERRIDE:-$(rbt_vmid "${MODULE}")}"
NODE="$(rbt_node "${MODULE}")"
[[ -z "${VMID}" ]] && { error "rollback-test: no vmid — cannot check health"; exit 2; }

val="$(rbt_read_sentinel "${VMID}" "${NODE}")"
if [[ "${val}" == "GOOD" ]]; then
    info "  ${GN}✓${CL} rollback-test health: sentinel=GOOD"
    exit 0
fi

error "  ✗ rollback-test health: sentinel='${val}' (expected GOOD) — BROKEN (fatal)"
exit 2
