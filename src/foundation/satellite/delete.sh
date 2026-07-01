#!/usr/bin/env bash
#
# TAPPaaS satellite module delete (ADR-010)
#
# Contract file called by delete-module.sh (if present). For the satellite this
# is a DECOMMISSION: it delegates to `satellite-manager remove`, which tears down
# the OPNsense tunnel side (WireGuard server/peer), the edge/admin zones + rules,
# and reverts DNS. Destroying the external VPS itself stays MANUAL (the operator's
# cloud account) unless the Tier-B hcloud API token is configured — §5.6.
#
# Usage: ./delete.sh <name> [--dry-run]
#
set -euo pipefail

NAME="${1:-}"
if [[ -z "${NAME}" ]]; then
    echo "usage: ./delete.sh <name> [--dry-run]   (name = the satellite-<name>.json)" >&2
    exit 1
fi
command -v satellite-manager >/dev/null 2>&1 \
    || { echo "satellite-manager not on PATH — nothing to decommission" >&2; exit 1; }
exec satellite-manager remove "$@"
