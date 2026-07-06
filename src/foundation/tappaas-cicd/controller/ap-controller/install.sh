#!/usr/bin/env bash
# Link this component's CLI entry programs into ~/bin (idempotent).
# Entries = every executable regular file here except verb scripts, README, test-*.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
# Shared link helper (lib/ doctrine: scaffolding lives once, sourced).
. "${here}/../../lib/component-install-lib.sh"
link_component_executables "${here}"
# Compat alias: ap-manager -> ap-controller (drop at a later cutover).
ln -sfn "${here}/ap-controller" "${bin}/ap-manager"; echo "  linked ${bin}/ap-manager (alias)"
