#!/usr/bin/env bash
#
# test-alert-watchdog.sh — tappaas-alert-watchdog.sh (#126) with a fake clock and mailer.
#
# Times are set relative to the heartbeat file's own mtime, so the test needs no
# GNU-only touch: grace on a first run, quiet while fresh, one notice when
# stale, once a day while it lasts, a resolve when it returns, and a notice that
# did not go out is retried. The logging VM is a fake probe: the subject names
# what does not answer there (#905).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W="${HERE}/../tappaas-alert-watchdog.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

[[ -f "${W}" ]] || { echo "tappaas-alert-watchdog.sh not found — cannot run here."; exit 77; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/alertwd.XXXXXX")"; trap 'rm -rf "${TMP}"' EXIT INT TERM

cat > "${TMP}/notify" <<EOF
#!/usr/bin/env bash
while [[ \$# -gt 0 ]]; do case "\$1" in --subject) S="\$2"; shift 2 ;; *) shift ;; esac; done
cat > /dev/null
[[ -e "${TMP}/fail" ]] && exit 1
printf '%s\n' "\${S}" >> "${TMP}/subjects"
EOF
chmod +x "${TMP}/notify"

# The probe prints whatever ${TMP}/probe holds: empty is a logging VM that does not answer.
printf 'loki=down\ngrafana=ok\n' > "${TMP}/probe"
printf '#!/usr/bin/env bash\ncat "%s/probe"\n' "${TMP}" > "${TMP}/probe-cmd"
chmod +x "${TMP}/probe-cmd"

run() {  # run <now> — prints the exit code
    TAPPAAS_ALERT_HEARTBEAT="${TMP}/hb" TAPPAAS_ALERT_WATCHDOG_STATE="${TMP}/state" \
    TAPPAAS_NOTIFY_CMD="${TMP}/notify" TAPPAAS_ALERT_BREADCRUMB="${TMP}/crumbs" TAPPAAS_NOW="$1" \
    TAPPAAS_ALERT_PROBE_CMD="${TMP}/probe-cmd" TAPPAAS_BUNDLE_CMD=true \
        bash "${W}" >/dev/null 2>&1; echo $?
}
mails() { [[ -f "${TMP}/subjects" ]] && wc -l < "${TMP}/subjects" | tr -d ' ' || echo 0; }

ck "no heartbeat yet: grace, no mail" "0 0" "$(run "$(date +%s)") $(mails)"
ck "…and the file now exists, so the wait has started" "yes" "$([[ -e ${TMP}/hb ]] && echo yes || echo no)"
T="$(date -r "${TMP}/hb" +%s)"

ck "fresh: nothing to say" "0 0" "$(run $((T + 60))) $(mails)"
ck "34 minutes without a heartbeat: still quiet" "0 0" "$(run $((T + 2040))) $(mails)"
ck "…and nothing on stderr (no state file is the healthy case)" "" \
   "$(TAPPAAS_ALERT_HEARTBEAT="${TMP}/hb" TAPPAAS_ALERT_WATCHDOG_STATE="${TMP}/state" TAPPAAS_NOTIFY_CMD="${TMP}/notify" \
      TAPPAAS_ALERT_BREADCRUMB="${TMP}/crumbs" TAPPAAS_NOW=$((T + 60)) bash "${W}" 2>&1 >/dev/null)"
ck "36 minutes: stale, one notice" "0 1" "$(run $((T + 2160))) $(mails)"
ck "…saying alerting is down" "ALERT: log alerting is down" "$(tail -1 "${TMP}/subjects" | cut -d' ' -f1-5)"
ck "…and that Loki does not answer" "Loki does not answer" "$(tail -1 "${TMP}/subjects" | sed 's/.* — //; s/ (no heartbeat.*//')"
ck "still stale an hour later: no second mail" "0 1" "$(run $((T + 10900))) $(mails)"
printf '' > "${TMP}/probe"
ck "still stale a day later: reminded once" "0 2" "$(run $((T + 2160 + 86400))) $(mails)"
ck "…naming the cause as it is now (the VM does not answer)" "the logging VM does not answer" \
   "$(tail -1 "${TMP}/subjects" | sed 's/.* — //; s/ (no heartbeat.*//')"

touch "${TMP}/hb"; T2="$(date -r "${TMP}/hb" +%s)"
ck "the heartbeat returns: resolved" "0 3" "$(run $((T2 + 30))) $(mails)"
ck "…saying it is back" "RESOLVED: log alerting is back" "$(tail -1 "${TMP}/subjects" | cut -d' ' -f1-5)"
ck "…and the state is cleared" "no" "$([[ -e ${TMP}/state ]] && echo yes || echo no)"
ck "fresh afterwards: quiet" "0 3" "$(run $((T2 + 90))) $(mails)"
printf 'loki=ok\ngrafana=ok\n' > "${TMP}/probe"

: > "${TMP}/fail"
ck "stale, but the notice does not go out: exit 1" "1 3" "$(run $((T2 + 7300))) $(mails)"
ck "…and nothing recorded, so it is retried" "no" "$([[ -e ${TMP}/state ]] && echo yes || echo no)"
rm -f "${TMP}/fail"
ck "the retry goes out" "0 4" "$(run $((T2 + 7400))) $(mails)"
ck "…both answer: the subject says so" "Loki and Grafana answer" "$(tail -1 "${TMP}/subjects" | sed 's/.* — //; s/ (no heartbeat.*//')"

touch "${TMP}/hb"; T3="$(date -r "${TMP}/hb" +%s)"
ck "back again: resolved" "0 5" "$(run $((T3 + 30))) $(mails)"
printf 'loki=ok\ngrafana=down\n' > "${TMP}/probe"
ck "Grafana down: one notice" "0 6" "$(run $((T3 + 2200))) $(mails)"
ck "…naming Grafana" "Grafana does not answer" "$(tail -1 "${TMP}/subjects" | sed 's/.* — //; s/ (no heartbeat.*//')"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
