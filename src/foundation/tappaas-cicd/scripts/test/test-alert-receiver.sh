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

cat > "${TMP}/health" <<EOF
#!/usr/bin/env bash
# fake health-manager: record each call
printf '%s\n' "\$*" >> "${TMP}/health-calls"
case "\$*" in
    "digest --json") cat "${TMP}/digest.json" ;;
    "digest --mark") cat > "${TMP}/digest-marked" ;;
esac
EOF
chmod +x "${TMP}/health"
mkdir -p "${TMP}/cfg"
echo '{"vmname":"site1","moduleSource":"/c/hosting"}' > "${TMP}/cfg/shop.json"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 "${R}" --listen "127.0.0.1:${PORT}" --token-file "${TMP}/token" \
    --notify "${TMP}/notify" --bundle "${TMP}/bundle" --breadcrumb "${TMP}/crumbs" --heartbeat-file "${TMP}/heartbeat" \
    --cluster "${TMP}/cluster" --node-down-dir "${TMP}/node-down" --cluster-cache 0 --alerts-log "${TMP}/alerts.jsonl" --siem-state "${TMP}/siem.json" \
    --health "${TMP}/health" --config-dir "${TMP}/cfg" --silent-hold 0 --burst-min 1000 \
    --maintenance-dir "${TMP}/maint" --silent-burst-file "${TMP}/burst.json" > "${TMP}/log" 2>&1 &
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

# Security hits (ADR-050 D12): one entry per rule and CI, with the count.
sec() {  # sec <status> <level> <host> — a security rule's webhook body
    printf '{"status":"%s","alerts":[{"status":"%s","labels":{"alertname":"SshBruteForce","host":"%s","kind":"event","module":"logging","type":"security","level":"%s","src_ip":"203.0.113.9"},"annotations":{"summary":"brute force"},"startsAt":"2026-11-12T08:00:00Z"}]}' "$1" "$1" "$3" "$2"
}
post sekret "$(sec firing warning nextcloud)" >/dev/null
post sekret "$(sec firing critical nextcloud)" >/dev/null
post sekret "$(sec resolved critical nextcloud)" >/dev/null
ck "two security hits are one entry" "1" "$(jq '.findings | length' "${TMP}/siem.json")"
ck "…counted twice (a resolve is no hit)" "2" "$(jq '.findings[].count' "${TMP}/siem.json")"
ck "…at the last hit's level" "critical" "$(jq -r '.findings[].level' "${TMP}/siem.json")"
ck "…with what it captured, not type or level" '{"src_ip":"203.0.113.9"}' "$(jq -c '.findings[].labels' "${TMP}/siem.json")"
ck "an alert that is not security is no hit" "1" "$(jq '.findings | length' "${TMP}/siem.json")"
jq '.findings[].last = "2026-01-01T00:00:00+00:00"' "${TMP}/siem.json" > "${TMP}/s2" && mv "${TMP}/s2" "${TMP}/siem.json"
post sekret "$(sec firing warning identity)" >/dev/null
ck "an entry past its keep is pruned on the next hit" "identity" "$(jq -r '.findings[].host' "${TMP}/siem.json")"
n="$(sent)"
ck "an info hit is accepted" "200" "$(post sekret "$(sec firing info jellyfin)")"
ck "…recorded" "info" "$(jq -r '.findings[] | select(.host == "jellyfin") | .level' "${TMP}/siem.json")"
ck "…and not mailed" "${n}" "$(sent)"
ck "a warning hit is mailed" "200" "$(post sekret "$(sec firing warning jellyfin)")"
ck "…as any alert" "$((n + 1))" "$(sent)"

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

ck "every alert is recorded for health-manager alerts (ADR-039 D8)" "QuorumLost tappaas1 event" \
   "$(jq -r 'select(.alertname == "QuorumLost") | "\(.alertname) \(.host) \(.kind)"' "${TMP}/alerts.jsonl" | head -1)"
