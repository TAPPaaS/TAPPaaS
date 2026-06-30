#!/usr/bin/env bash
#
# TAPPaaS satellite module install (ADR-010)
#
# The satellite is an EXTERNAL host and is OPERATOR-DRIVEN — it is NOT installed
# by the mandatory foundation chain (rest-of-foundation.sh) and does NOT go through
# the cluster:vm hook. This script is the module-contract entry point; it delegates
# to `satellite-manager`. See INSTALL.md for the full runbook.
#
# Usage: ./install.sh <name>      (name = the satellite-<name>.json config)
#
set -euo pipefail

NAME="${1:-}"
if [[ -z "${NAME}" ]]; then
    cat << EOF
The satellite is optional and operator-driven. To install one:

  1. Read   src/foundation/satellite/INSTALL.md
  2. Copy   src/foundation/satellite/satellite.json -> ~/config/satellite-<name>.json  and edit it
  3. Run    satellite-manager install <name>

(re-run this script with a <name> argument to delegate to satellite-manager.)
EOF
    exit 0
fi

command -v satellite-manager >/dev/null 2>&1 \
    || { echo "satellite-manager not on PATH — run the satellite-manager component install first" >&2; exit 1; }

exec satellite-manager install "${NAME}"
