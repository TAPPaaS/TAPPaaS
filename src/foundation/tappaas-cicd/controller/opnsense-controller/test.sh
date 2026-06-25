#!/usr/bin/env bash
# opnsense-controller/test.sh — build the package env (nix), then run the
# co-located Python unit tests (stdlib `unittest`) against it. Mirrors
# identity-controller/test.sh.
#
# These are OFFLINE unit tests (mocked OPNsense API) for the zone / rules / dhcp /
# caddy / acme / dns managers. The LIVE opnsense plane (real rules, NAT, split-
# horizon, connectivity) is exercised by network/test.sh — this wrapper closes the
# gap where these unit tests were not run by the component contract at all.
#
# Exit non-zero on any failure.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== building opnsense-controller (nix) =="
( cd "${here}" && nix-build -A default default.nix >/dev/null )

py="${here}/result/bin/python"
if [ ! -x "${py}" ]; then
    echo "[Error] python not found in build result: ${py}" >&2
    exit 1
fi

echo "== unit tests (python -m unittest discover src/test) =="
PYTHONPATH="${here}/src" "${py}" -m unittest discover -s "${here}/src/test" -v
