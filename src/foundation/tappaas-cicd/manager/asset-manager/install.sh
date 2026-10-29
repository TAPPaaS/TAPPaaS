#!/usr/bin/env bash
# asset-manager install — build the TS bin and link it into ~/bin, with
# position-manager and rack-manager, its old names, beside it for one release
# (ADR-035 P2).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
mkdir -p "${bin}"

. "${here}/../../lib/component-install-lib.sh"
build_and_link_nix_component "${here}" "asset-manager" asset-manager position-manager rack-manager
