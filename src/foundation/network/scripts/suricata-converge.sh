#!/usr/bin/env bash
# TAPPaaS network — Suricata on the firewall, alert only (ADR-050 D5)
#
# OPNsense's intrusion detection (Suricata) watches the WAN in PCAP mode: it
# alerts and never drops (operator decision, 2026-11-12: alert first; IPS on
# the WAN is a later step of its own). Its alerts go to syslog as eve JSON
# (program "suricata"), so the firewall's syslog forwarder takes them to Loki,
# where the network module's security rules read them.
#
# What it converges, every run (idempotent), through the OPNsense API from the
# mothership:
#   1. with the site's security monitoring on (site.json security.monitoring;
#      off on a small site): IDS enabled, PCAP mode, the WAN, eve to syslog;
#      off: IDS disabled — nothing else is touched;
#   2. the rule sets: threat categories of ET Open and abuse.ch (exploits,
#      malware and its command-and-control, phishing, known-bad addresses) —
#      not the policy, info, scan or hunting ones, which on a WAN are noise
#      (CrowdSec already bans scanners);
#   3. the rules downloaded when a rule set was turned on, then a reconfigure.
#
# Usage: suricata-converge.sh [--check]   (--check: report, change nothing)
set -euo pipefail
# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. "${TAPPAAS_BIN:-/home/tappaas/bin}/common-install-routines.sh"
# shellcheck source=/home/tappaas/bin/security-monitoring.sh
. "${TAPPAAS_BIN:-/home/tappaas/bin}/security-monitoring.sh"

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; }
CHECK=0
case "${1:-}" in
    --check) CHECK=1 ;;
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) usage >&2; exit 2 ;;
esac

FW="${FIREWALL_FQDN:-firewall.mgmt.internal}"
OPN_CREDS="${HOME}/.opnsense-credentials.txt"
[[ -r "${OPN_CREDS}" ]] || die "no OPNsense API credentials (${OPN_CREDS})"
OPN_AUTH="$(grep '^key=' "$OPN_CREDS" | cut -d= -f2-):$(grep '^secret=' "$OPN_CREDS" | cut -d= -f2-)"
IDS="https://${FW}:8443/api/ids"
TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT INT TERM

api() { curl -ksS --max-time 120 -u "$OPN_AUTH" "$@"; }
post() { api -X POST -H 'Content-Type: application/json' "$@"; }

# The rule sets taken: threats, not policy. File names as OPNsense lists them.
RULESETS=(
    abuse.ch.feodotracker.rules abuse.ch.sslblacklist.rules abuse.ch.sslipblacklist.rules
    abuse.ch.threatfox.rules abuse.ch.urlhaus.rules
    botcc.rules compromised.rules drop.rules ciarmy.rules
    emerging-attack_response.rules emerging-coinminer.rules emerging-current_events.rules
    emerging-exploit.rules emerging-exploit_kit.rules emerging-malware.rules
    emerging-mobile_malware.rules emerging-phishing.rules emerging-web_server.rules
    emerging-web_specific_apps.rules emerging-worm.rules threatview_CS_c2.rules
)

api "${IDS}/settings/get" > "${TMP}" || die "cannot read the IDS settings"
jq -e '.ids.general' "${TMP}" >/dev/null || die "the IDS settings did not read as expected"
sel() { jq -r ".ids.general.$1 | to_entries | map(select(.value.selected == 1) | .key) | join(\",\")" "${TMP}"; }
enabled="$(jq -r '.ids.general.enabled' "${TMP}")"

if [[ "$(security_monitoring)" != on ]]; then
    if [[ "${enabled}" == 1 ]]; then
        if [[ ${CHECK} -eq 1 ]]; then info "  would turn the IDS off (security monitoring off)"; else
            post "${IDS}/settings/set" -d '{"ids":{"general":{"enabled":"0"}}}' | jq -e '.result == "saved"' >/dev/null \
                || die "could not turn the IDS off"
            post "${IDS}/service/reconfigure" -d '{}' >/dev/null
            info "  ${GN}✓${CL} IDS off (security monitoring off)"
        fi
    fi
    echo "  suricata: off (security monitoring off)"
    exit 0
fi

# 1. on, alert only, on the WAN, eve to syslog
changed=0
want='{"enabled":"1","mode":"pcap","interfaces":"wan","syslog_eve":"1"}'
if [[ "${enabled}" != 1 || "$(sel mode)" != pcap || "$(sel interfaces)" != wan || "$(jq -r '.ids.general.syslog_eve' "${TMP}")" != 1 ]]; then
    if [[ ${CHECK} -eq 1 ]]; then info "  would turn the IDS on: alert only (PCAP), on the WAN, alerts to syslog"; else
        post "${IDS}/settings/set" -d "{\"ids\":{\"general\":${want}}}" | jq -e '.result == "saved"' >/dev/null \
            || die "could not set the IDS (alert only, WAN, eve to syslog)"
        changed=1
    fi
fi

# 2. the rule sets
api "${IDS}/settings/listRulesets" > "${TMP}" || die "cannot list the IDS rule sets"
new_rules=0
for f in "${RULESETS[@]}"; do
    state="$(jq -r --arg f "${f}" '.rows[] | select(.filename == $f) | .enabled' "${TMP}")"
    [[ -n "${state}" ]] || { warn "  rule set ${f} is not offered by this OPNsense — skipped"; continue; }
    [[ "${state}" == 1 ]] && continue
    if [[ ${CHECK} -eq 1 ]]; then info "  would turn on rule set ${f}"; continue; fi
    post "${IDS}/settings/toggleRuleset/${f}/1" -d '{}' | jq -e '.status == "ok" or .result == "saved"' >/dev/null \
        || die "could not turn on rule set ${f}"
    new_rules=1; changed=1
done

# 3. download what was turned on, then apply
if [[ ${CHECK} -eq 0 && ${changed} -eq 1 ]]; then
    if [[ ${new_rules} -eq 1 ]]; then
        post "${IDS}/service/updateRules" -d '{}' | jq -e '.status' >/dev/null || die "the rule download did not start"
        info "  rules downloading (ET Open, abuse.ch)"
    fi
    post "${IDS}/service/reconfigure" -d '{}' | jq -e '.status' >/dev/null || die "the IDS reconfigure failed"
    info "  ${GN}✓${CL} IDS on: alert only, WAN, ${#RULESETS[@]} threat rule sets"
fi
status="$(api "${IDS}/service/status" | jq -r '.status // "unknown"')"
echo "  suricata: ${status}"
