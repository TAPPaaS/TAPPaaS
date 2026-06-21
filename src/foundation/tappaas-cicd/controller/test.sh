#!/usr/bin/env bash
# controller/test.sh — ADR-007 P4/S0 two-level dispatcher (no shared runner).
# Runs each child component's test.sh, skipping TEMPLATE/. Idempotent; a
# failing child does not stop the others (worst rc is returned).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for d in "${here}"/*/; do
    [ "$(basename "${d}")" = TEMPLATE ] && continue
    [ -x "${d}test.sh" ] || continue
    echo "==> controller/$(basename "${d}")/test.sh"
    "${d}test.sh" "$@" || rc=$?
done
exit "${rc}"
