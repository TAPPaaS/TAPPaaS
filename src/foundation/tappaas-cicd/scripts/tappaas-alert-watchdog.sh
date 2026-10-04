#!/usr/bin/env bash
#
# tappaas-alert-watchdog.sh — mail when the log alerting itself has stopped (#126).
#
# The logging module's Grafana fires a Heartbeat rule while logs keep arriving;
# its webhook reaches tappaas-alert-receiver here, which writes the time to the
# heartbeat file and mails nothing. A heartbeat proves the whole path at once:
# logs flow into Loki, Grafana evaluates its rules, the webhook gets through
# with the token. This runs from a timer on the mothership — not on the logging
# VM it watches — and mails through site-notify.sh, the path a failed sweep
# uses (#651), when the heartbeat goes stale:
#
#   stale (older than MAX_AGE)  "ALERT: log alerting is down", once, then again
#                               once a day while it lasts
#   fresh again                 "RESOLVED: log alerting is back"
#
# A heartbeat file that does not exist yet (a fresh install, a new mothership)
# is created now: the first heartbeat then has MAX_AGE to arrive before this
# says anything. A notice that does not go out is retried on the next run.
#
# Environment (tests):
#   TAPPAAS_ALERT_HEARTBEAT   heartbeat file   (default /var/lib/tappaas/alert-heartbeat)
#   TAPPAAS_ALERT_WATCHDOG_STATE  state file   (default /var/lib/tappaas/alert-watchdog.state)
#   TAPPAAS_ALERT_MAX_AGE     seconds before stale (default 7200: the heartbeat repeats hourly)
#   TAPPAAS_ALERT_REPEAT      seconds between repeat notices while down (default 86400)
#   TAPPAAS_NOTIFY_CMD        the mailer (default /home/tappaas/bin/site-notify.sh)
#   TAPPAAS_NOW               the time, in epoch seconds
#
# Exit: 0 nothing to do or notice sent · 1 a notice did not go out
set -uo pipefail

HB="${TAPPAAS_ALERT_HEARTBEAT:-/var/lib/tappaas/alert-heartbeat}"
STATE="${TAPPAAS_ALERT_WATCHDOG_STATE:-/var/lib/tappaas/alert-watchdog.state}"
MAX_AGE="${TAPPAAS_ALERT_MAX_AGE:-7200}"
REPEAT="${TAPPAAS_ALERT_REPEAT:-86400}"
NOTIFY="${TAPPAAS_NOTIFY_CMD:-/home/tappaas/bin/site-notify.sh}"
BREADCRUMB="${TAPPAAS_ALERT_BREADCRUMB:-/home/tappaas/config/alerts.log}"
NOW="${TAPPAAS_NOW:-$(date +%s)}"

if [[ ! -e "${HB}" ]]; then
    touch -d "@${NOW}" "${HB}" 2>/dev/null || touch "${HB}"
    echo "alert-watchdog: no heartbeat yet — waiting up to ${MAX_AGE}s for the first"
    exit 0
fi

last="$(date -r "${HB}" +%s)"
age=$(( NOW - last ))
when="$(date -d "@${last}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || date -r "${last}" '+%Y-%m-%d %H:%M %Z')"
read -r down_since last_mail < "${STATE}" 2>/dev/null || { down_since=""; last_mail=""; }

notice() {  # notice <subject> — body on stdin
    "${NOTIFY}" --subject "$1" --what "alert-watchdog" --breadcrumb "${BREADCRUMB}"
}

if (( age > MAX_AGE )); then
    if [[ -n "${down_since}" ]] && (( NOW - last_mail < REPEAT )); then
        echo "alert-watchdog: still no heartbeat (last ${when}); notified already"
        exit 0
    fi
    if notice "ALERT: log alerting is down — no heartbeat since ${when}" <<EOF
The logging module's alert rules have not reported in for $(( age / 60 )) minutes
(the last heartbeat was ${when}). Until they do, NOTHING in the logs raises an
alert: quorum loss, fencing, disk errors, failed backups, silent hosts.

The heartbeat proves logs reach Loki, Grafana evaluates the rules, and its
webhook reaches tappaas-alert-receiver on the mothership. One of those stopped:
  - the logging VM:   module-manager module test logging
  - Grafana / Loki:   ssh tappaas@logging.mgmt.internal systemctl status grafana loki
  - the receiver:     journalctl -u tappaas-alert-receiver (401 = a token mismatch:
                      re-run the logging module's update)

Repeated once a day while it lasts. Sent by tappaas-alert-watchdog (#126).
EOF
    then
        printf '%s %s\n' "${down_since:-${NOW}}" "${NOW}" > "${STATE}"
        echo "alert-watchdog: no heartbeat since ${when} — notified"
        exit 0
    fi
    echo "alert-watchdog: no heartbeat since ${when} — the notice did NOT go out; retrying next run" >&2
    exit 1
fi

if [[ -n "${down_since}" ]]; then
    if notice "RESOLVED: log alerting is back — heartbeat ${when}" <<EOF
The logging module's alert rules are reporting again (heartbeat ${when}),
after $(( (NOW - down_since) / 60 )) minutes without. Log conditions raise alerts again.

Sent by tappaas-alert-watchdog (#126).
EOF
    then
        rm -f "${STATE}"
        echo "alert-watchdog: heartbeat is back — notified"
        exit 0
    fi
    echo "alert-watchdog: heartbeat is back, but the notice did NOT go out; retrying next run" >&2
    exit 1
fi
echo "alert-watchdog: heartbeat ${when} (${age}s ago)"
