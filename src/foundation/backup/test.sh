#!/usr/bin/env bash
# backup/test.sh — module test for the backup (Proxmox Backup Server) module.
#
# FAST (default): the pure unit suites for the PBS helper libs (lib/test-*.sh) —
#   no cluster access (vmid-list CSV logic, ACL-path / parent-chain / retention).
#   These were previously orphaned (no module test.sh aggregated them).
# DEEP (TAPPAAS_TEST_DEEP=1): read-only live PBS reachability via backup-controller.
#
# Note: the per-VM backup verification (services/vm/test-service.sh) is a SERVICE
# test run by test-module.sh for each module that declares `dependsOn backup:vm`
# — it belongs to those consumer modules, not here.
#
# Usage: ./test.sh        (fast) ; TAPPAAS_TEST_DEEP=1 ./test.sh   (+ live PBS)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0

echo "== backup: PBS helper unit tests (offline) =="
shopt -s nullglob
for t in "${here}"/lib/test-*.sh; do
    echo "-- $(basename "${t}") --"
    bash "${t}" || rc=1
done

if [[ "${TAPPAAS_TEST_DEEP:-0}" == "1" ]]; then
    echo "== backup (deep): live PBS reachability =="
    if command -v backup-controller >/dev/null 2>&1; then
        if backup-controller list >/dev/null 2>&1; then
            echo "  ✓ backup-controller reaches PBS (datastore listable)"
        else
            echo "  ✗ backup-controller could not reach/list PBS"
            rc=1
        fi
    else
        echo "  SKIP: backup-controller not on PATH (run the module install first)"
    fi
else
    echo "  (deep tier skipped — set TAPPAAS_TEST_DEEP=1 for the live PBS check)"
fi

echo ""
[[ "${rc}" -eq 0 ]] && echo "backup: all tests passed" || echo "backup: FAILURES above"
exit "${rc}"
