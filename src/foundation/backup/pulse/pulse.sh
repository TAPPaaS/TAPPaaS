#!/usr/bin/env bash
#
# pulse.sh — is the backup buddy alive, and is this site? (ADR-031)
#
# A dark site cannot report itself. This runs on a site's backup node — the Host
# its PBS runs on — from a timer every 5 minutes, and mails when something it
# watches stops answering:
#
#   buddies     the PBS of every buddy we pull from, through the buddy tunnel
#               (TLS, certificate fingerprint checked). Mailed to our operator
#               AND the buddy's: their site may be down, and this is the mail it
#               cannot send itself.
#   uplink      our own internet. While it is down, buddies are not judged — a
#               buddy that does not answer proves nothing then.
#   firewall, mothership, pbs
#               our own site, mailed to our operator.
#
# A target is down after `downAfter` seconds of failed probes (default 900;
# the mothership 1800, a reboot during a sweep takes minutes). Then one mail,
# again once a day (`repeat`) while it lasts, and one when it answers again.
# A mail that does not go out is retried on the next run.
#
# The same script runs standalone on a buddy that is not TAPPaaS (BUDDY.md,
# Setup 3): a pulse.json with only `site`, `email`, `uplink` and `buddies`.
#
# Usage: pulse.sh [--config FILE] [--status] [--template]
#   --status    each target: up or down since when, last answer, last mail
#   --template  print a pulse.json to start from
#
# Environment (tests):
#   PULSE_STATE_DIR   state (default /var/lib/tappaas/pulse)
#   PULSE_PROBE_CMD   replaces every probe: `cmd <target-id>`, rc 0 = answers
#   PULSE_SENDMAIL    the mailer, reads a whole message on stdin (default sendmail -t)
#   PULSE_NOW         the time, in epoch seconds
#
# Exit: 0 · 1 a mail did not go out · 2 bad config
set -uo pipefail

CONFIG="/etc/tappaas/pulse.json"
MODE="run"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG="${2:?--config needs a file}"; shift 2 ;;
        --status) MODE="status"; shift ;;
        --template) MODE="template"; shift ;;
        -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
        *) echo "pulse: unknown option $1" >&2; exit 2 ;;
    esac
done

if [[ "${MODE}" == "template" ]]; then
    cat <<'EOF'
{
  "site": "my-site",
  "email": "me@example.org",
  "uplink": "deb.debian.org",
  "buddies": [
    { "name": "their-site", "host": "10.255.2.1", "port": 8007,
      "fingerprint": "aa:bb:…  (their PBS certificate, sha256)",
      "contact": "them@example.org" }
  ]
}
EOF
    exit 0
fi

command -v jq >/dev/null || { echo "pulse: jq is needed" >&2; exit 2; }
[[ -r "${CONFIG}" ]] && jq -e 'type == "object"' "${CONFIG}" >/dev/null 2>&1 \
    || { echo "pulse: ${CONFIG} is missing or not a JSON object" >&2; exit 2; }

STATE_DIR="${PULSE_STATE_DIR:-/var/lib/tappaas/pulse}"
NOW="${PULSE_NOW:-$(date +%s)}"
mkdir -p "${STATE_DIR}"
cfg() { jq -r "$1 // empty" "${CONFIG}"; }
SITE="$(cfg .site)"; EMAIL="$(cfg .email)"
DOWN_AFTER="$(cfg .downAfter)"; DOWN_AFTER="${DOWN_AFTER:-900}"
REPEAT="$(cfg .repeat)"; REPEAT="${REPEAT:-86400}"

# ── the targets: "id|kind|label|downAfter|contact|probe args" ──────────
targets() {
    local u; u="$(cfg .uplink)"
    [[ -n "${u}" ]] && echo "uplink|uplink|our internet|${DOWN_AFTER}||${u}"
    local fw; fw="$(cfg .firewall)"
    [[ -n "${fw}" ]] && echo "firewall|ping|the firewall (${fw})|${DOWN_AFTER}||${fw}"
    local ms ma; ms="$(cfg .mothership)"; ma="$(cfg .mothershipDownAfter)"
    [[ -n "${ms}" ]] && echo "mothership|tcp|the mothership (${ms})|${ma:-1800}||${ms} 22"
    local pbs; pbs="$(cfg .pbs)"
    [[ -n "${pbs}" ]] && echo "pbs|tcp|this site's PBS|${DOWN_AFTER}||${pbs} 8007"
    jq -r --arg d "${DOWN_AFTER}" '.buddies // [] | .[]
        | "buddy-\(.name)|tls|backup buddy \(.name)|\($d)|\(.contact // "")|\(.host) \(.port // 8007) \(.fingerprint // "")"' "${CONFIG}"
}

