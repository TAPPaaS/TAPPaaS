#!/usr/bin/env bash
# install.sh — link pbs-controller's CLI entry onto ~/bin (idempotent).
# Bash component: nothing to compile — link the entry program only.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
mkdir -p "${bin}"
[ -x "${here}/pbs-controller" ] || chmod +x "${here}/pbs-controller"
ln -sfn "${here}/pbs-controller" "${bin}/pbs-controller"
# The old name, an alias for one release (ADR-035 P2): backup-controller -> pbs-controller.
ln -sfn "${here}/pbs-controller" "${bin}/backup-controller"; echo "  linked ${bin}/backup-controller (alias)"
echo "  linked ${bin}/pbs-controller"
