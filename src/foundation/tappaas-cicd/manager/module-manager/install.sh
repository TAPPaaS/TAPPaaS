#!/usr/bin/env bash
# Link this component's CLI entry scripts into ~/bin (idempotent).
# Entries = every *.sh here except the verb scripts.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
mkdir -p "${bin}"

# ── build + link the TypeScript CLI via Nix (ADR-007 #3) ──────────────
# The TS `module-manager` is the new verb-aligned front door. The legacy
# *-module.sh verb scripts are still linked below (transition) and remain the
# implementation the TS lifecycle verbs shell out to, until the retire phase.
echo "  building module-manager (tsc via nix-build)..."
( cd "${here}" && nix-build -A default default.nix --no-out-link >/tmp/module-manager-build.path )
out="$(cat /tmp/module-manager-build.path)"
[[ -x "${out}/bin/module-manager" ]] || { echo "  ERROR: build did not produce module-manager" >&2; exit 1; }
ln -sfn "${out}/bin/module-manager" "${bin}/module-manager"
echo "  linked ${bin}/module-manager -> ${out}/bin/module-manager"

for f in "${here}"/*.sh; do
    b="$(basename "${f}")"
    case "${b}" in install.sh|update.sh|test.sh|validate.sh) continue ;; esac
    chmod +x "${f}"; ln -sfn "${f}" "${bin}/${b}"; echo "  linked ${bin}/${b}"
done
