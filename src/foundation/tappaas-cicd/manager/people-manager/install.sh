#!/usr/bin/env bash
# install.sh — build + link the people-manager component (compiled-component).
#
# people-manager is a TypeScript reconcile engine (ADR-007 P1, S2b-3). It is
# built with Nix (tsc, no node_modules) into result/bin/people-manager, then
# linked onto PATH alongside the bash entry points this component still owns:
#
#   people-manager  -> ~/bin/people-manager       (the TS reconcile CLI)
#   user-setup.sh   -> ~/bin/user-setup.sh         (bootstrap copy of minimal-org)
#   validate.sh     -> ~/bin/validate-people.sh    (project-wide name)
#
# The reconcile engine calls the identity-controller PRIMITIVES via the
# `authentik-manager` bin (must also be on PATH); it does NOT speak Authentik
# HTTP itself. Idempotent.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
mkdir -p "${bin}"

# ── build the TypeScript CLI via Nix ──────────────────────────────────
echo "  building people-manager (tsc via nix-build)..."
gcroots="${TAPPAAS_GCROOTS:-${HOME}/.tappaas-gcroots}"; mkdir -p "${gcroots}"
# --out-link registers a nix GC root so nix-collect-garbage cannot delete the
# build output out from under the ~/bin symlink (was --no-out-link => dangling).
out="$( cd "${here}" && nix-build -A default default.nix --out-link "${gcroots}/people-manager" )"
[[ -x "${out}/bin/people-manager" ]] || { echo "  ERROR: build did not produce people-manager" >&2; exit 1; }
ln -sfn "${out}/bin/people-manager" "${bin}/people-manager"
echo "  linked ${bin}/people-manager -> ${out}/bin/people-manager"

# ── link the bash entry points ─────────────────────────────────────────
link_as() {
    # $1 = source basename, $2 = link name in bin
    local src="${here}/$1" name="$2"
    [[ -f "${src}" ]] || { echo "  skip: ${src} not found"; return 0; }
    chmod +x "${src}"
    ln -sfn "${src}" "${bin}/${name}"
    echo "  linked ${bin}/${name}"
}

link_as user-setup.sh user-setup.sh
link_as validate.sh    validate-people.sh
