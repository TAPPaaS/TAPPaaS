#!/usr/bin/env bash
# Runs this component's co-located unit tests (test-*.sh). Exit non-zero on any fail.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; rc=0
shopt -s nullglob
for t in "${here}"/test-*.sh; do
    echo "== $(basename "${t}") =="
    bash "${t}" || rc=1
done
exit "${rc}"
