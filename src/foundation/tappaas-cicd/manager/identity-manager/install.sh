#!/usr/bin/env bash
# install.sh — build + link the identity-manager component (compiled-component).
#
# identity-manager is a TypeScript reconcile engine (ADR-007 P1, S2b-3). It is
# built with Nix (tsc, no node_modules) into result/bin/identity-manager, then
# linked onto PATH alongside the bash entry point this component still owns:
#
#   identity-manager         -> ~/bin/identity-manager        (the TS reconcile CLI)
#   validate.sh              -> ~/bin/validate-identities.sh  (project-wide name)
#
# and, for ONE stable cycle after #628 renamed people-manager, the old names:
#
#   people-manager-alias.sh  -> ~/bin/people-manager          (warns, runs identity-manager)
#   validate.sh              -> ~/bin/validate-people.sh
#
# The alias link is not optional: without it the old ~/bin/people-manager keeps
# pointing at the last people-manager Nix build, which would go on running OLD
# code against the renamed config/identities/.
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
build_and_link_nix_component "${here}" "identity-manager"

# ── link the bash entry points ─────────────────────────────────────────
link_as() {
    # $1 = source basename, $2 = link name in bin
    local src="${here}/$1" name="$2"
    [[ -f "${src}" ]] || { echo "  skip: ${src} not found"; return 0; }
    chmod +x "${src}"
    ln -sfn "${src}" "${bin}/${name}"
    echo "  linked ${bin}/${name}"
}

link_as validate.sh             validate-identities.sh
link_as validate.sh             validate-people.sh        # alias, one stable cycle (#628)
link_as people-manager-alias.sh people-manager            # alias, one stable cycle (#628)

# user-setup.sh is retired (ADR-007 refactor Phase 8.2) — the TS
# `identity-manager bootstrap` verb seeds the minimal Identity domain now. Drop a
# stale link from older installs.
rm -f "${bin}/user-setup.sh"
