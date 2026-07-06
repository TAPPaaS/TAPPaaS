#!/usr/bin/env bash
# Link this component's CLI entry programs into ~/bin (idempotent).
# Entries = every executable regular file here except verb scripts, README, test-*.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
# Shared link helper (lib/ doctrine: scaffolding lives once, sourced).
. "${here}/../../lib/component-install-lib.sh"
link_component_executables "${here}"
