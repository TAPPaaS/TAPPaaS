#!/usr/bin/env bash
# controller/install.sh — ADR-007 P4/S0 two-level dispatcher (no shared runner).
# Runs each child component's install.sh, skipping TEMPLATE/. Idempotent; a
# failing child does not stop the others (worst rc is returned).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for d in "${here}"/*/; do
    [ "$(basename "${d}")" = TEMPLATE ] && continue
    [ -x "${d}install.sh" ] || continue
    echo "==> controller/$(basename "${d}")/install.sh"
    "${d}install.sh" "$@" || rc=$?
done
exit "${rc}"
