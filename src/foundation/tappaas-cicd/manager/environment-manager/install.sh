#!/usr/bin/env bash
# Link this component's CLI entry scripts into ~/bin (idempotent).
# Entries = every *.sh here except the verb scripts.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
mkdir -p "${bin}"

# ── build + link the TypeScript CLI via Nix (ADR-007 #3) ──────────────
echo "  building environment-manager (tsc via nix-build)..."
( cd "${here}" && nix-build -A default default.nix --no-out-link >/tmp/environment-manager-build.path )
out="$(cat /tmp/environment-manager-build.path)"
[[ -x "${out}/bin/environment-manager" ]] || { echo "  ERROR: build did not produce environment-manager" >&2; exit 1; }
ln -sfn "${out}/bin/environment-manager" "${bin}/environment-manager"
echo "  linked ${bin}/environment-manager -> ${out}/bin/environment-manager"

for f in "${here}"/*.sh; do
    b="$(basename "${f}")"
    case "${b}" in install.sh|update.sh|test.sh|validate.sh) continue ;; esac
    chmod +x "${f}"; ln -sfn "${f}" "${bin}/${b}"; echo "  linked ${bin}/${b}"
done
