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
#   2. the rule sets, by the site's size (operator, 2026-11-12): threat
#      categories of ET Open and abuse.ch — at medium a core set (exploits,
#      attack responses, command-and-control and known-bad hosts), at large
#      also the big ones (ET malware, phishing, exploit kits, web apps, the SSL
#      blacklist). Not the policy, info, scan or hunting ones, which on a WAN
#      are noise (CrowdSec already bans scanners). Sets of the other size are
#      turned off, so a site that shrinks gives the memory back;
#   3. the rules downloaded when a rule set was turned on, then a reconfigure.
#
# Memory: the firewall keeps /var/log in RAM and has no swap, so what Suricata
# needs must be free. It is not turned on while less than SURICATA_NEED_MB (free
# and inactive memory) is: on hrossen's 4 GB firewall the full rule set was
# killed with about 1.9 GB free, and the kernel had killed unbound before
# (2026-11-12). The need is by size: the core set (about 3 600 rules) ran in
# 200 MB on hrossen, so medium asks 1 GB free; the full set (about 60 000)
# asks 3 GB, which a large site's 8 GB network VM has (ADR-044).
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
CORE=(
    abuse.ch.feodotracker.rules abuse.ch.sslipblacklist.rules abuse.ch.threatfox.rules
    abuse.ch.urlhaus.rules botcc.rules compromised.rules drop.rules ciarmy.rules
    threatview_CS_c2.rules emerging-attack_response.rules emerging-coinminer.rules
    emerging-exploit.rules emerging-web_server.rules emerging-worm.rules
)
LARGE=(
    abuse.ch.sslblacklist.rules emerging-current_events.rules emerging-exploit_kit.rules
    emerging-malware.rules emerging-mobile_malware.rules emerging-phishing.rules
    emerging-web_specific_apps.rules
)
SIZE="$(_ms_size)"
if [[ "${SIZE}" == large ]]; then
    RULESETS=("${CORE[@]}" "${LARGE[@]}"); NOT=(); NEED_DEFAULT=3072
else
    RULESETS=("${CORE[@]}"); NOT=("${LARGE[@]}"); NEED_DEFAULT=1024
fi

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

# 1. on, alert only, on the WAN, eve to syslog — if the memory is there
changed=0
NEED_MB="${SURICATA_NEED_MB:-${NEED_DEFAULT}}"
if [[ "${enabled}" != 1 ]]; then
    free_mb="$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "root@${FW}" \
        "/bin/sh -c 'echo \$(( (\$(sysctl -n vm.stats.vm.v_free_count) + \$(sysctl -n vm.stats.vm.v_inactive_count)) * \$(sysctl -n hw.pagesize) / 1048576 ))'" 2>/dev/null || echo "")"
    if [[ ! "${free_mb}" =~ ^[0-9]+$ ]]; then
        warn "  could not read the firewall's free memory — Suricata stays off"; echo "  suricata: off (memory unknown)"; exit 0
    elif (( free_mb < NEED_MB )); then
        warn "  Suricata needs about ${NEED_MB} MB free; the firewall has ${free_mb} MB — it stays off (give network more memory: module-manager module modify network --set memory=<MB>)"
        echo "  suricata: off (not enough memory)"; exit 0
    fi
fi
want='{"enabled":"1","mode":"pcap","interfaces":"wan","syslog_eve":"1"}'
if [[ "${enabled}" != 1 || "$(sel mode)" != pcap || "$(sel interfaces)" != wan || "$(jq -r '.ids.general.syslog_eve' "${TMP}")" != 1 ]]; then
    if [[ ${CHECK} -eq 1 ]]; then info "  would turn the IDS on: alert only (PCAP), on the WAN, alerts to syslog"; else
        post "${IDS}/settings/set" -d "{\"ids\":{\"general\":${want}}}" | jq -e '.result == "saved"' >/dev/null \
            || die "could not set the IDS (alert only, WAN, eve to syslog)"
        changed=1
    fi
fi

# 2. the rule sets of this size on, the others off
api "${IDS}/settings/listRulesets" > "${TMP}" || die "cannot list the IDS rule sets"
new_rules=0
state_of() { jq -r --arg f "$1" '.rows[] | select(.filename == $f) | .enabled' "${TMP}"; }
want_on=(); want_off=()
for f in "${RULESETS[@]}"; do
    st="$(state_of "${f}")"
    [[ -n "${st}" ]] || { warn "  rule set ${f} is not offered by this OPNsense — skipped"; continue; }
    [[ "${st}" == 1 ]] || want_on+=("${f}")
done
for f in ${NOT[@]+"${NOT[@]}"}; do
    [[ "$(state_of "${f}")" == 1 ]] && want_off+=("${f}")
done
# One call per direction; the answer is the state the sets are in now.
toggle() {  # toggle <0|1> <files...>
    local to="$1"; shift
    local list; list="$(IFS=,; echo "$*")"
    post "${IDS}/settings/toggleRuleset/${list}/${to}" -d '{}' | jq -e --arg to "${to}" '.status == $to' >/dev/null
}
if [[ ${#want_on[@]} -gt 0 ]]; then
    if [[ ${CHECK} -eq 1 ]]; then info "  would turn on ${#want_on[@]} rule set(s): ${want_on[*]}"; else
        toggle 1 "${want_on[@]}" || die "could not turn on the rule sets: ${want_on[*]}"
        new_rules=1; changed=1
    fi
fi
if [[ ${#want_off[@]} -gt 0 ]]; then
    if [[ ${CHECK} -eq 1 ]]; then info "  would turn off ${#want_off[@]} rule set(s) for a ${SIZE} site: ${want_off[*]}"; else
        toggle 0 "${want_off[@]}" || die "could not turn off the rule sets: ${want_off[*]}"
        new_rules=1; changed=1
    fi
fi

# 3. the rules on disk follow the sets (a set turned off keeps its file until
# a rule update), then apply. On the firewall and synchronous: the API's
# updateRules runs in the background, and a reconfigure before it ends starts
# Suricata on every file there (hrossen: 60 000 rules, out of memory).
if [[ ${CHECK} -eq 0 && ${changed} -eq 1 ]]; then
    if [[ ${new_rules} -eq 1 ]]; then
        ssh -n -o BatchMode=yes -o ConnectTimeout=10 "root@${FW}" "/usr/local/sbin/configctl ids update" >/dev/null \
            || die "the rule update on the firewall failed"
        info "  rules updated (ET Open, abuse.ch)"
    fi
    post "${IDS}/service/reconfigure" -d '{}' | jq -e '.status' >/dev/null || die "the IDS reconfigure failed"
    info "  ${GN}✓${CL} IDS on: alert only, WAN, ${#RULESETS[@]} threat rule sets (${SIZE})"
fi
status="$(api "${IDS}/service/status" | jq -r '.status // "unknown"')"
echo "  suricata: ${status}"
