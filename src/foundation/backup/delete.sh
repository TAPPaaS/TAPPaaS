#!/usr/bin/env bash
#
# TAPPaaS backup module — delete (DNS only, #672).
#
# Run by `module-manager delete <instance>` (delete-module.sh Step 4) while the
# instance's config still exists. It removes what the instance registered in
# DNS: its name — an alias on its Host's dnsmasq entry (#612) — and, through
# the guarded `dns-manager release`, the Host entry backup created for a
# machine Host. A cluster node's entry, a DHCP reservation and anything made by
# hand are never touched.
#
# Deliberately NOT here: the PBS itself, its datastore, its jobs and the PVE
# storage entry. Taking a PBS down is a decision with data in it, and has its
# own issue; deleting the instance only stops TAPPaaS naming it.
#
# Usage: delete.sh <instance>

set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MODULE_DIR

. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=lib/pbs-dns.sh disable=SC1091
. "${MODULE_DIR}/lib/pbs-dns.sh"

INSTANCE="$(pbs_instance "${1:-}")"
ZONE="$(get_config_value 'zone0' 'mgmt')"

pbs_dns_remove "${INSTANCE}" "${ZONE}" \
    || warn "  $(pbs_dns_name "${INSTANCE}" "${ZONE}") may still resolve — remove it with: dns-manager alias delete $(pbs_dns_name "${INSTANCE}" "${ZONE}")"
