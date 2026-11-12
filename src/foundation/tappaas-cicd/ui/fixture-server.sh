#!/usr/bin/env bash
#
# fixture-server.sh — the console with no live system, on this machine.
#
#   ui/fixture-server.sh [--port 9097] [--fixtures <dir>] [--overlay <dir>]
#
# Builds ui/src into ui/dist when a source is newer (the front end is the
# committed web/dist; `cd web && npm run build` after changing it), and runs the
# server in fixture mode (src/fixtures.ts) in the foreground on 127.0.0.1. Every
# verb answers from <dir>, default test/fixtures; nothing is executed. The clock
# stands at the capture unless CONSOLE_NOW is set. --overlay lays a variant's
# config/ over the fixtures' (test/fixtures/variants/off: a small site that
# collects no performance numbers). Stop it with ^C.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT=9097
FIXTURES="${HERE}/test/fixtures"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PORT="$2"; shift 2 ;;
        --fixtures) FIXTURES="$(cd "$2" && pwd)"; shift 2 ;;
        --overlay) export CONSOLE_FIXTURES_OVERLAY="$(cd "$2" && pwd)"; shift 2 ;;
        *) echo "usage: fixture-server.sh [--port 9097] [--fixtures <dir>] [--overlay <dir>]" >&2; exit 2 ;;
    esac
done

# The Mac's node is not on a shell's PATH when an app starts it.
[[ -x /opt/homebrew/bin/node ]] && PATH="${PATH}:/opt/homebrew/bin"
MAIN="${HERE}/dist/ui/src/main.js"
if [[ ! -f "${MAIN}" ]] || [[ -n "$(find "${HERE}/src" "${HERE}/../lib/ts/src" -name '*.ts' -newer "${MAIN}" -print -quit)" ]]; then
    echo "building ui/src ..."
    tsc -p "${HERE}/tsconfig.json"
fi

# One path per port, not per worktree: a page that prints it compares equal.
STATE="/tmp/tappaas-console-fixtures-${PORT}"
rm -rf -- "${STATE}"
mkdir -p "${STATE}"

export CONSOLE_RUNNER=fixtures CONSOLE_FIXTURES="${FIXTURES}" CONSOLE_STATE_DIR="${STATE}"
export CONSOLE_FIXTURES_JOURNAL="${CONSOLE_FIXTURES_JOURNAL:-${STATE}/journal.jsonl}"
[[ -f "${FIXTURES}/CAPTURED" ]] && export CONSOLE_NOW="${CONSOLE_NOW:-$(head -1 "${FIXTURES}/CAPTURED")}"

echo "http://127.0.0.1:${PORT}/  (fixtures ${FIXTURES}, clock ${CONSOLE_NOW:-running}, journal ${CONSOLE_FIXTURES_JOURNAL})"
exec node "${MAIN}" serve --listen "127.0.0.1:${PORT}"
