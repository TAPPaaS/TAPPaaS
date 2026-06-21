#!/usr/bin/env bash
# Smoke test: every entry script parses (bash -n) and resolves on PATH.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; rc=0
for f in "${here}"/*.sh; do
    b="$(basename "${f}")"
    case "${b}" in install.sh|update.sh|test.sh|validate.sh) continue ;; esac
    bash -n "${f}" && echo "  ok: ${b} parses" || { echo "  FAIL: ${b}"; rc=1; }
    command -v "${b}" >/dev/null 2>&1 && echo "  ok: ${b} on PATH" || { echo "  FAIL: ${b} not on PATH"; rc=1; }
done
exit "${rc}"
