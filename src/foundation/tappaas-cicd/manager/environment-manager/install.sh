#!/usr/bin/env bash
# Link this component's CLI entry scripts into ~/bin (idempotent).
# Entries = every *.sh here except the verb scripts.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
mkdir -p "${bin}"

# ── build + link the TypeScript CLI via Nix (ADR-007 #3) ──────────────
# Shared build+link helper (lib/ doctrine: scaffolding lives once, sourced).
. "${here}/../../lib/component-install-lib.sh"
build_and_link_nix_component "${here}" "environment-manager"

for f in "${here}"/*.sh; do
    b="$(basename "${f}")"
    case "${b}" in install.sh|update.sh|test.sh|validate.sh) continue ;; esac
    chmod +x "${f}"; ln -sfn "${f}" "${bin}/${b}"; echo "  linked ${bin}/${b}"
done

# validate-environment.sh is retired — the TS `environment-manager validate`
# verb is the schema + reference gate now. Drop a stale link from older installs.
rm -f "${bin}/validate-environment.sh"
