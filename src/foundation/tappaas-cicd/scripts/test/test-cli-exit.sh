#!/usr/bin/env bash
#
# test-cli-exit.sh — no TypeScript CLI ends with process.exit(run(…)) (#788).
#
# process.exit() ends Node before a large write to a PIPE has drained: health-
# manager's `scan images` reached the release preview cut at 65536 bytes, and
# every manager's --json piped into jq is cut the same way. The entry point sets
# process.exitCode and lets Node exit when the output is out.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
bad="$(grep -rnE '^\s*process\.exit\(\s*(run|main)\(' "${ROOT}/manager" "${ROOT}/controller" --include=main.ts 2>/dev/null | grep -v '/node_modules/')"
if [[ -z "${bad}" ]]; then
    echo "  ok: every CLI entry point lets its output drain (process.exitCode)"
    echo "── summary: 1 pass, 0 fail ──"; exit 0
fi
while IFS= read -r l; do echo "  FAIL: ${l#"${ROOT}/"} — set process.exitCode instead"; done <<<"${bad}"
echo "── summary: 0 pass, 1 fail ──"; exit 1
