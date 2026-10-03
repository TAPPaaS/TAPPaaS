#!/usr/bin/env bash
#
# ready.sh — readiness probe for logging (#468, #700).
#
# Exits 0 once Loki can serve, non-zero while it is still starting. Polled by
# wait_for_module_ready() before the update's pre-update gate and after its
# apply, so it must be cheap, side-effect free, and quick to fail.
#
# Why this exists: the guest's systemd reports "running" seconds after boot,
# but Loki answers /ready only once its ring has settled, and holds no stream
# until Alloy has shipped the first journal lines. The pre-update gate asked in
# that window on 2026-09-21 and skipped the module's update for the night;
# forty minutes later the same checks passed (#700).
#
# The two conditions are test.sh's checks 2 and 8, in the same form, so the
# probe and the gate it protects stay in step.
#
# Usage: ready.sh <module> <vm-ip>

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# $1 is the module name, part of the hook contract but unused here.
VM_IP="${2:-}"

if [[ -z "${VM_IP}" ]]; then
    echo "Usage: ${SCRIPT_NAME} <module> <vm-ip>" >&2
    exit 2
fi

# Both in ONE ssh round-trip; --max-time well under the 5 s poll interval.
ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o BatchMode=yes \
    "tappaas@${VM_IP}" '
        case "$(curl -s --max-time 4 http://127.0.0.1:3100/ready)" in *ready*) ;; *) exit 1 ;; esac
        n=$(curl -s --max-time 4 --get http://127.0.0.1:3100/loki/api/v1/label/job/values | jq -r ".data | length") || exit 1
        [ "${n:-0}" -ge 1 ]
    ' >/dev/null 2>&1
