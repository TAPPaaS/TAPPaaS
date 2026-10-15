#!/usr/bin/env bash
# test-pulse.sh — the pulse (ADR-031) against stubbed probes and a stubbed mailer:
# down only after downAfter, one mail then a daily repeat, "back" when it answers,
# both operators for a buddy, no buddy verdict while our own uplink is down, and
# the mothership's longer grace.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PULSE="${HERE}/pulse.sh"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $1 (got '$2', want '$3')"; fi; }

cat > "${T}/pulse.json" <<'EOF'
{ "site": "home", "email": "me@home.example", "uplink": "deb.debian.org",
  "firewall": "10.0.0.1", "mothership": "10.0.0.13", "pbs": "localhost",
  "buddies": [ { "name": "rasmus", "host": "10.255.2.1", "port": 8007, "fingerprint": "AA:BB", "contact": "r@buddy.example" },
               { "name": "quiet",  "host": "10.255.2.5" } ] }
EOF
# Probes answer unless their id is listed in ${T}/down.
cat > "${T}/probe" <<EOF
#!/usr/bin/env bash
grep -qx "\$1" "${T}/down" 2>/dev/null && exit 1; exit 0
EOF
cat > "${T}/mail" <<EOF
#!/usr/bin/env bash
{ cat; echo "----"; } >> "${T}/mails"
EOF
chmod +x "${T}/probe" "${T}/mail"
export PULSE_PROBE_CMD="${T}/probe" PULSE_SENDMAIL="${T}/mail" PULSE_STATE_DIR="${T}/state"
run() { PULSE_NOW="$1" bash "${PULSE}" --config "${T}/pulse.json" >/dev/null 2>&1; }
mails() { grep -c '^Subject:' "${T}/mails" 2>/dev/null; true; }
: > "${T}/down"; : > "${T}/mails"

t=1000000
run "${t}";                                    ck "all answer: no mail" "$(mails)" "0"
echo buddy-rasmus > "${T}/down"
run $((t+300));                                ck "a first failure is not a verdict" "$(mails)" "0"
run $((t+900));                                ck "10 minutes failing: still not down" "$(mails)" "0"
run $((t+1200));                               ck "15 minutes: one mail" "$(mails)" "1"
ck "…to both operators" "$(grep -c '^To: me@home.example,r@buddy.example$' "${T}/mails")" "1"
ck "…naming the buddy" "$(grep -c 'ALERT: backup buddy rasmus not answering' "${T}/mails")" "1"
run $((t+1500)); run $((t+5000));              ck "while down: no repeat within the day" "$(mails)" "1"
run $((t+1200+86400));                         ck "a day later: the repeat" "$(mails)" "2"
: > "${T}/down"
run $((t+1200+86700));                         ck "answers again: one RESOLVED mail" "$(grep -c 'RESOLVED: backup buddy rasmus' "${T}/mails")" "1"
run $((t+1200+87000));                         ck "…and nothing after" "$(mails)" "3"

# Our own uplink down: the buddy is not judged, the uplink is (own operator only).
: > "${T}/mails"; rm -rf "${T}/state"
printf 'uplink\nbuddy-quiet\n' > "${T}/down"
run "${t}"; run $((t+1200))
ck "uplink down: the uplink mail goes out" "$(grep -c 'ALERT: our internet not answering' "${T}/mails")" "1"
ck "…to our operator only" "$(grep -c '^To: me@home.example$' "${T}/mails")" "1"
ck "…and no verdict on a buddy we cannot reach anyway" "$(grep -c 'buddy quiet' "${T}/mails")" "0"

# The mothership gets 30 minutes, not 15.
: > "${T}/mails"; rm -rf "${T}/state"
echo mothership > "${T}/down"
run "${t}"; run $((t+1200));                   ck "mothership at 20 minutes: not yet" "$(mails)" "0"
run $((t+1800));                               ck "mothership at 30 minutes: mailed" "$(grep -c 'ALERT: the mothership' "${T}/mails")" "1"

# A mail that does not go out is retried.
: > "${T}/mails"; rm -rf "${T}/state"
echo firewall > "${T}/down"
run "${t}"
PULSE_SENDMAIL=false PULSE_NOW=$((t+1200)) bash "${PULSE}" --config "${T}/pulse.json" >/dev/null 2>&1
ck "a failed mail exits 1" "$?" "1"
run $((t+1500));                               ck "…and is sent on the next run" "$(grep -c 'ALERT: the firewall' "${T}/mails")" "1"

# A contact that is our own address is not mailed twice.
: > "${T}/mails"; rm -rf "${T}/state"
jq '.buddies[0].contact = "Me@Home.example"' "${T}/pulse.json" > "${T}/same.json"
echo buddy-rasmus > "${T}/down"
PULSE_NOW="${t}" bash "${PULSE}" --config "${T}/same.json" >/dev/null 2>&1
PULSE_NOW=$((t+1200)) bash "${PULSE}" --config "${T}/same.json" >/dev/null 2>&1
ck "our own address as the buddy's contact: one recipient" "$(grep -c '^To: me@home.example$' "${T}/mails")" "1"

# Standalone: a buddy's own config, nothing of the site.
cat > "${T}/alone.json" <<'EOF'
{ "site": "rasmus", "email": "r@buddy.example", "uplink": "deb.debian.org",
  "buddies": [ { "name": "home", "host": "10.255.2.1", "contact": "me@home.example" } ] }
EOF
PULSE_NOW="${t}" bash "${PULSE}" --config "${T}/alone.json" --status > "${T}/st" 2>&1
ck "standalone: the targets are its uplink and the buddy" "$(awk 'NR>1{print $1}' "${T}/st" | paste -sd, -)" "uplink,buddy-home"
bash "${PULSE}" --template | jq -e '.buddies[0].contact' >/dev/null; ck "the template is JSON with a contact" "$?" "0"
echo '[]' > "${T}/bad.json"
bash "${PULSE}" --config "${T}/bad.json" >/dev/null 2>&1; ck "a config that is not an object: exit 2" "$?" "2"

echo "Results: ${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]]
