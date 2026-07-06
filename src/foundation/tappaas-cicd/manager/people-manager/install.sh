#!/usr/bin/env bash
# install.sh — build + link the people-manager component (compiled-component).
#
# people-manager is a TypeScript reconcile engine (ADR-007 P1, S2b-3). It is
# built with Nix (tsc, no node_modules) into result/bin/people-manager, then
# linked onto PATH alongside the bash entry point this component still owns:
#
#   people-manager  -> ~/bin/people-manager       (the TS reconcile CLI)
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
# Shared build+link helper (lib/ doctrine: scaffolding lives once, sourced).
. "${here}/../../lib/component-install-lib.sh"
build_and_link_nix_component "${here}" "people-manager"

# ── link the bash entry points ─────────────────────────────────────────
link_as() {
    # $1 = source basename, $2 = link name in bin
    local src="${here}/$1" name="$2"
    [[ -f "${src}" ]] || { echo "  skip: ${src} not found"; return 0; }
    chmod +x "${src}"
    ln -sfn "${src}" "${bin}/${name}"
    echo "  linked ${bin}/${name}"
}

link_as validate.sh    validate-people.sh

# user-setup.sh is retired (ADR-007 refactor Phase 8.2) — the TS
# `people-manager bootstrap` verb seeds the minimal People domain now. Drop a
# stale link from older installs.
rm -f "${bin}/user-setup.sh"
