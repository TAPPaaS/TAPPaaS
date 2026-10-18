#!/usr/bin/env bash
# install.sh — build the console (backend and front end) and link bin/console
# and bin/tappaas (`tappaas ask`) into ~/bin (idempotent).
# tappaas-console.service (tappaas-cicd.nix) runs
# ~/bin/console serve; its path unit starts it once the bin exists, and a new
# build is taken up by restarting it here — unless a job runs: this script is
# reached from `module-manager update tappaas-cicd` (pre-update.sh →
# refresh-control-plane.sh), which is itself a console job, and a restart then
# would kill that job. So the console is asked (GET /api/v1/jobs on loopback,
# a read); if it is busy the restart is deferred: `restart-pending` is left in
# its state directory and the console exits into the new build the moment its
# runner is idle (jobs.ts takeRestartMarker; the unit's Restart=always).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
state_dir="${CONSOLE_STATE_DIR:-/var/lib/tappaas/console}"
console_url="${CONSOLE_URL:-http://127.0.0.1:9097}"
. "${here}/../lib/component-install-lib.sh"
before="$(readlink "${bin}/console" 2>/dev/null || true)"
build_and_link_nix_component "${here}" "console" console tappaas
after="$(readlink "${bin}/console" 2>/dev/null || true)"
if [[ "${before}" != "${after}" ]] && systemctl is-active --quiet tappaas-console.service 2>/dev/null; then
    # "true", "false", or empty when the console does not answer (then restart as before).
    busy="$(curl -fsS --max-time 5 "${console_url}/api/v1/jobs" 2>/dev/null | jq -r '.data.busy // empty' 2>/dev/null || true)"
    if [[ "${busy}" == "true" ]] && touch "${state_dir}/restart-pending" 2>/dev/null; then
        echo "  the console runs a job: it restarts into the new build when its runner is idle (${state_dir}/restart-pending)" >&2
    else
        sudo -n systemctl try-restart tappaas-console.service 2>/dev/null \
            || echo "  the console runs the previous build until: sudo systemctl restart tappaas-console" >&2
    fi
fi
