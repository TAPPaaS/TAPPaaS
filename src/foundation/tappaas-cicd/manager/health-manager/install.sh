#!/usr/bin/env bash
# manager/health-manager/install.sh — link this component's CLI entry scripts
# into ~/bin (idempotent). Entry scripts = every *.sh here except the verb scripts.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
mkdir -p "${bin}"

# ── build + link the TypeScript CLI via Nix (ADR-007 #3) ──────────────
# The TS `health-manager` is the new read-only front door; the inspect/check
# logic scripts stay linked below (the verbs shell out to update-os.sh etc.).
echo "  building health-manager (tsc via nix-build)..."
( cd "${here}" && nix-build -A default default.nix --no-out-link >/tmp/health-manager-build.path )
out="$(cat /tmp/health-manager-build.path)"
[[ -x "${out}/bin/health-manager" ]] || { echo "  ERROR: build did not produce health-manager" >&2; exit 1; }
ln -sfn "${out}/bin/health-manager" "${bin}/health-manager"
echo "  linked ${bin}/health-manager -> ${out}/bin/health-manager"

for f in "${here}"/*.sh; do
    b="$(basename "${f}")"
    case "${b}" in install.sh|update.sh|test.sh|validate.sh) continue ;; esac
    chmod +x "${f}"
    ln -sfn "${f}" "${bin}/${b}"
    echo "  linked ${bin}/${b}"
done
