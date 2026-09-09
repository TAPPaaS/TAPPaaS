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

# Accept --deep as well as TAPPAAS_TEST_DEEP=1. Every gate below reads the
# variable, so exporting it here is all a flag needs to do — and exporting (not
# just setting) is what carries it into any suite this one dispatches. Without
# this, `test.sh --deep` silently ran the fast path.
for _a in "$@"; do [[ "${_a}" == "--deep" ]] && export TAPPAAS_TEST_DEEP=1; done


here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0

echo "== backup: PBS helper unit tests (offline) =="
shopt -s nullglob
for t in "${here}"/lib/test-*.sh; do
    echo "-- $(basename "${t}") --"
    bash "${t}" || rc=1
done

# ── #604: nothing in install.sh touches the PBS host's filesystem locally ──
# The datastore lives on the PBS node. A mkdir/rm/chown against a /<storage>
# path without an ssh runs on the MOTHERSHIP instead, where that path is not a
# mount — it silently creates a stray tree on the root filesystem, and (under
# `set -e`, with a sudo that asks for a password) can abort the install outright.
echo "== backup: no local filesystem writes to a PBS storage path (#604) =="
_stray="$(grep -nE '^[[:space:]]*(sudo[[:space:]]+)?(mkdir|rm|chown|chmod|touch)[^|]*[[:space:]]/\$\{?STORAGE' \
    "${here}/install.sh" "${here}/update.sh" 2>/dev/null || true)"
if [[ -z "${_stray}" ]]; then
    echo "  ok: install.sh/update.sh never write to /\${STORAGE} without ssh"
else
    echo "  FAIL: a local write to the PBS storage path — it would run on the mothership:"
    printf '%s\n' "${_stray}" | sed 's/^/      /'
    rc=1
fi

if [[ "${TAPPAAS_TEST_DEEP:-0}" == "1" ]]; then
    echo "== backup (deep): live PBS reachability =="
    if command -v backup-controller >/dev/null 2>&1; then
        # `list` takes a MODULE argument (`list <module>`), so a bare `list` is a
        # usage error, not a reachability result — it exited non-zero on every
        # healthy system and reported "could not reach PBS". Probe with verbs that
        # genuinely query PBS and need no arguments.
        if backup-controller job-status >/dev/null 2>&1 \
           && backup-controller namespaces >/dev/null 2>&1; then
            echo "  ✓ backup-controller reaches PBS (job + namespaces queryable)"
        else
            echo "  ✗ backup-controller could not reach PBS"
            backup-controller job-status 2>&1 | tail -3 | sed 's/^/      /'
            backup-controller namespaces 2>&1 | tail -3 | sed 's/^/      /' 
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
