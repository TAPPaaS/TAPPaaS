#!/usr/bin/env bash
# manager/install.sh — ADR-007 P4/S0 two-level dispatcher (no shared runner).
# Runs each child component's install.sh, skipping TEMPLATE/. Idempotent; a
# failing child does not stop the others (worst rc is returned).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
# Quiet by default: one '.' per component built — the child build/link logs are
# noise during install. Set TAPPAAS_DEBUG=1 to stream each child's full output.
for d in "${here}"/*/; do
    [ "$(basename "${d}")" = TEMPLATE ] && continue
    [ -x "${d}install.sh" ] || continue
    name="$(basename "${d}")"
    if [ -n "${TAPPAAS_DEBUG:-}" ]; then
        echo "==> manager/${name}/install.sh"
        "${d}install.sh" "$@" || rc=$?
    elif log="$("${d}install.sh" "$@" 2>&1)"; then
        printf '.'
    else
        rc=$?
        printf '\n[manager/%s] install failed:\n%s\n' "${name}" "${log}" >&2
    fi
done
[ -n "${TAPPAAS_DEBUG:-}" ] || printf '\n'
exit "${rc}"
