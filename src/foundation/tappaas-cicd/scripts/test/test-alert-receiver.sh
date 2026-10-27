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
# fake site-notify.sh: record the subject, the body and every argument; fail when told to
printf '%s\n' "\$*" >> "${TMP}/args"
while [[ \$# -gt 0 ]]; do case "\$1" in --subject) S="\$2"; shift 2 ;; *) shift ;; esac; done
printf '%s\n' "\${S}" >> "${TMP}/subjects"
cat >> "${TMP}/bodies"
[[ -e "${TMP}/notify-fails" ]] && exit 1
exit 0
EOF
chmod +x "${TMP}/notify"
cat > "${TMP}/bundle" <<EOF
#!/usr/bin/env bash
# fake tappaas-support-bundle.sh: record the arguments, print a path
printf '%s\n' "\$*" >> "${TMP}/bundle-args"
echo "${TMP}/b.tar.gz"
EOF
chmod +x "${TMP}/bundle"

cat > "${TMP}/cluster" <<EOF
#!/usr/bin/env bash
# fake tappaas-cluster-state.sh: the document the test wrote, or no answer
[[ -e "${TMP}/cluster-fails" ]] && exit 1
cat "${TMP}/cluster.json"
EOF
chmod +x "${TMP}/cluster"
# No node down: the cluster as it is most of the time.
echo '{"nodes":[{"name":"tappaas1","online":true},{"name":"tappaas2","online":true}],"quorate":true,"guests":[],"ha_log":[]}' > "${TMP}/cluster.json"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 "${R}" --listen "127.0.0.1:${PORT}" --token-file "${TMP}/token" \
    --notify "${TMP}/notify" --bundle "${TMP}/bundle" --breadcrumb "${TMP}/crumbs" --heartbeat-file "${TMP}/heartbeat" \
    --cluster "${TMP}/cluster" --node-down-dir "${TMP}/node-down" --cluster-cache 0 > "${TMP}/log" 2>&1 &
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

# #883: one condition from ALERT to RESOLVED, and the support bundle
: > "${TMP}/args"
post rotated "$(wh firing state HostSilent tappaas3)" >/dev/null
ck "a state alert names its condition" "yes" "$(grep -q -- '--key grafana:HostSilent:tappaas3$' "${TMP}/args" && echo yes || echo no)"
post rotated "$(wh resolved state HostSilent tappaas3)" >/dev/null
ck "…and its resolve closes it" "yes" "$(grep -q -- '--key grafana:HostSilent:tappaas3 --resolve' "${TMP}/args" && echo yes || echo no)"
post rotated "$(wh firing event QuorumLost tappaas1)" >/dev/null
ck "an event has no condition to close" "no" "$(tail -1 "${TMP}/args" | grep -q -- --key && echo yes || echo no)"
ck "…and no bundle without the label" "no" "$([[ -s "${TMP}/bundle-args" ]] && echo yes || echo no)"
bw="$(wh firing event QuorumLost tappaas2 | sed 's/"kind":"event"/"kind":"event","bundle":"true"/')"
ck "a bundle alert is acknowledged at once" "200" "$(post rotated "${bw}")"
for _ in $(seq 1 50); do grep -q 'QuorumLost on tappaas2' "${TMP}/args" 2>/dev/null && break; sleep 0.1; done
ck "…the bundle starts half an hour before it fired" "yes" "$(grep -q -- '--since 2026-10-04 17:30:00 UTC' "${TMP}/bundle-args" && echo yes || echo no)"
ck "…and the mail carries it" "yes" "$(grep 'QuorumLost on tappaas2' "${TMP}/args" | grep -q -- "--attach ${TMP}/b.tar.gz" && echo yes || echo no)"
ck "…and its subject does not show the bundle label" "ALERT: QuorumLost on tappaas2" "$(tail -1 "${TMP}/subjects")"

# A node down is one notice: tappaas2 dies with two plain guests, one HA guest
# the CRM moved to tappaas1 and one it has not moved yet (hrossen 2026-10-27:
# nine HostSilent ALERTs, then nine RESOLVEDs).
cat > "${TMP}/cluster.json" <<'EOF'
{"nodes":[{"name":"tappaas1","online":true},{"name":"tappaas2","online":false},{"name":"tappaas3","online":true}],"quorate":true,
 "guests":[{"vmid":140,"name":"identity","type":"qemu","node":"tappaas1","status":"running","ha":"started"},
           {"vmid":150,"name":"logging","type":"qemu","node":"tappaas1","status":"running","ha":""},
           {"vmid":350,"name":"forgejo","type":"qemu","node":"tappaas2","status":"unknown","ha":""},
           {"vmid":351,"name":"woodpecker","type":"qemu","node":"tappaas2","status":"unknown","ha":""},
           {"vmid":610,"name":"vaultwarden","type":"qemu","node":"tappaas2","status":"unknown","ha":"fence"}],
 "ha_log":["2026-10-27T13:02:00+01:00 tappaas1 pve-ha-crm[1]: recover service 'vm:150' from fenced node 'tappaas2' to node 'tappaas1'",
           "2026-10-27T13:05:00+01:00 tappaas1 pve-ha-crm[1]: node 'tappaas2': state changed from 'unknown' => 'online'",
           "2026-10-27T14:15:51+01:00 tappaas1 pve-ha-crm[1]: node 'tappaas2': state changed from 'online' => 'unknown'",
           "2026-10-27T14:18:00+01:00 tappaas1 pve-ha-crm[1]: recover service 'vm:140' from fenced node 'tappaas2' to node 'tappaas1'"]}
EOF
: > "${TMP}/args"; : > "${TMP}/subjects"; : > "${TMP}/bodies"
ck "a guest of a down node: accepted" "200" "$(post rotated "$(wh firing state HostSilent woodpecker)")"
for _ in $(seq 1 50); do grep -q 'node tappaas2' "${TMP}/subjects" 2>/dev/null && break; sleep 0.1; done
ck "…one notice for the node, counting what it took down" "ALERT: node tappaas2 is down (2 guests down, 1 moved by HA, 1 HA not moved yet)" "$(tail -1 "${TMP}/subjects")"
ck "…a condition of its own" "yes" "$(grep -q -- '--key grafana:NodeDown:tappaas2$' "${TMP}/args" && echo yes || echo no)"
ck "…naming when it went (not an earlier outage)" "yes" "$(grep -q 'saw it go at 2026-10-27T14:15:51' "${TMP}/bodies" && echo yes || echo no)"
ck "…the guests down with it" "  forgejo (350)|  woodpecker (351)" "$(sed -n '/^Down with it/,/^$/p' "${TMP}/bodies" | grep '^  ' | paste -sd'|' -)"
ck "…the HA guest moved, and where (an earlier outage's move is not listed)" "  identity (140)  tappaas2 -> tappaas1" "$(sed -n '/^HA-protected, moved/,/^$/p' "${TMP}/bodies" | grep '^  ')"
ck "…the HA guest not moved yet" "  vaultwarden (610)  HA state: fence" "$(sed -n '/^HA-protected, not moved/,/^$/p' "${TMP}/bodies" | grep '^  ')"
ck "the node's own silence: folded, not mailed" "200" "$(post rotated "$(wh firing state HostSilent tappaas2)")"
ck "another guest's silence: folded, not mailed" "200" "$(post rotated "$(wh firing state HostSilent forgejo)")"
ck "…still one mail" "1" "$(wc -l < "${TMP}/subjects" | tr -d ' ')"
ck "…the incident remembers who was silent" "woodpecker tappaas2 forgejo" "$(jq -r '.members | join(" ")' "${TMP}/node-down/tappaas2.json")"
ck "…each fold is a breadcrumb" "yes" "$(grep -q 'folded into node tappaas2 down: HostSilent on forgejo' "${TMP}/crumbs" && echo yes || echo no)"
ck "a silent host on a node that is up: mailed on its own" "ALERT: HostSilent on logging" \
   "$(post rotated "$(wh firing state HostSilent logging)" >/dev/null; tail -1 "${TMP}/subjects")"
post rotated "$(wh resolved state HostSilent woodpecker)" >/dev/null
ck "a folded guest back while the node is down: no node RESOLVED" "0" "$(grep -c 'RESOLVED: node' "${TMP}/subjects")"
# tappaas2 is back; vaultwarden did not start
sed -e 's/"online":false/"online":true/' -e 's/"unknown"/"running"/' "${TMP}/cluster.json" \
    | jq '.guests |= map(if .name == "vaultwarden" then .status = "stopped" else . end)' > "${TMP}/c2" && mv "${TMP}/c2" "${TMP}/cluster.json"
post rotated "$(wh resolved state HostSilent forgejo)" >/dev/null
ck "the node is back: one RESOLVED for it" "RESOLVED: node tappaas2 is back" "$(grep 'RESOLVED: node' "${TMP}/subjects")"
ck "…as the reply to its ALERT" "yes" "$(grep -q -- '--key grafana:NodeDown:tappaas2 --resolve' "${TMP}/args" && echo yes || echo no)"
ck "…naming a guest that did not come back" "yes" "$(grep -q '^  vaultwarden on tappaas2  (stopped)' "${TMP}/bodies" && echo yes || echo no)"
ck "…and the incident is closed" "no" "$([[ -e "${TMP}/node-down/tappaas2.json" ]] && echo yes || echo no)"
jq '.nodes |= map(if .name == "tappaas2" then .online = false else . end)' "${TMP}/cluster.json" > "${TMP}/c2" && mv "${TMP}/c2" "${TMP}/cluster.json"
: > "${TMP}/cluster-fails"
ck "the cluster cannot be asked: the host is mailed on its own, as before" "ALERT: HostSilent on forgejo" \
   "$(post rotated "$(wh firing state HostSilent forgejo)" >/dev/null; tail -1 "${TMP}/subjects")"
rm -f "${TMP}/cluster-fails"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
