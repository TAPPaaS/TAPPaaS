#!/usr/bin/env bash
# install.sh — build + link the network-manager component (compiled-component).
#
# network-manager is a TypeScript owner + orchestrator (ADR-007 P4 / ADR-008):
# it owns zones.json (CRUD + delta) and reconciles all four planes by calling
# the plane-controller bins (zone-manager, proxmox-manager, switch-controller,
# ap-manager). It is built with Nix (tsc, no node_modules) into
# result/bin/network-manager, then linked onto PATH.
#
# The legacy bash entry points (zone-reconcile / zone-controller / zone-state)
# are NOT retired yet (a later chunk does that), so they are still linked here
# alongside the new TS bin. Idempotent.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
mkdir -p "${bin}"

# ── build the TypeScript CLI via Nix ──────────────────────────────────
echo "  building network-manager (tsc via nix-build)..."
( cd "${here}" && nix-build -A default default.nix --no-out-link >/tmp/network-manager-build.path )
out="$(cat /tmp/network-manager-build.path)"
[[ -x "${out}/bin/network-manager" ]] || { echo "  ERROR: build did not produce network-manager" >&2; exit 1; }
ln -sfn "${out}/bin/network-manager" "${bin}/network-manager"
echo "  linked ${bin}/network-manager -> ${out}/bin/network-manager"

# ── link the legacy bash entry programs (not retired yet) ─────────────
# zone-reconcile + the *.sh tools, EXCEPT the verb scripts and the one-shot
# migration helper (migrate-zone-keys-*), which are not on-PATH tools. (The old
# apply-zones-merge.sh was retired in favour of `network-manager zones-merge`.)
link_bash() {
    local src="$1" name="$2"
    [ -f "${src}" ] || { echo "  skip: ${src} not found"; return 0; }
    [ -x "${src}" ] || chmod +x "${src}"
    ln -sfn "${src}" "${bin}/${name}"
    echo "  linked ${bin}/${name}"
}

link_bash "${here}/zone-reconcile"      zone-reconcile
link_bash "${here}/zone-state.sh"       zone-state.sh
link_bash "${here}/zone-controller.sh"  zone-controller
