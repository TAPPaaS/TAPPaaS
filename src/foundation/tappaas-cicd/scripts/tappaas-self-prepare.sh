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
#   3. leaves $RUNTIME_DIRECTORY/prepared and control-plane for update-tappaas.
# A non-zero exit stops the unit before the rebuild and the sweep; OnFailure
# then mails the site owner (#651), naming the stage from config/.update-stage.
#
# Environment: RUNTIME_DIRECTORY (systemd), TAPPAAS_CONFIG_DIR, TAPPAAS_REFRESH_CMD (tests)

set -euo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG_DIR="${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}"
RUN_DIR="${RUNTIME_DIRECTORY:-/run/update-tappaas}"
REFRESH="${TAPPAAS_REFRESH_CMD:-${_here}/refresh-control-plane.sh}"
REQUEST="${CONFIG_DIR}/.update-request.json"
MAX_REQUEST_AGE=600

log() { echo "tappaas-self-prepare: $*"; }
echo prepare > "${CONFIG_DIR}/.update-stage"
mkdir -p "${RUN_DIR}"

# ── 1. the request ───────────────────────────────────────────────────
if [[ -f "${REQUEST}" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "${REQUEST}") ))
    if (( age > MAX_REQUEST_AGE )); then
        log "WARNING: discarding a request written ${age}s ago (older than ${MAX_REQUEST_AGE}s): $(tr -d '\n' < "${REQUEST}")"
        rm -f "${REQUEST}"
    else
        mv -f "${REQUEST}" "${RUN_DIR}/request.json"
        log "operator request: $(jq -c . "${RUN_DIR}/request.json" 2>/dev/null || echo unreadable)"
    fi
fi
if [[ -f "${RUN_DIR}/request.json" ]] && [[ "$(jq -r '.noGitPull // false' "${RUN_DIR}/request.json" 2>/dev/null)" == "true" ]]; then
    export TAPPAAS_NO_GIT_PULL=1
fi

# ── 2. refresh ───────────────────────────────────────────────────────
rc=0
"${REFRESH}" || rc=$?
case "${rc}" in
    0)  state=refreshed ;;
    10) state=stale; log "WARNING: some components failed to build — their bins are STALE; the sweep continues (#595)" ;;
    12) log "FATAL: a repository did not sync and holds no pull hold — no rebuild, no sweep on stale tooling (ADR-017 D3)"
        exit 1 ;;
    *)  log "FATAL: refresh-control-plane.sh failed (rc ${rc}) — no rebuild, no sweep"
        exit 1 ;;
esac

# ── 3. hand over ─────────────────────────────────────────────────────
echo "${state}" > "${RUN_DIR}/control-plane"
: > "${RUN_DIR}/prepared"
echo rebuild > "${CONFIG_DIR}/.update-stage"
log "control plane ${state}"
