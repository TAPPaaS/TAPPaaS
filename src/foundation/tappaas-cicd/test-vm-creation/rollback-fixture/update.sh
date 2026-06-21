#!/usr/bin/env bash
#
# rollback-test fixture — update step (#307).
#
# Behaviour is driven by a control file on the cicd host so the deep-test driver
# (test-rollback.sh) can choose which rollback trigger to exercise:
#
#   /tmp/tappaas-rollback-test.mode
#     off|<absent>  -> re-stamp GOOD, exit 0      (normal healthy update)
#     fail          -> break sentinel, exit 1     (drives Step-5 rollback)
#     test          -> break sentinel, exit 0     (drives Step-6 post-test rollback)
#
# test.sh never reads this file — it is a genuine health check. Only the *update*
# breaks things, which is exactly the situation the rollback machinery defends.
#
# Usage: ./update.sh <module>   (called by update-module.sh, Step 5)
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
readonly MODE_FILE="/tmp/tappaas-rollback-test.mode"

mode="off"
[[ -f "${MODE_FILE}" ]] && mode="$(tr -d '[:space:]' < "${MODE_FILE}")"

VMID="$(rbt_vmid "${MODULE}")"
NODE="$(rbt_node "${MODULE}")"
[[ -z "${VMID}" ]] && die "rollback-test: no vmid in installed config"

case "${mode}" in
    fail)
        warn "rollback-test update (mode=fail): breaking functionality, then exiting non-zero"
        rbt_write_sentinel "${VMID}" "${NODE}" "BROKEN" || true
        exit 1
        ;;
    test)
        warn "rollback-test update (mode=test): breaking functionality, exiting 0 (post-update test must catch it)"
        rbt_write_sentinel "${VMID}" "${NODE}" "BROKEN" || true
        exit 0
        ;;
    *)
        info "rollback-test update (mode=off): re-stamping GOOD (healthy no-op update)"
        rbt_write_sentinel "${VMID}" "${NODE}" "GOOD"
        exit 0
        ;;
esac
