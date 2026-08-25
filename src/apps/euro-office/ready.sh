#!/usr/bin/env bash
#
# ready.sh — readiness probe for euro-office (#468).
#
# Exits 0 once the module can actually serve, non-zero while it is still
# starting. Polled by wait_for_module_ready() after a post-update reboot, so it
# must be cheap, side-effect free, and quick to fail.
#
# Why this exists instead of relying on the generic port probe: euro-office
# declares exactly one port, 80, and nginx binds it almost immediately — long
# before the DocumentServer backend behind it answers. "Listening" is therefore
# satisfied by the very component that returns the 502, so the generic probe
# reports ready while /healthcheck is still failing. The post-update run then
# tested a module that was still booting and failed a healthy one on two
# consecutive nights (2026-08-24, 2026-08-25), each time passing again on a
# later warm run.
#
# The endpoints and the exact-200 comparison are held in the same form as
# test.sh Test 4b, so the probe and the test it protects stay in step: 502 is
# precisely the "backend not up yet" state that test scores as a failure, so
# ANY-status would not do here (unlike litellm, whose 401 is a healthy answer).
#
# Usage: ready.sh <module> <vm-ip>

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# $1 is the module name, part of the hook contract but unused here — this probe
# is specific to euro-office, so the endpoints below are already the right ones.
# $2 is the VM's address, passed by wait_for_module_ready so the probe does not
# depend on DNS being settled straight after a reboot.
VM_IP="${2:-}"

if [[ -z "${VM_IP}" ]]; then
    echo "Usage: ${SCRIPT_NAME} <module> <vm-ip>" >&2
    exit 2
fi

# Both endpoints in ONE ssh round-trip, so a slow start costs one connection per
# poll rather than two. --max-time is shorter than test.sh's 15s because this is
# polled every 5s: a hung request should fail the poll, not stall it.
ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
    "tappaas@${VM_IP}" '
        hc=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
             http://localhost/healthcheck) || exit 1
        api=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
              http://localhost/web-apps/apps/api/documents/api.js) || exit 1
        [ "$hc" = "200" ] && [ "$api" = "200" ]
    ' >/dev/null 2>&1
