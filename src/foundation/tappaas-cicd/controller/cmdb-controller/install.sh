#!/usr/bin/env bash
# install.sh — build cmdb-controller and link bin/cmdb-controller (the
# service) and bin/cmdb (the CLI) into ~/bin (idempotent).
#
# cmdb.service (tappaas-cicd.nix) runs ~/bin/cmdb-controller serve; its path
# unit starts it once the bin exists. A new build is taken up by restarting it
# here: the service holds no state of its own (the store is PostgreSQL), and a
# reporter that finds it restarting spools its report (lib/ts/src/cmdb.ts).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
. "${here}/../../lib/component-install-lib.sh"
before="$(readlink "${bin}/cmdb-controller" 2>/dev/null || true)"
build_and_link_nix_component "${here}" "cmdb-controller" cmdb-controller cmdb
after="$(readlink "${bin}/cmdb-controller" 2>/dev/null || true)"
if [[ "${before}" != "${after}" ]] && systemctl is-active --quiet cmdb.service 2>/dev/null; then
    sudo -n systemctl try-restart cmdb.service 2>/dev/null \
        || echo "  cmdb-controller runs the previous build until: sudo systemctl restart cmdb" >&2
fi