ck "…resolves too" "yes" "$(jq -e -s 'any(.[]; .status == "resolved" and .alertname == "HostSilent")' "${TMP}/alerts.jsonl" >/dev/null && echo yes || echo no)"
n="$(sent)"
ck "a heartbeat is accepted" "200" "$(post rotated "$(wh firing heartbeat Heartbeat '')")"
ck "…recorded" "2026-10-04T18:00:00Z" "$(cat "${TMP}/heartbeat" 2>/dev/null)"
ck "…and never mailed" "${n}" "$(sent)"
ck "…nor recorded as an alert" "0" "$(jq -s '[.[] | select(.alertname == "Heartbeat")] | length' "${TMP}/alerts.jsonl")"
both='{"status":"firing","alerts":[{"status":"firing","labels":{"alertname":"Heartbeat","kind":"heartbeat"},"startsAt":"2026-10-04T19:00:00Z"},{"status":"firing","labels":{"alertname":"QuorumLost","host":"tappaas2","kind":"event"},"startsAt":"2026-10-04T19:00:00Z"}]}'
ck "a heartbeat next to a real alert does not hide it" "200" "$(post rotated "${both}")"
ck "…the real one is mailed" "ALERT: QuorumLost on tappaas2" "$(tail -1 "${TMP}/subjects")"

# Grafana's error alert for the Heartbeat rule carries the rule's labels; it
# says the rules cannot run, so it must not pass for a heartbeat (#905).
n="$(sent)"
dse='{"status":"firing","alerts":[{"status":"firing","labels":{"alertname":"DatasourceError","rulename":"Heartbeat","kind":"heartbeat"},"startsAt":"2026-10-04T20:00:00Z"}]}'
ck "a Heartbeat's DatasourceError is accepted" "200" "$(post rotated "${dse}")"
ck "…but not recorded as a heartbeat" "2026-10-04T19:00:00Z" "$(cat "${TMP}/heartbeat" 2>/dev/null)"
ck "…and not mailed (the watchdog speaks for it)" "${n}" "$(sent)"
ck "a resolved Heartbeat is not a heartbeat either" "200" "$(post rotated "$(wh resolved heartbeat Heartbeat '')")"
ck "…the file keeps the last firing one" "2026-10-04T19:00:00Z" "$(cat "${TMP}/heartbeat" 2>/dev/null)"

ck "--render prints the mail" "Subject: ALERT: QuorumLost on tappaas1" \
   "$(wh firing event QuorumLost tappaas1 | python3 "${R}" --render | head -1)"
rep='{"status":"firing","alerts":[{"status":"firing","labels":{"alertname":"ReplicationFailed","host":"tappaas1","replication_job":"110-0","kind":"state","grafana_folder":"TAPPaaS","__alert_rule_uid__":"x"},"annotations":{"summary":"s"},"startsAt":"2026-10-08T00:31:00Z"}]}'
ck "a series label names WHICH one in the subject (replication job)" "Subject: ALERT: ReplicationFailed on tappaas1 (replication_job 110-0)" \
   "$(python3 "${R}" --render <<<"${rep}" | head -1)"
ck "…and in the body; grafana's own labels stay out" "replication_job: 110-0" "$(python3 "${R}" --render <<<"${rep}" | grep -E '^(replication_job|grafana_folder|__alert)' | paste -sd' ' -)"
ck "a rule's headline names it in the subject, after ALERT:" "Subject: ALERT: Out of Memory Kill on openwebui" \
   "$(wh firing event OomKill openwebui | sed 's/"query":/"headline":"Out of Memory Kill","query":/' | python3 "${R}" --render | head -1)"

# ADR-039 D7: a module's rule — its own mail, its labels, its log lines.
modwh='{"status":"firing","alerts":[{"status":"firing","labels":{"alertname":"Release signature rejected","host":"site1","kind":"event","module":"hosting","site":"shop"},"annotations":{"summary":"A release was refused.","query":"{host=~\"^(site1)$\"} |~ \"rejected\""},"startsAt":"2026-10-29T10:00:00Z"}]}'
ck "a module rule without a template: today's mail; module stays out of the subject" "Subject: ALERT: Release signature rejected on site1 (site shop)" \
   "$(python3 "${R}" --render <<<"${modwh}" | head -1)"
tpl="$(jq -c '.alerts[0].annotations.mailSubject = "{state}: {title} for site {label.site} ({module})" | .alerts[0].annotations.mailBody = "Site {label.site} on {host}: {summary}\nsince {since}"' <<<"${modwh}")"
ck "a template fills the subject" "Subject: ALERT: Release signature rejected for site shop (hosting)" \
   "$(python3 "${R}" --render <<<"${tpl}" | head -1)"
