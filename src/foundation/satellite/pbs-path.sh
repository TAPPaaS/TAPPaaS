#!/usr/bin/env bash
#
# TAPPaaS satellite: the path from the Site's nodes to a PBS on it (ADR-010 §8.4.3)
#
# Called by the backup module whenever this satellite is the Site's PBS Host
# (pbs_host_path_ensure: a PBS Host's module may ship this script), and by the
# satellite's own update to keep it converged. `open`: its DNS entry at the
# tunnel end, an OPNsense rule mgmt -> <tunnel end>:8007, and the satellite's
# tunnel and firewall admitting the nodes to :8007 only. `close`: the reverse.
#
# Usage: ./pbs-path.sh <instance> open|close
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. /home/tappaas/bin/common-install-routines.sh
. "${HERE}/lib/satellite-lib.sh"

sat_load "${1:?usage: ./pbs-path.sh <instance> open|close}"
case "${2:-}" in
    open|close) sat_pbs_path "$2" ;;
    *) die "usage: ./pbs-path.sh <instance> open|close" ;;
esac
