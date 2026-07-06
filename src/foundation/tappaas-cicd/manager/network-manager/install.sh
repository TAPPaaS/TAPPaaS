#!/usr/bin/env bash
# install.sh — build + link the network-manager component (compiled-component).
#
# network-manager is a TypeScript owner + orchestrator (ADR-007 P4 / ADR-008):
# it owns zones.json (CRUD + delta) and reconciles all four planes by calling
# the plane-controller bins (zone-manager, proxmox-manager, switch-controller,
# ap-manager). It is built with Nix (tsc, no node_modules) into
# result/bin/network-manager, then linked onto PATH.
#
# The legacy zone-controller.sh / zone-state.sh bash entry points are RETIRED
# (ADR-007 Phase 7.5) — their verbs live natively in the TS bin
# (`network-manager add/delete/enable/disable/manual`). Only zone-reconcile is
# still linked alongside the new TS bin. Idempotent.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
mkdir -p "${bin}"

# ── build the TypeScript CLI via Nix ──────────────────────────────────
# Shared build+link helper (lib/ doctrine: scaffolding lives once, sourced).
. "${here}/../../lib/component-install-lib.sh"
build_and_link_nix_component "${here}" "network-manager"

# ── link the legacy bash entry programs (not retired yet) ─────────────
# zone-reconcile only. (apply-zones-merge.sh was retired in favour of
# `network-manager merge`; zone-controller.sh / zone-state.sh in favour of the
# TS zone lifecycle + state verbs — ADR-007 Phase 7.5.)
link_bash() {
    local src="$1" name="$2"
    [ -f "${src}" ] || { echo "  skip: ${src} not found"; return 0; }
    [ -x "${src}" ] || chmod +x "${src}"
    ln -sfn "${src}" "${bin}/${name}"
    echo "  linked ${bin}/${name}"
}

link_bash "${here}/zone-reconcile"      zone-reconcile

# Drop the retired symlinks so an upgraded install has no dangling ~/bin
# entries pointing at the deleted scripts.
rm -f "${bin}/zone-controller" "${bin}/zone-state.sh"
