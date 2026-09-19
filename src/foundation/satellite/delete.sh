#!/usr/bin/env bash
#
# TAPPaaS satellite module decommission (ADR-010 §8.4.5)
#
# Run only by `module-manager module delete <instance> --decommission`; a plain
# `delete` unregisters a machine and never calls this. Takes the Site's side of
# the satellite down — the OPNsense peer and tunnel server, and the edge rules
# when no other satellite needs them. The machine itself is never touched:
# destroying it is the operator's, in the provider's console.
#
# Usage: ./delete.sh <instance>
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. /home/tappaas/bin/common-install-routines.sh
. "${HERE}/lib/satellite-lib.sh"

sat_load "${1:?usage: ./delete.sh <instance>}"
sat_decommission
