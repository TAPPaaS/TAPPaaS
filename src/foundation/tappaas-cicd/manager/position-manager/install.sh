#!/usr/bin/env bash
# position-manager install — build the TS bin and link it into ~/bin, with
# rack-manager, its old name, beside it for one release (ADR-035 P2).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
mkdir -p "${bin}"

. "${here}/../../lib/component-install-lib.sh"
build_and_link_nix_component "${here}" "position-manager" position-manager rack-manager
