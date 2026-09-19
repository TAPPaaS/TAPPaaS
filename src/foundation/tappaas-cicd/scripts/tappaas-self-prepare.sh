#!/usr/bin/env bash
# tappaas-self-prepare.sh — the mothership's pull + relink + builds, before the sweep (ADR-017 D3).
#
# Second ExecStartPre line of update-tappaas.service, run as tappaas inside the
# unit's sandbox. It:
#   1. claims the one-shot request site-manager update wrote (D4):
#      config/.update-request.json → $RUNTIME_DIRECTORY/request.json, so the
#      request is consumed by exactly this run; one older than 10 min is dropped;
#   2. runs refresh-control-plane.sh (pull, hold-aware #653; relink ~/bin; builds)
#      and maps its exit code: 0 refreshed, 10 stale (non-fatal, #595),
#      12 a repository did not sync → fatal, 1 → fatal;
#   3. runs the config migrations the refresh just pulled (ADR-025 D2, #652);
#   4. leaves $RUNTIME_DIRECTORY/prepared and control-plane for update-tappaas.
# A non-zero exit stops the unit before the rebuild and the sweep; OnFailure
# then mails the site owner (#651), naming the stage from config/.update-stage.
#
# Environment: RUNTIME_DIRECTORY (systemd), TAPPAAS_CONFIG_DIR,
#              TAPPAAS_REFRESH_CMD / TAPPAAS_MIGRATE_CMD (tests)

set -euo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG_DIR="${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}"
RUN_DIR="${RUNTIME_DIRECTORY:-/run/update-tappaas}"
REFRESH="${TAPPAAS_REFRESH_CMD:-${_here}/refresh-control-plane.sh}"
MIGRATE="${TAPPAAS_MIGRATE_CMD:-${_here}/run-migrations.sh}"
REQUEST="${CONFIG_DIR}/.update-request.json"
MAX_REQUEST_AGE=600

# shellcheck source=../lib/common-install-routines.sh
. "$(dirname "${_here}")/lib/common-install-routines.sh"
echo prepare > "${CONFIG_DIR}/.update-stage"
mkdir -p "${RUN_DIR}"

# ── 1. the request ───────────────────────────────────────────────────
if [[ -f "${REQUEST}" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "${REQUEST}") ))
    if (( age > MAX_REQUEST_AGE )); then
        warn "discarding a request written ${age}s ago (older than ${MAX_REQUEST_AGE}s): $(tr -d '\n' < "${REQUEST}")"
        rm -f "${REQUEST}"
    else
        mv -f "${REQUEST}" "${RUN_DIR}/request.json"
        debug "operator request: $(jq -c . "${RUN_DIR}/request.json" 2>/dev/null || echo unreadable)"
    fi
fi
if [[ "${TRIGGER_UNIT:-}" == "update-tappaas.timer" && -f "${RUN_DIR}/request.json" ]]; then
    # The timer's run is the scheduled pass; a request it happened to claim
    # belongs to an operator start and is not applied here.
    warn "ignoring an operator request picked up by the timer's run"
    rm -f "${RUN_DIR}/request.json"
fi
if [[ -f "${RUN_DIR}/request.json" ]] && [[ "$(jq -r '.noGitPull == true' "${RUN_DIR}/request.json" 2>/dev/null)" == "true" ]]; then
    export TAPPAAS_NO_GIT_PULL=1
fi

# ── 2. refresh ───────────────────────────────────────────────────────
rc=0
"${REFRESH}" || rc=$?
case "${rc}" in
    0)  state=refreshed ;;
    10) state=stale; warn "some components failed to build — their bins are STALE; the sweep continues" ;;
    12) fatal "a repository did not sync and holds no pull hold — no rebuild, no sweep on stale tooling"
        exit 1 ;;
    *)  fatal "refresh-control-plane.sh failed (rc ${rc}) — no rebuild, no sweep"
        exit 1 ;;
esac

# ── 3. config migrations (ADR-025 D2) ────────────────────────────────
# Here and nowhere else: the migrations are the ones the refresh above just
# pulled, and this is the last point before the rebuild and before the sweep
# reaches its first module. A failure stops the unit, so the site stays on the
# old code with a config that is untouched or restorable (D5).
echo migrate > "${CONFIG_DIR}/.update-stage"
if ! TAPPAAS_CONFIG_DIR="${CONFIG_DIR}" "${MIGRATE}"; then
    fatal "a config migration failed — no rebuild, no sweep"
    exit 1
fi

# ── 4. hand over ─────────────────────────────────────────────────────
echo "${state}" > "${RUN_DIR}/control-plane"
: > "${RUN_DIR}/prepared"
echo rebuild > "${CONFIG_DIR}/.update-stage"
debug "tappaas-self-prepare: control plane ${state}"
