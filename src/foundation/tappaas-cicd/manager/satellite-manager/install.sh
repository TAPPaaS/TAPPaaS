#!/usr/bin/env bash
# install.sh — link satellite-manager onto PATH (idempotent). Bash component:
# nothing to compile (ADR-010; orchestration-heavy, stays bash per ADR-007 thin-
# orchestration). The parent dispatcher SKIPS TEMPLATE/ but runs this for real components.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
mkdir -p "${bin}"
chmod +x "${here}/satellite-manager.sh"
ln -sfn "${here}/satellite-manager.sh" "${bin}/satellite-manager"
echo "  linked ${bin}/satellite-manager -> ${here}/satellite-manager.sh"
