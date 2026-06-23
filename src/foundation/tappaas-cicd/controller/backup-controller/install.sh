#!/usr/bin/env bash
# install.sh — link backup-controller's CLI entry onto ~/bin (idempotent).
# Bash component: nothing to compile — link the entry program only.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
mkdir -p "${bin}"
[ -x "${here}/backup-controller" ] || chmod +x "${here}/backup-controller"
ln -sfn "${here}/backup-controller" "${bin}/backup-controller"
echo "  linked ${bin}/backup-controller"
