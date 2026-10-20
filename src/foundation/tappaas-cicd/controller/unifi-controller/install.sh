#!/usr/bin/env bash
# Link the UniFi controller into ~/bin (idempotent). unifi.sh and contract.json
# are its parts, not commands: only the entry point is linked.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
mkdir -p "${bin}"
chmod +x "${here}/unifi-controller"
ln -sfn "${here}/unifi-controller" "${bin}/unifi-controller"
echo "  linked ${bin}/unifi-controller"
