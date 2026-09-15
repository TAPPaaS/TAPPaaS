#!/usr/bin/env bash
# notify-update-failure.sh — tell the site owner that an update sweep failed (#651).
#
# Run by update-tappaas-failure.service, the OnFailure handler of
# update-tappaas.service. The notice goes to site.json `email` through a Proxmox
# node's own mail system (postfix/sendmail, the channel PVE already uses for its
# own mail): the cicd has no mailer, and a notice that stays on the cicd reaches
# no one (ADR-007e v1.3). Nodes are tried in order until one accepts the mail.
#
# Usage: notify-update-failure.sh [--dry-run]    (--dry-run prints the mail instead)
#
# Environment:
#   MONITOR_SERVICE_RESULT, MONITOR_EXIT_STATUS   set by systemd for OnFailure units
#   TAPPAAS_CONFIG_DIR   config dir (default /home/tappaas/config; tests)
#   TAPPAAS_NOTIFY_SSH   ssh command (default ssh; tests)
#   TAPPAAS_NOTIFY_NODES space-separated node names (default: the site's nodes; tests)
#
# Exit codes: 0 notice sent (or nothing to send to), 1 no node accepted the mail.

set -euo pipefail

CONFIG_DIR="${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}"
SSH="${TAPPAAS_NOTIFY_SSH:-ssh}"
DRY_RUN=0
for a in "$@"; do
    case "${a}" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        *) echo "notify-update-failure: unknown option: ${a}" >&2; exit 2 ;;
    esac
done

log() { echo "notify-update-failure: $*"; }
breadcrumb() { printf '%s %s\n' "$(date -Is)" "$*" >> "${CONFIG_DIR}/update-tappaas.failures" 2>/dev/null || true; }

SITE="${CONFIG_DIR}/site.json"
RESULT="${CONFIG_DIR}/last-update-result.json"
to="$(jq -r '.email // empty' "${SITE}" 2>/dev/null || true)"
site_name="$(jq -r '.name // empty' "${SITE}" 2>/dev/null || true)"
if [[ -z "${to}" ]]; then
    log "site.json has no email — notice not sent (set one: site-manager site modify --email <address>)"
    breadcrumb "failure notice NOT sent: site.json has no email"
    exit 0
fi
# It becomes a mail header: one plain address or nothing.
if ! [[ "${to}" =~ ^[^@[:space:]\<\>]+@[^@[:space:]\<\>]+$ ]]; then
    log "site.json email is not a single address — notice not sent"
    breadcrumb "failure notice NOT sent: site.json email is not a single address"
    exit 1
fi

if [[ -n "${TAPPAAS_NOTIFY_NODES:-}" ]]; then
    read -r -a nodes <<<"${TAPPAAS_NOTIFY_NODES}"
else
    mapfile -t nodes < <(jq -r '.hardware.nodes[]?.name // empty' "${SITE}" 2>/dev/null)
    [[ ${#nodes[@]} -gt 0 ]] || nodes=(tappaas1)
fi

# ── the message ──────────────────────────────────────────────────────
result_line="no last-update-result.json"
detail=""
written=""
if [[ -f "${RESULT}" ]]; then
    written="$(date -r "${RESULT}" -Is)"
    result_line="$(jq -r '"ok=\(.ok) failed=\(.failed // 0) not_attempted=\(.not_attempted // 0) control_plane=\(.control_plane // "?") reboot=\(.reboot // "?")"' "${RESULT}" 2>/dev/null || echo "unreadable")"
    detail="$(jq -r '
        (if (.failed_modules // []) | length > 0 then "Failed modules: \(.failed_modules | join(", "))" else empty end),
        (if .shared_dependency_down then "Shared dependency DOWN: \(.shared_dependency_down.failures // [] | map(.detail // tostring) | join("; ")) (culprit: \(.shared_dependency_down.culprit_module // "?"))" else empty end),
        (if (.deferred // 0) > 0 then "Deferred disruptive changes: \(.deferred)" else empty end),
        (if (.test_warnings // []) | length > 0 then "Checks failing before and after their update: \(.test_warnings | length)" else empty end)
      ' "${RESULT}" 2>/dev/null || true)"
fi

host="$(hostname 2>/dev/null || echo tappaas-cicd)"
subject="[TAPPaaS${site_name:+ ${site_name}}] update sweep FAILED on ${host}"
body="$(cat <<EOF
The scheduled TAPPaaS update on ${host} failed at $(date -Is).

systemd: result=${MONITOR_SERVICE_RESULT:-?} exit=${MONITOR_EXIT_STATUS:-?}
Last sweep result: ${result_line}${written:+ (written ${written})}
${detail}

If that result is older than this failure, the run stopped before the sweep
wrote one — for instance in the mothership's own update.

Look at:
  journalctl -u update-tappaas.service -n 200
  ~/config/last-update-result.json
EOF
)"

# ── send it ──────────────────────────────────────────────────────────
ssh_node() {
    "${SSH}" -n -o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=no -o ControlPath=none \
        "root@$1.mgmt.internal" "$2"
}

for node in "${nodes[@]}"; do
    # The sender Proxmox is configured with (Datacenter → email_from), if any.
    from="$(ssh_node "${node}" "pvesh get /cluster/options --output-format json" 2>/dev/null \
            | jq -r '.email_from // empty' 2>/dev/null || true)"
    from_hdr=""
    [[ -n "${from}" ]] && from_hdr="From: TAPPaaS <${from}>"$'\n'
    mail="$(printf 'To: %s\n%sSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
        "${to}" "${from_hdr}" "${subject}" "${body}")"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        printf '%s\n' "${mail}"
        log "dry run — would send through ${node}"
        exit 0
    fi
    if printf '%s\n' "${mail}" | "${SSH}" -o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=no -o ControlPath=none \
            "root@${node}.mgmt.internal" "/usr/sbin/sendmail -t -oi"; then
        log "notice sent to ${to} through ${node}"
        breadcrumb "failure notice sent to ${to} through ${node}"
        exit 0
    fi
    log "${node} did not take the mail — trying the next node"
done

log "no node accepted the mail — notice NOT sent"
breadcrumb "failure notice NOT sent: no node accepted the mail"
exit 1