# ── probes ───────────────────────────────────────────────────────────
tcp() { timeout 6 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }
probe() {  # probe <id> <kind> <args…>
    local id="$1" kind="$2"; shift 2
    if [[ -n "${PULSE_PROBE_CMD:-}" ]]; then ${PULSE_PROBE_CMD} "${id}"; return; fi
    case "${kind}" in
        uplink) getent hosts "$1" >/dev/null && tcp "$1" 443 ;;
        ping)   ping -c 1 -W 3 "$1" >/dev/null 2>&1 ;;
        tcp)    tcp "$1" "$2" ;;
        tls)
            local host="$1" port="$2" want="${3:-}" got
            if [[ -z "${want}" ]]; then tcp "${host}" "${port}"; return; fi
            got="$(timeout 10 openssl s_client -connect "${host}:${port}" </dev/null 2>/dev/null \
                   | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//')"
            [[ -n "${got}" && "${got,,}" == "${want,,}" ]] ;;
        *) return 1 ;;
    esac
}

# ── mail ─────────────────────────────────────────────────────────────
mail_to() {  # mail_to <to,…> <subject> — body on stdin
    local to="$1" subject="$2" body
    body="$(cat)"
    [[ -n "${to}" ]] || { echo "pulse: no address to mail '${subject}' to"; return 0; }
    {
        printf 'To: %s\nSubject: [TAPPaaS %s] %s\nContent-Type: text/plain; charset=UTF-8\n\n' \
            "${to}" "${SITE:-site}" "${subject}"
        printf '%s\n\n— the pulse on %s (ADR-031)\n' "${body}" "$(hostname -f 2>/dev/null || hostname)"
    } | if [[ -n "${PULSE_SENDMAIL:-}" ]]; then ${PULSE_SENDMAIL}; else /usr/sbin/sendmail -t; fi
}
when() { date -d "@$1" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M %Z'; }

# State per target: "<last_ok> <first_fail> <down_since> <last_mail>", 0 = never.
load() { local f="${STATE_DIR}/$1"; s_ok=0 s_fail=0 s_down=0 s_mail=0
         [[ -f "${f}" ]] && read -r s_ok s_fail s_down s_mail < "${f}"; return 0; }
save() { echo "${s_ok} ${s_fail} ${s_down} ${s_mail}" > "${STATE_DIR}/$1"; }

if [[ "${MODE}" == "status" ]]; then
    printf '%-22s %-6s %-22s %-22s %s\n' TARGET STATE SINCE "LAST ANSWER" "LAST MAIL"
    while IFS='|' read -r id _ label _ _ _; do
        load "${id}"
        st=up; since="-"
        (( s_down > 0 )) && { st=DOWN; since="$(when "${s_down}")"; }
        (( s_down == 0 && s_fail > 0 )) && { st=failing; since="$(when "${s_fail}")"; }
        printf '%-22s %-6s %-22s %-22s %s\n' "${id}" "${st}" "${since}" \
            "$( (( s_ok > 0 )) && when "${s_ok}" || echo never)" "$( (( s_mail > 0 )) && when "${s_mail}" || echo -)"
    done < <(targets)
    exit 0
fi

# ── run ──────────────────────────────────────────────────────────────
rc=0
uplink_up=1
if [[ -n "$(cfg .uplink)" ]] && ! probe uplink uplink "$(cfg .uplink)"; then uplink_up=0; fi

while IFS='|' read -r id kind label after contact args; do
    [[ -n "${id}" ]] || continue
    # A buddy that does not answer while our own uplink is down proves nothing.
    if [[ "${id}" == buddy-* && "${uplink_up}" == "0" ]]; then continue; fi
    load "${id}"
    to="${EMAIL}"; [[ -n "${contact}" && "${contact,,}" != "${EMAIL,,}" ]] && to="${EMAIL:+${EMAIL},}${contact}"
    # shellcheck disable=SC2086  # args are words on purpose
    if { [[ "${id}" == uplink ]] && (( uplink_up )); } || { [[ "${id}" != uplink ]] && probe "${id}" "${kind}" ${args}; }; then
        if (( s_down > 0 )); then
            if mail_to "${to}" "RESOLVED: ${label} answers again" <<EOF
${label} answers again, $(when "${NOW}").
It did not answer from $(when "${s_fail}") — $(( (NOW - s_fail) / 60 )) minutes.
EOF
            then s_down=0; s_mail=0; else rc=1; fi
        fi
        (( s_down == 0 )) && s_fail=0
        s_ok="${NOW}"
    else
        (( s_fail == 0 )) && s_fail="${NOW}"
        if (( NOW - s_fail >= after )) && { (( s_down == 0 )) || (( NOW - s_mail >= REPEAT )); }; then
            what="${label} has not answered since $(when "${s_fail}")."
            case "${id}" in
                buddy-*) what+=$'\n\n'"Their site may be down: power, its firewall, its uplink or its PBS host. Our off-site copy of them is not being pulled, and theirs of us may not be either." ;;
                uplink)  what+=$'\n\n'"This site's own internet is down. This mail goes out when it is back." ;;
                mothership) what+=$'\n\n'"No updates run, and the alerts that pass through the mothership do not go out." ;;
            esac
            if mail_to "${to}" "ALERT: ${label} not answering" <<< "${what}"; then
                (( s_down == 0 )) && s_down="${NOW}"
                s_mail="${NOW}"
            else
                rc=1
            fi
        fi
    fi
    save "${id}"
done < <(targets)
exit "${rc}"
