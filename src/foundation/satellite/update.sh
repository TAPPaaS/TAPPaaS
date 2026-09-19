#!/usr/bin/env bash
#
# TAPPaaS satellite module update (ADR-010 §8.4.2)
#
# A managed satellite (the default) is a Debian machine the sweep patches like
# any other: its OPNsense edge rules and DNS entry are re-ensured, the nodes'
# path to it opened exactly while it is the Site's PBS Host (§8.4.3), then the
# debianhost update runs against it (apt full-upgrade; a reboot only when
# authorized, else DEFERRED). A locked-down satellite (`management: unmanaged`, §8.4.4) patches
# itself and admits no login from home: there is nothing to do, and the sweep
# does not call this for it.
#
# Usage: ./update.sh <instance>
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. /home/tappaas/bin/common-install-routines.sh
. "${HERE}/lib/satellite-lib.sh"

sat_load "${1:?usage: ./update.sh <instance>}"
if [[ "${SAT_MGMT}" == unmanaged ]]; then
    info "${INSTANCE} is locked down (unmanaged): it patches itself; nothing to update from here"
    exit 0
fi
[[ -n "$(jq -r '.address // empty' "${SAT_CFG}")" ]] \
    || die "${INSTANCE} records no 'address' — a satellite from before ADR-010 §8.4 is converted by hand first (satellite/INSTALL.md, 'Converting an existing satellite')"
sat_edge_rules_ensure || warn "  OPNsense edge rules for ${SAT_ROLES} could not be ensured"
sat_dns_ensure || warn "  ${SAT_NAME}.${SAT_DNS_ZONE}.internal could not be registered at the tunnel end"
# The Site's PBS on it (ADR-010 §8.4.3): the nodes' path open exactly while it is.
if sat_is_pbs_host; then sat_pbs_path open; else sat_pbs_path close; fi
exec "${HERE}/../debianhost/update.sh" "${INSTANCE}"
