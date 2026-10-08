#!/usr/bin/env bash
#
# test-alert-receiver.sh — tappaas-alert-receiver.py (#126) against a fake site-notify.
#
# Starts the receiver on a free local port with a token file and a notify
# command that records its subject and body, then posts Grafana-shaped webhooks:
# authentication, the event/state resolve rule, a notify failure (5xx so Grafana
# retries), and what reaches the mail.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="${HERE}/../tappaas-alert-receiver.py"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

[[ -f "${R}" ]] || { echo "tappaas-alert-receiver.py not found — cannot run here."; exit 77; }
command -v python3 >/dev/null && command -v curl >/dev/null || { echo "needs python3 and curl"; exit 77; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/alertrx.XXXXXX")"
PID=""
trap '[[ -n "${PID}" ]] && kill "${PID}" 2>/dev/null; rm -rf "${TMP}"' EXIT INT TERM

printf 'sekret\n' > "${TMP}/token"
cat > "${TMP}/notify" <<EOF
#!/usr/bin/env bash
# fake site-notify.sh: record the subject and the body; fail when told to
while [[ \$# -gt 0 ]]; do case "\$1" in --subject) S="\$2"; shift 2 ;; *) shift ;; esac; done
printf '%s\n' "\${S}" >> "${TMP}/subjects"
cat >> "${TMP}/bodies"
[[ -e "${TMP}/notify-fails" ]] && exit 1
exit 0
EOF
chmod +x "${TMP}/notify"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 "${R}" --listen "127.0.0.1:${PORT}" --token-file "${TMP}/token" \
    --notify "${TMP}/notify" --breadcrumb "${TMP}/crumbs" --heartbeat-file "${TMP}/heartbeat" > "${TMP}/log" 2>&1 &
PID=$!
for _ in $(seq 1 50); do curl -s "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 && break; sleep 0.1; done

post() {  # post <token> <json> [path] — prints the HTTP status
    curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${PORT}${3:-/alert}" \
        -H "Authorization: Bearer $1" -H 'Content-Type: application/json' --data "$2"
}
wh() {  # wh <status> <kind> <alertname> <host> — a Grafana webhook body
    printf '{"status":"%s","commonLabels":{"alertname":"%s"},"alerts":[{"status":"%s","labels":{"alertname":"%s","host":"%s","kind":"%s"},"annotations":{"summary":"%s on %s","query":"{host=\\"%s\\"}"},"startsAt":"2026-10-04T18:00:00Z","endsAt":"2026-10-04T18:20:00Z"}]}' \
        "$1" "$3" "$1" "$3" "$4" "$2" "$3" "$4" "$4"
}
sent() { [[ -f "${TMP}/subjects" ]] && wc -l < "${TMP}/subjects" | tr -d ' ' || echo 0; }

ck "no token: refused" "401" "$(post '' "$(wh firing event QuorumLost tappaas1)")"
ck "wrong token: refused" "401" "$(post nope "$(wh firing event QuorumLost tappaas1)")"
ck "nothing mailed for a refused request" "0" "$(sent)"
ck "another path: not found" "404" "$(post sekret "$(wh firing event QuorumLost tappaas1)" /other)"
ck "not JSON: bad request" "400" "$(post sekret 'nope')"

ck "a firing alert is accepted" "200" "$(post sekret "$(wh firing event QuorumLost tappaas1)")"
ck "…and mailed" "ALERT: QuorumLost on tappaas1" "$(tail -1 "${TMP}/subjects")"
ck "the body carries the summary" "yes" "$(grep -q 'QuorumLost on tappaas1' "${TMP}/bodies" && echo yes || echo no)"
ck "the body carries the query to paste" "yes" "$(grep -q 'Explore, Loki): {host="tappaas1"}' "${TMP}/bodies" && echo yes || echo no)"

n="$(sent)"
ck "an event rule's resolve is accepted" "200" "$(post sekret "$(wh resolved event QuorumLost tappaas1)")"
ck "…but not mailed" "${n}" "$(sent)"
ck "a state rule's resolve is accepted" "200" "$(post sekret "$(wh resolved state HostSilent logging)")"
ck "…and mailed" "RESOLVED: HostSilent on logging" "$(tail -1 "${TMP}/subjects")"

: > "${TMP}/notify-fails"
ck "a notice that does not go out is a 5xx, so Grafana retries" "502" "$(post sekret "$(wh firing state HostSilent tappaas2)")"
rm -f "${TMP}/notify-fails"

: > "${TMP}/token"
ck "an empty token file refuses everything" "401" "$(post '' "$(wh firing event QuorumLost tappaas1)")"
printf 'rotated\n' > "${TMP}/token"
ck "a rotated token is read without a restart" "200" "$(post rotated "$(wh firing event OomKill openwebui)")"

n="$(sent)"
ck "a heartbeat is accepted" "200" "$(post rotated "$(wh firing heartbeat Heartbeat '')")"
ck "…recorded" "2026-10-04T18:00:00Z" "$(cat "${TMP}/heartbeat" 2>/dev/null)"
ck "…and never mailed" "${n}" "$(sent)"
both='{"status":"firing","alerts":[{"status":"firing","labels":{"alertname":"Heartbeat","kind":"heartbeat"},"startsAt":"2026-10-04T19:00:00Z"},{"status":"firing","labels":{"alertname":"QuorumLost","host":"tappaas2","kind":"event"},"startsAt":"2026-10-04T19:00:00Z"}]}'
ck "a heartbeat next to a real alert does not hide it" "200" "$(post rotated "${both}")"
ck "…the real one is mailed" "ALERT: QuorumLost on tappaas2" "$(tail -1 "${TMP}/subjects")"

ck "--render prints the mail" "Subject: ALERT: QuorumLost on tappaas1" \
   "$(wh firing event QuorumLost tappaas1 | python3 "${R}" --render | head -1)"
rep='{"status":"firing","alerts":[{"status":"firing","labels":{"alertname":"ReplicationFailed","host":"tappaas1","replication_job":"110-0","kind":"state","grafana_folder":"TAPPaaS","__alert_rule_uid__":"x"},"annotations":{"summary":"s"},"startsAt":"2026-10-08T00:31:00Z"}]}'
ck "a series label names WHICH one in the subject (replication job)" "Subject: ALERT: ReplicationFailed on tappaas1 (replication_job 110-0)" \
   "$(python3 "${R}" --render <<<"${rep}" | head -1)"
ck "…and in the body; grafana's own labels stay out" "replication_job: 110-0" "$(python3 "${R}" --render <<<"${rep}" | grep -E '^(replication_job|grafana_folder|__alert)' | paste -sd' ' -)"
ck "a rule's headline names it in the subject, after ALERT:" "Subject: ALERT: Out of Memory Kill on openwebui" \
   "$(wh firing event OomKill openwebui | sed 's/"query":/"headline":"Out of Memory Kill","query":/' | python3 "${R}" --render | head -1)"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