ck "…and the body" "Site shop on site1: A release was refused." "$(python3 "${R}" --render <<<"${tpl}" | sed -n 3p)"
ck "…and the Explore query is still in it" "yes" "$(python3 "${R}" --render <<<"${tpl}" | grep -c 'Explore, Loki): {host=~' >/dev/null && echo yes || echo no)"
odd="$(jq -c '.alerts[0].annotations.mailSubject = "{nope} {title}"' <<<"${modwh}")"
ck "an unknown placeholder is left as written, never evaluated" "Subject: {nope} Release signature rejected" "$(python3 "${R}" --render <<<"${odd}" | head -1)"
lw="$(jq -c '.alerts[0].labels.lines = "true"' <<<"${modwh}")"
ck "lines=true without lines to give: the body says so" "yes" \
   "$(python3 "${R}" --render <<<"${lw}" | grep -cF '(log lines not mailed on this site' >/dev/null && echo yes || echo no)"
printf 'GET /shop from 203.0.113.9 by person-1\n' > "${TMP}/lines"
ck "lines=true with lines: under Log lines (anonymized)" "GET /shop from 203.0.113.9 by person-1" \
   "$(python3 "${R}" --render --lines-file "${TMP}/lines" <<<"${lw}" | sed -n '/^Log lines (anonymized):/{n;p;}')"
ck "a module label 'lines' stays out of the subject" "Subject: ALERT: Release signature rejected on site1 (site shop)" \
   "$(python3 "${R}" --render --lines-file "${TMP}/lines" <<<"${lw}" | head -1)"
# The site flag and the anonymizer, through the receiver's own fetcher.
mkdir -p "${TMP}/cfgL"; printf '{"name":"x"}\n' > "${TMP}/cfgL/site.json"
flag="$(python3 -I - "${R}" "${TMP}/cfgL" <<'PY'
import importlib.util, sys, types
s = importlib.util.spec_from_file_location("rx", sys.argv[1]); rx = importlib.util.module_from_spec(s); s.loader.exec_module(rx)
print(rx.lines_allowed(sys.argv[2]))
PY
)"
ck "site.json without alerts.includeLines: no lines" "False" "${flag}"
printf '{"name":"x","alerts":{"includeLines":true}}\n' > "${TMP}/cfgL/site.json"
flag="$(python3 -I - "${R}" "${TMP}/cfgL" <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location("rx", sys.argv[1]); rx = importlib.util.module_from_spec(s); s.loader.exec_module(rx)
print(rx.lines_allowed(sys.argv[2]))
PY
)"
ck "alerts.includeLines true: lines allowed" "True" "${flag}"
anon="$(python3 -I - "${R}" "${TMP}/cfgL" "${TMP}/bundle" <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location("rx", sys.argv[1]); rx = importlib.util.module_from_spec(s); s.loader.exec_module(rx)
print(rx._anonymizer(sys.argv[2], sys.argv[3]).text("login by alice@example.org from 81.2.69.160 password=hunter2"))
PY
)"
ck "mailed lines go through support-anonymize.py" "yes" \
   "$([[ "${anon}" != *alice@example.org* && "${anon}" != *hunter2* && "${anon}" != *81.2.69.160* ]] && echo yes || echo "no: ${anon}")"

