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
# Compat alias: callers/tests still invoking the pre-S5 name resolve to the
# renamed bin (proxmox-manager -> proxmox-controller). Drop at a later cutover.
ln -sfn "${here}/proxmox-controller" "${bin}/proxmox-manager"; echo "  linked ${bin}/proxmox-manager (alias)"
