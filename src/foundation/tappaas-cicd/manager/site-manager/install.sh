#!/usr/bin/env bash
# install.sh — link this component's CLI entry scripts into ~/bin (idempotent).
#
# site-manager (ADR-007 P2) is a bash component. It links every *.sh here
# except the dispatcher verb scripts (install/update/test/validate.sh). That
# covers the P2 entry points:
#   migrate-configuration.sh         -> ~/bin/migrate-configuration.sh
#   migrate-configuration-to-site.sh -> ~/bin/migrate-configuration-to-site.sh (alias)
#   validate-site.sh                 -> ~/bin/validate-site.sh
# plus the still-resident legacy site scripts (create-configuration.sh, ...).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
mkdir -p "${bin}"

# ── build + link the TypeScript CLI via Nix (ADR-007 #3) ──────────────
# The TS `site-manager` is the new verb-aligned front door; the legacy site
# scripts stay linked below (transition) — the TS thin-delegation verbs shell
# out to them until the retire phase.
echo "  building site-manager (tsc via nix-build)..."
gcroots="${TAPPAAS_GCROOTS:-${HOME}/.tappaas-gcroots}"; mkdir -p "${gcroots}"
# --out-link registers a nix GC root so nix-collect-garbage cannot delete the
# build output out from under the ~/bin symlink (was --no-out-link => dangling).
out="$( cd "${here}" && nix-build -A default default.nix --out-link "${gcroots}/site-manager" )"
[[ -x "${out}/bin/site-manager" ]] || { echo "  ERROR: build did not produce site-manager" >&2; exit 1; }
ln -sfn "${out}/bin/site-manager" "${bin}/site-manager"
echo "  linked ${bin}/site-manager -> ${out}/bin/site-manager"

for f in "${here}"/*.sh; do
    b="$(basename "${f}")"
    case "${b}" in install.sh|update.sh|test.sh|validate.sh) continue ;; esac
    # chmod the resolved source (chmod follows symlinks; the alias points at a
    # repo file, the target may be read-only /etc/static on NixOS).
    chmod +x "$(readlink -f "${f}")"
    ln -sfn "${f}" "${bin}/${b}"
    echo "  linked ${bin}/${b}"
done