# #883: one condition from ALERT to RESOLVED, and the support bundle
: > "${TMP}/args"
post rotated "$(wh firing state HostSilent tappaas3)" >/dev/null
ck "a state alert names its condition" "yes" "$(grep -q -- '--key grafana:HostSilent:tappaas3$' "${TMP}/args" && echo yes || echo no)"
post rotated "$(wh resolved state HostSilent tappaas3)" >/dev/null
ck "…and its resolve closes it" "yes" "$(grep -q -- '--key grafana:HostSilent:tappaas3 --resolve' "${TMP}/args" && echo yes || echo no)"
post rotated "$(wh firing event QuorumLost tappaas1)" >/dev/null
ck "an event has no condition to close" "no" "$(tail -1 "${TMP}/args" | grep -c -- --key >/dev/null && echo yes || echo no)"
ck "…and no bundle without the label" "no" "$([[ -s "${TMP}/bundle-args" ]] && echo yes || echo no)"
bw="$(wh firing event QuorumLost tappaas2 | sed 's/"kind":"event"/"kind":"event","bundle":"true"/')"
ck "a bundle alert is acknowledged at once" "200" "$(post rotated "${bw}")"
for _ in $(seq 1 50); do grep -q 'QuorumLost on tappaas2' "${TMP}/args" 2>/dev/null && break; sleep 0.1; done
ck "…the bundle starts half an hour before it fired" "yes" "$(grep -q -- '--since 2026-10-04 17:30:00 UTC' "${TMP}/bundle-args" && echo yes || echo no)"
ck "…and the mail carries it" "yes" "$(grep 'QuorumLost on tappaas2' "${TMP}/args" | grep -c -- "--attach ${TMP}/b.tar.gz" >/dev/null && echo yes || echo no)"
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
# A node down that is then removed from the cluster: closed as left, not back.
post rotated "$(wh firing state HostSilent tappaas2)" >/dev/null
jq '.nodes |= map(select(.name != "tappaas2"))' "${TMP}/cluster.json" > "${TMP}/c2" && mv "${TMP}/c2" "${TMP}/cluster.json"
post rotated "$(wh resolved state HostSilent tappaas2)" >/dev/null
ck "a node that left the cluster closes its incident as left, not back" "RESOLVED: node tappaas2 left the cluster" "$(grep 'RESOLVED: node tappaas2 left' "${TMP}/subjects")"
ck "…and the incident is gone" "no" "$([[ -e "${TMP}/node-down/tappaas2.json" ]] && echo yes || echo no)"

# The health hook (ADR-041 D2): every alert, ALERT or RESOLVED, assesses what it
# is about and then emits; the worker runs apart from the webhook.
hooked() {  # hooked <webhook>: the calls it makes, one line
    : > "${TMP}/health-calls"
    post rotated "$1" >/dev/null
    for _ in $(seq 1 20); do grep -q '^emit' "${TMP}/health-calls" && break; sleep 0.1; done
    paste -sd'|' - < "${TMP}/health-calls"
}
ck "an alert assesses what it is about (placed by health-manager), then emits" "assess --alert site1,|emit" "$(hooked "$(wh firing state HostSilent site1)")"
ck "…a RESOLVED too" "assess --alert site1,|emit" "$(hooked "$(wh resolved state HostSilent site1)")"
ck "an alert with neither host nor module assesses the site" "assess|emit" "$(hooked "$(wh firing event Oom '')")"
ck "health-manager's own rule runs nothing" "" "$(hooked "$(wh firing event HealthRootCause tappaas-cicd)")"

# The daily digest: health-manager writes the mail, and hears what went out.
digest='{"labels":{"alertname":"HealthDailyDigest","host":"tappaas-cicd","kind":"event"},"annotations":{"mailSubject":"{state}: daily digest could not be built","mailBody":"the template"},"status":"firing","startsAt":"2026-11-02T13:00:00Z"}'
digest_wh="{\"status\":\"firing\",\"alerts\":[${digest}]}"
waited() {  # waited <file> <text>: wait for the worker to write it
    for _ in $(seq 1 30); do grep -q -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done
    return 1
}
echo '{"subject":"STATUS: daily digest, nothing new, 2 still open","body":"NOTHING NEW\n","keys":["a","b"]}' > "${TMP}/digest.json"
: > "${TMP}/health-calls"
post rotated "${digest_wh}" >/dev/null
waited "${TMP}/subjects" "STATUS: daily digest"
ck "the digest's subject is health-manager's" "STATUS: daily digest, nothing new, 2 still open" "$(tail -1 "${TMP}/subjects")"
ck "…and its body" "yes" "$(grep -q '^NOTHING NEW' "${TMP}/bodies" && echo yes || echo no)"
waited "${TMP}/health-calls" "digest --mark"
ck "…what went out is marked, and nothing is assessed" "digest --json|digest --mark" "$(paste -sd'|' - < "${TMP}/health-calls")"
waited "${TMP}/digest-marked" "keys"
ck "…the keys it told" "a b" "$(jq -r '.keys | join(" ")' "${TMP}/digest-marked")"
echo 'not json' > "${TMP}/digest.json"
: > "${TMP}/health-calls"
post rotated "${digest_wh}" >/dev/null
waited "${TMP}/subjects" "could not be built"
ck "health-manager cannot say: the rule's template goes out" "ALERT: daily digest could not be built" "$(tail -1 "${TMP}/subjects")"
sleep 0.3
ck "…and nothing is marked" "digest --json" "$(paste -sd'|' - < "${TMP}/health-calls")"

