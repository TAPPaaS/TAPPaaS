#!/usr/bin/env bash
#
# ready.sh — readiness probe for litellm (#468).
#
# Exits 0 once the module can actually serve, non-zero while it is still
# starting. Polled by wait_for_module_ready() after a post-update reboot, so it
# must be cheap, side-effect free, and quick to fail.
#
# Why this exists instead of relying on the generic port probe: uvicorn binds
# :4000 slightly before it serves, and "listening" was never what the
# post-update tests needed.
#
# Why /health/readiness and not /health (#690): /health answers 401 as soon as
# uvicorn is up, which says nothing about the database behind it — and the admin
# API the models service drives (/key/list, /key/generate) needs that database.
# A provider restored from a snapshot therefore passed this probe seconds before
# refusing to mint a key. /health/readiness needs no credential and answers 200
# only once the DB is connected, so it gates what the callers actually do.
#
# Usage: ready.sh <module> <vm-ip>

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
readonly LITELLM_PORT=4000

# $1 is the module name, part of the hook contract but unused here — this probe
# is specific to litellm, so the port below is already the right one. $2 is the
# VM's address, passed by wait_for_module_ready so the probe does not depend on
# DNS being settled straight after a reboot.
VM_IP="${2:-}"

if [[ -z "${VM_IP}" ]]; then
    echo "Usage: ${SCRIPT_NAME} <module> <vm-ip>" >&2
    exit 2
fi

# --fail: anything but a 2xx is "still starting". While the DB is still coming up
# LiteLLM answers this endpoint with 503, which is exactly the state to wait out.
ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o BatchMode=yes \
    "tappaas@${VM_IP}" \
    "curl -sf -o /dev/null --max-time 5 http://localhost:${LITELLM_PORT}/health/readiness" \
    >/dev/null 2>&1
