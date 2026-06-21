#!/usr/bin/env bash
# Link this component's CLI entry scripts into ~/bin (idempotent).
# Entries = every *.sh here except the verb scripts.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
for f in "${here}"/*.sh; do
    b="$(basename "${f}")"
    case "${b}" in install.sh|update.sh|test.sh|validate.sh) continue ;; esac
    chmod +x "${f}"; ln -sfn "${f}" "${bin}/${b}"; echo "  linked ${bin}/${b}"
done
ln -sfn "${here}/variant-manager.sh" "${bin}/variant-manager"; echo "  linked ${bin}/variant-manager"
