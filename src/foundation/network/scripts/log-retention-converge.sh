#!/usr/bin/env bash
# TAPPaaS network — how long the firewall keeps its own logs (ADR-050)
#
# OPNsense keeps /var/log in a RAM disk and prunes it by "days to preserve"
# (31 by default) in its nightly log_archive. The filter log alone grows 70–90
# MB a day (hrossen, 2026-11-12): after six days /var/log held 740 MB of a 4 GB
# firewall with no swap, Suricata was killed for memory, and unbound had been
# before. The lines are in Loki already (logging:logs, 30 days and the
# security streams 90 or 180), so the firewall keeps two days of them; on a
# site without the logging module its copy is the only one, and it keeps seven.
#
# What it converges, every run (idempotent), through the OPNsense API from the
# mothership: the days to preserve; when they change, the archive runs at once
# so the memory comes back now, not at night.
#
# Usage: log-retention-converge.sh [--check]   (--check: report, change nothing)
set -euo pipefail
# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. "${TAPPAAS_BIN:-/home/tappaas/bin}/common-install-routines.sh"

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }
CHECK=0
case "${1:-}" in
    --check) CHECK=1 ;;
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) usage >&2; exit 2 ;;
esac

FW="${FIREWALL_FQDN:-firewall.mgmt.internal}"
CONFIG_DIR="${CONFIG_DIR:-/home/tappaas/config}"
OPN_CREDS="${HOME}/.opnsense-credentials.txt"
[[ -r "${OPN_CREDS}" ]] || die "no OPNsense API credentials (${OPN_CREDS})"
OPN_AUTH="$(grep '^key=' "$OPN_CREDS" | cut -d= -f2-):$(grep '^secret=' "$OPN_CREDS" | cut -d= -f2-)"
API="https://${FW}:8443/api/syslog"

# Shipped to Loki (logging deployed): two days; the only copy: seven.
want=7
[[ -f "${CONFIG_DIR}/logging.json" ]] && want=2

have="$(curl -ksS --max-time 30 -u "$OPN_AUTH" "${API}/settings/get" | jq -r '.syslog.general.maxpreserve // empty')"
[[ "${have}" =~ ^[0-9]+$ ]] || die "cannot read the firewall's log retention"
if [[ "${have}" == "${want}" ]]; then
    echo "  firewall logs: kept ${want} days"
    exit 0
fi
if [[ ${CHECK} -eq 1 ]]; then
    info "  would keep the firewall's logs ${want} days, not ${have}"
    exit 0
fi
curl -ksS --max-time 30 -u "$OPN_AUTH" -X POST "${API}/settings/set" -H 'Content-Type: application/json' \
    -d "{\"syslog\":{\"general\":{\"maxpreserve\":\"${want}\"}}}" | jq -e '.result == "saved"' >/dev/null \
    || die "could not set the firewall's log retention"
curl -ksS --max-time 60 -u "$OPN_AUTH" -X POST "${API}/service/reconfigure" -d '{}' >/dev/null || true
# Prune now: the archive is what deletes, and it otherwise runs at night.
ssh -n -o BatchMode=yes -o ConnectTimeout=10 "root@${FW}" "/usr/local/opnsense/scripts/syslog/log_archive" >/dev/null \
    || warn "  the archive did not run now; the nightly one prunes"
used="$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "root@${FW}" "df -m /var/log | tail -1" 2>/dev/null | awk '{print $3}')"
info "  ${GN}✓${CL} the firewall keeps its logs ${want} days (was ${have})${used:+; /var/log now ${used} MB}"