# ── planned disruption and many hosts silent at once ────────────────────
# A second receiver that holds a HostSilent for a second before mailing it.
kill "${PID}" 2>/dev/null; wait "${PID}" 2>/dev/null
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 "${R}" --listen "127.0.0.1:${PORT}" --token-file "${TMP}/token" \
    --notify "${TMP}/notify" --bundle "${TMP}/bundle" --breadcrumb "${TMP}/crumbs2" --heartbeat-file "${TMP}/heartbeat" \
    --cluster "${TMP}/cluster" --node-down-dir "${TMP}/node-down2" --cluster-cache 0 --alerts-log "${TMP}/alerts2.jsonl" --siem-state "${TMP}/siem2.json" \
    --health "" --config-dir "${TMP}/cfg" --silent-hold 1 --burst-min 3 --burst-window 60 \
    --maintenance-dir "${TMP}/maint2" --silent-burst-file "${TMP}/burst2.json" > "${TMP}/log2" 2>&1 &
PID=$!
for _ in $(seq 1 50); do curl -s "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 && break; sleep 0.1; done
TOKEN="$(cat "${TMP}/token")"
echo '{"nodes":[{"name":"tappaas1","online":true},{"name":"tappaas2","online":true}],"quorate":true,"guests":[],"ha_log":[]}' > "${TMP}/cluster.json"
MW="${HERE}/../tappaas-maintenance.sh"
: > "${TMP}/subjects"; : > "${TMP}/args"

# A maintenance window for the whole site: a HostSilent is recorded, not mailed.
TAPPAAS_MAINTENANCE_DIR="${TMP}/maint2" "${MW}" open --name restart-network --scope site --minutes 5 --reason "network restarted by its update"
ck "a window is listed" "restart-network	site" "$(TAPPAAS_MAINTENANCE_DIR="${TMP}/maint2" "${MW}" list | cut -f1,2)"
post "${TOKEN}" "$(wh firing state HostSilent immich)" >/dev/null
post "${TOKEN}" "$(wh resolved state HostSilent immich)" >/dev/null
sleep 1.5
ck "inside a site window, a HostSilent is not mailed" "0" "$(grep -c '^ALERT: HostSilent' "${TMP}/subjects")"
ck "…its RESOLVED is only a reply, which site-notify drops with no ALERT open" "yes" "$(grep -q -- '--key grafana:HostSilent:immich --resolve' "${TMP}/args" && echo yes || echo no)"
ck "…and the fold is on record" "yes" "$(grep -q 'folded into maintenance (network restarted by its update): HostSilent on immich' "${TMP}/crumbs2" && echo yes || echo no)"
TAPPAAS_MAINTENANCE_DIR="${TMP}/maint2" "${MW}" close --name restart-network
# A window for one host covers that host only.
TAPPAAS_MAINTENANCE_DIR="${TMP}/maint2" "${MW}" open --name restart-forgejo --scope forgejo --minutes 5
post "${TOKEN}" "$(wh firing state HostSilent forgejo)" >/dev/null
sleep 1.5
ck "a host window covers its host" "0" "$(grep -c 'HostSilent on forgejo' "${TMP}/subjects")"
TAPPAAS_MAINTENANCE_DIR="${TMP}/maint2" "${MW}" close --name restart-forgejo
ck "a closed window is gone" "" "$(TAPPAAS_MAINTENANCE_DIR="${TMP}/maint2" "${MW}" list)"

# A node's cluster packages upgraded: its QuorumLost is held, another node's is not.
TAPPAAS_MAINTENANCE_DIR="${TMP}/maint2" "${MW}" open --name upgrade-tappaas1 --scope tappaas1 --minutes 10 --reason "tappaas1's cluster packages upgraded (corosync)"
: > "${TMP}/subjects"
post "${TOKEN}" "$(wh firing event QuorumLost tappaas1)" >/dev/null
post "${TOKEN}" "$(wh firing event QuorumLost tappaas2)" >/dev/null
for _ in $(seq 1 30); do grep -q 'QuorumLost on tappaas2' "${TMP}/subjects" && break; sleep 0.1; done
ck "inside its node's window, QuorumLost is not mailed" "0" "$(grep -c 'QuorumLost on tappaas1' "${TMP}/subjects")"
ck "…a node outside any window still alerts" "1" "$(grep -c 'QuorumLost on tappaas2' "${TMP}/subjects")"
ck "…and the hold is on record" "yes" "$(grep -q 'folded into maintenance (tappaas1.s cluster packages upgraded (corosync)): QuorumLost on tappaas1' "${TMP}/crumbs2" && echo yes || echo no)"
TAPPAAS_MAINTENANCE_DIR="${TMP}/maint2" "${MW}" close --name upgrade-tappaas1
: > "${TMP}/subjects"

