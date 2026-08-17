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
# post-update tests needed — they need /health to answer. ANY HTTP status
# counts, including the 401 the endpoint returns without an API key, which is
# exactly what test.sh already scores as healthy (test.sh Test 2).
#
# The port is held here in the same literal form as test.sh's health check, so
# the probe and the test it protects stay in step.
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

# curl without --fail exits 0 on any response, so a 401 (no API key) counts as
# ready; only a connection failure or timeout is "still starting".
ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
    "tappaas@${VM_IP}" \
    "curl -s -o /dev/null --max-time 5 http://localhost:${LITELLM_PORT}/health" \
    >/dev/null 2>&1
