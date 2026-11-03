#!/usr/bin/env bash
# ca-manager install — build the TS bin and link it into ~/bin (ADR-043).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
mkdir -p "${bin}"

. "${here}/../../lib/component-install-lib.sh"
build_and_link_nix_component "${here}" "ca-manager"
