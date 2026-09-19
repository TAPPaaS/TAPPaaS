#!/usr/bin/env bash
#
# TAPPaaS satellite lockdown (ADR-010 §8.4.4)
#
# Run by `module-manager module modify <instance> --lockdown`. Makes a managed
# satellite the Site's off-site backup vault: it pulls the Site's PBS through a
# read-only login, patches itself, and — the last step — the mothership's key is
# removed, so nothing at home can log in to it or delete its copy. Recorded
# `management: unmanaged`; the sweep skips it from then on. There is no unlock:
# returning it to managed needs your operator key, on the machine itself.
#
# Refused when the satellite is the Site's PBS Host, when the Site has no PBS of
# its own, and when no operator key is recorded.
#
# Usage: ./lockdown.sh <instance>
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. /home/tappaas/bin/common-install-routines.sh
. "${HERE}/lib/satellite-lib.sh"

sat_load "${1:?usage: ./lockdown.sh <instance>}"
sat_lockdown
