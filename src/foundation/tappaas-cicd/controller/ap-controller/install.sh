#!/usr/bin/env bash
# Link this component's CLI entry programs into ~/bin (idempotent).
# Entries = every executable regular file here except verb scripts, README, test-*.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
for f in "${here}"/*; do
    [ -f "${f}" ] || continue
    b="$(basename "${f}")"
    case "${b}" in install.sh|update.sh|test.sh|validate.sh|README.md) continue ;; esac
    case "${b}" in test-*) continue ;; esac
    [ -x "${f}" ] || chmod +x "${f}"
    ln -sfn "${f}" "${bin}/${b}"; echo "  linked ${bin}/${b}"
done
# Compat alias: ap-manager -> ap-controller (drop at a later cutover).
ln -sfn "${here}/ap-controller" "${bin}/ap-manager"; echo "  linked ${bin}/ap-manager (alias)"
