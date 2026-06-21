#!/usr/bin/env bash
# manager/health-manager/test.sh — smoke test: every entry script parses (bash -n)
# and resolves on PATH. Exit non-zero on any failure.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for f in "${here}"/*.sh; do
    b="$(basename "${f}")"
    case "${b}" in install.sh|update.sh|test.sh|validate.sh) continue ;; esac
    if bash -n "${f}"; then echo "  ok: ${b} parses"; else echo "  FAIL: ${b} syntax"; rc=1; fi
    command -v "${b}" >/dev/null 2>&1 && echo "  ok: ${b} on PATH" || { echo "  FAIL: ${b} not on PATH"; rc=1; }
done
exit "${rc}"