# One host silent on its own: mailed, after the hold.
post "${TOKEN}" "$(wh firing state HostSilent vaultwarden)" >/dev/null
ck "a lone HostSilent waits for the hold" "0" "$(grep -c 'HostSilent on vaultwarden' "${TMP}/subjects")"
for _ in $(seq 1 40); do grep -q 'HostSilent on vaultwarden' "${TMP}/subjects" && break; sleep 0.1; done
ck "…and is then mailed on its own" "1" "$(grep -c 'HostSilent on vaultwarden' "${TMP}/subjects")"
post "${TOKEN}" "$(wh resolved state HostSilent vaultwarden)" >/dev/null
rm -f "${TMP}/burst2.json"; : > "${TMP}/subjects"; : > "${TMP}/args"

# Three hosts silent within the window, their nodes up: one notice.
for h in nextcloud identity litellm; do post "${TOKEN}" "$(wh firing state HostSilent "${h}")" >/dev/null; done
for _ in $(seq 1 40); do grep -q 'hosts stopped logging at once' "${TMP}/subjects" && break; sleep 0.1; done
ck "three hosts silent at once make one ALERT" "ALERT: 3 hosts stopped logging at once" "$(grep 'at once' "${TMP}/subjects")"
ck "…a condition of its own" "yes" "$(grep -q -- '--key grafana:SilentBurst:site$' "${TMP}/args" && echo yes || echo no)"
ck "…naming every host" "yes" "$(grep -q '  identity' "${TMP}/bodies" && grep -q '  litellm' "${TMP}/bodies" && grep -q '  nextcloud' "${TMP}/bodies" && echo yes || echo no)"
sleep 1.5
ck "the held ones fold into it: no HostSilent of their own" "0" "$(grep -c '^ALERT: HostSilent' "${TMP}/subjects")"
post "${TOKEN}" "$(wh firing state HostSilent jellyfin)" >/dev/null
sleep 1.5
ck "a host silent later joins the open notice" "0" "$(grep -c 'HostSilent on jellyfin' "${TMP}/subjects")"
ck "…and is listed in it" "true" "$(jq -r '.members | index("jellyfin") != null' "${TMP}/burst2.json")"
# Past the burst window, a host that falls silent is a fault of its own.
jq '.mailed -= 120' "${TMP}/burst2.json" > "${TMP}/b2" && mv "${TMP}/b2" "${TMP}/burst2.json"
post "${TOKEN}" "$(wh firing state HostSilent immich)" >/dev/null
for _ in $(seq 1 40); do grep -q 'HostSilent on immich' "${TMP}/subjects" && break; sleep 0.1; done
ck "a host silent after the burst's window is mailed on its own" "1" "$(grep -c 'HostSilent on immich' "${TMP}/subjects")"
ck "…and does not join the burst" "false" "$(jq -r '.members | index("immich") != null' "${TMP}/burst2.json")"
post "${TOKEN}" "$(wh resolved state HostSilent immich)" >/dev/null
for h in nextcloud identity litellm; do post "${TOKEN}" "$(wh resolved state HostSilent "${h}")" >/dev/null; done
ck "not all back: no RESOLVED yet" "0" "$(grep -c 'log again' "${TMP}/subjects")"
post "${TOKEN}" "$(wh resolved state HostSilent jellyfin)" >/dev/null
ck "all back: one RESOLVED" "RESOLVED: 4 hosts log again" "$(grep 'log again' "${TMP}/subjects")"
ck "…as the reply to its ALERT" "yes" "$(grep -q -- '--key grafana:SilentBurst:site --resolve' "${TMP}/args" && echo yes || echo no)"
ck "…and the burst is closed" "{}" "$(jq -c . "${TMP}/burst2.json")"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
