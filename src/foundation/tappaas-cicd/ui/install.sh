#!/usr/bin/env bash
# install.sh — build the console (backend and front end) and link bin/console
# and bin/tappaas (`tappaas ask`) into ~/bin (idempotent).
# tappaas-console.service (tappaas-cicd.nix) runs
# ~/bin/console serve; its path unit starts it once the bin exists, and a new
# build is taken up by restarting it here.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
. "${here}/../lib/component-install-lib.sh"
before="$(readlink "${bin}/console" 2>/dev/null || true)"
build_and_link_nix_component "${here}" "console" console tappaas
after="$(readlink "${bin}/console" 2>/dev/null || true)"
if [[ "${before}" != "${after}" ]] && systemctl is-active --quiet tappaas-console.service 2>/dev/null; then
    sudo -n systemctl try-restart tappaas-console.service 2>/dev/null \
        || echo "  the console runs the previous build until: sudo systemctl restart tappaas-console" >&2
fi
