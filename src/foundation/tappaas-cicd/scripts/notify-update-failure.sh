#!/usr/bin/env bash
# notify-update-failure.sh — tell the site owner that an update sweep failed (#651).
#
# Run by update-tappaas-failure.service, the OnFailure handler of
# update-tappaas.service. It says what failed and where; site-notify.sh delivers
# it to site.json `email` through a Proxmox node's own mail system (ADR-007e v1.3).
#
# Usage: notify-update-failure.sh [--degraded | --resolved] [--no-bundle] [--dry-run]
#        (--dry-run prints the mail instead)
#
# --degraded: the sweep completed but some app modules failed (exit 3, which the
# unit counts as success, so OnFailure does not fire): run from the unit's
# ExecStopPost instead, it records and mails that with its own subject.
# --resolved: run from ExecStopPost after a clean run. Sends "update sweep OK
# again" only while a failure notice is open and a clean sweep has written its
# result since — a run that did nothing clears nothing.
#
# Every notice is the condition `update-sweep` (#883): the RESOLVED replies to
# the failure it clears. A failure notice carries a support bundle of the run
# (tappaas-support-bundle.sh; --no-bundle leaves it out).
#
# Environment:
#   MONITOR_SERVICE_RESULT, MONITOR_EXIT_STATUS   set by systemd for OnFailure units
#   TAPPAAS_CONFIG_DIR   config dir (default /home/tappaas/config; tests)
#   TAPPAAS_NOTIFY_SSH, TAPPAAS_NOTIFY_NODES      passed on to site-notify.sh (tests)
#   TAPPAAS_ALERT_STATE  site-notify.sh's open conditions (default /var/lib/tappaas/alerts-open)
#   TAPPAAS_SUPPORT_BUNDLE  the bundle maker (default next to this file)
#
# Exit codes: 0 notice sent (or nothing to send to), 1 no node accepted the mail.

set -euo pipefail

CONFIG_DIR="${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}"
DRY_RUN=0
DEGRADED=0
RESOLVED=0
BUNDLE=1
for a in "$@"; do
    case "${a}" in
        --dry-run) DRY_RUN=1 ;;
        --degraded) DEGRADED=1 ;;
        --resolved) RESOLVED=1 ;;
        --no-bundle) BUNDLE=0 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "notify-update-failure: unknown option: ${a}" >&2; exit 2 ;;
    esac
done

# The mailer every site notice shares; it sits next to this file.
SITE_NOTIFY="${TAPPAAS_SITE_NOTIFY:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/site-notify.sh}"
SUPPORT_BUNDLE="${TAPPAAS_SUPPORT_BUNDLE:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/tappaas-support-bundle.sh}"
KEY="update-sweep"
OPEN="${TAPPAAS_ALERT_STATE:-/var/lib/tappaas/alerts-open}/${KEY}"

RESULT="${CONFIG_DIR}/last-update-result.json"
host="$(hostname 2>/dev/null || echo tappaas-cicd)"

# ── a clean sweep after a failure: the RESOLVED (#883) ───────────────
if [[ "${RESOLVED}" -eq 1 ]]; then
    # Nothing open (the common case), or no sweep since the notice: nothing to say.
    [[ -f "${OPEN}" && -f "${RESULT}" && "${RESULT}" -nt "${OPEN}" ]] || exit 0
    [[ "$(jq -r '(.ok == true) and ((.failed // 0) == 0)' "${RESULT}" 2>/dev/null)" == "true" ]] || exit 0
    since="$(jq -r '.sent // empty' "${OPEN}" 2>/dev/null || true)"
    summary="$(jq -r '"succeeded=\(.succeeded // "?")/\(.total // "?") control_plane=\(.control_plane // "?") reboot=\(.reboot // "?")"' "${RESULT}" 2>/dev/null || true)"
    args=(--what "resolved notice" --breadcrumb "${CONFIG_DIR}/update-tappaas.failures" --key "${KEY}" --resolve
          --subject "RESOLVED: update sweep OK again on ${host}")
    [[ "${DRY_RUN}" -eq 1 ]] && args+=(--dry-run)
    printf '%s\n' "The scheduled TAPPaaS update on ${host} completed cleanly at $(jq -r '.end_time // "?"' "${RESULT}" 2>/dev/null).
${since:+The failure reported since ${since} is cleared.}

Last sweep result: ${summary}" | "${SITE_NOTIFY}" "${args[@]}"
    exit $?
fi
# ── the stage it stopped in (ADR-017 D3) ─────────────────────────────
# prepare / rebuild: the unit's ExecStartPre failed and no sweep ran, so the
# result file still describes the previous sweep — record this failure there.
stage="$( { tr -d '[:space:]' < "${CONFIG_DIR}/.update-stage"; } 2>/dev/null || true)"
case "${stage}" in
    prepare|rebuild|migrate)
        jq -n --arg stage "${stage}" --arg t "$(date -Is)" \
            '{ok: false, stage: $stage, end_time: $t, failed: 0, failed_modules: [],
              note: "stopped before the sweep (ADR-017 D3); no module was updated"}' \
            > "${RESULT}.tmp" 2>/dev/null && mv -f "${RESULT}.tmp" "${RESULT}" || true ;;
esac
rm -f "${CONFIG_DIR}/.update-stage"
case "${stage}" in
    prepare) stage_line="Stopped in: the mothership's pull and builds (prepare), before any module was updated." ;;
    rebuild) stage_line="Stopped in: the mothership's nixos-rebuild, before any module was updated." ;;
    migrate) stage_line="Stopped in: a config migration, before any module was updated (ADR-025 D5). The migration that failed is named in the log below." ;;
    sweep)   stage_line="Stopped in: the module sweep." ;;
    *)       stage_line="" ;;
esac

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

headline="The scheduled TAPPaaS update on ${host} failed at $(date -Is)."
subject="update sweep FAILED on ${host}"
if [[ "${DEGRADED}" -eq 1 ]]; then
    nfailed="$(jq -r '.failed // 0' "${RESULT}" 2>/dev/null || echo '?')"
    headline="The scheduled TAPPaaS update on ${host} completed at $(date -Is), but ${nfailed} app module(s) failed."
    subject="update sweep: ${nfailed} module(s) failed on ${host}"
    printf '%s update-tappaas.service DEGRADED — %s app module(s) failed, see config/last-update-result.json\n' \
        "$(date -Is)" "${nfailed}" >> "${CONFIG_DIR}/update-tappaas.failures" 2>/dev/null || true
fi
body="$(cat <<EOF
${headline}

systemd: result=${MONITOR_SERVICE_RESULT:-${SERVICE_RESULT:-?}} exit=${MONITOR_EXIT_STATUS:-${EXIT_STATUS:-?}}
${stage_line}
Last sweep result: ${result_line}${written:+ (written ${written})}
${detail}

If that result is older than this failure, the run stopped before the sweep
wrote one — for instance in the mothership's own update.

Look at:
  journalctl -u update-tappaas.service -n 200
  ~/config/last-update-result.json
EOF
)"

# ── send it: addressing, the node's mailer and the fallback are site-notify.sh's
notify_args=(--what "failure notice" --breadcrumb "${CONFIG_DIR}/update-tappaas.failures"
             --subject "${subject}" --key "${KEY}")
[[ "${DRY_RUN}" -eq 1 ]] && notify_args+=(--dry-run)
# The run's journal and test logs, the site's state and its anonymized config.
# A bundle that cannot be made never stops the notice.
if [[ "${BUNDLE}" -eq 1 && -x "${SUPPORT_BUNDLE}" ]]; then
    bundle="$("${SUPPORT_BUNDLE}" --reason "${subject}" --unit update-tappaas.service 2>/dev/null | tail -n 1)" || bundle=""
    [[ -f "${bundle}" ]] && notify_args+=(--attach "${bundle}")
fi
printf '%s\n' "${body}" | "${SITE_NOTIFY}" "${notify_args[@]}"
