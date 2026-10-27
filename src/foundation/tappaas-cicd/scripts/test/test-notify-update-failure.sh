#!/usr/bin/env bash
# test-notify-update-failure.sh — the failed-sweep notice (#651).
# A fake ssh stands in for the Proxmox nodes: it records each call and the mail
# it was handed, and refuses sendmail on the nodes listed in FAKE_DOWN.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
N="${HERE}/../notify-update-failure.sh"

pass=0; fail=0
ok()  { echo "  ✓ $1"; pass=$((pass+1)); }
bad() { echo "  ✗ $1"; fail=$((fail+1)); }

d="$(mktemp -d)"; trap 'rm -rf "${d}"' EXIT
mkdir -p "${d}/config"
cat > "${d}/fake-ssh" <<'FAKE'
#!/usr/bin/env bash
host=""; for a in "$@"; do case "$a" in root@*) host="${a#root@}"; host="${host%%.*}" ;; esac; done
cmd="${!#}"
echo "${host} ${cmd}" >> "${FAKE_LOG}"
case "${cmd}" in
  pvesh*) [[ -n "${FAKE_FROM:-}" ]] && printf '{"email_from":"%s"}\n' "${FAKE_FROM}" || echo '{}' ;;
  *sendmail*)
    for n in ${FAKE_DOWN:-}; do [[ "${n}" == "${host}" ]] && exit 75; done
    cat > "${FAKE_MAIL}" ;;
esac
FAKE
chmod +x "${d}/fake-ssh"
# The support bundle (#883) is its own suite (test-support-bundle.sh): here a
# fake writes a small file, or nothing when FAKE_NO_BUNDLE is set.
cat > "${d}/fake-bundle" <<'FAKE'
#!/usr/bin/env bash
[[ -n "${FAKE_NO_BUNDLE:-}" ]] && exit 1
f="${FAKE_BUNDLE_DIR}/tappaas-support-test.tar.gz"; echo "bundle bytes" > "${f}"; echo "${f}"
FAKE
chmod +x "${d}/fake-bundle"
export TAPPAAS_CONFIG_DIR="${d}/config" TAPPAAS_NOTIFY_SSH="${d}/fake-ssh" \
       FAKE_LOG="${d}/ssh.log" FAKE_MAIL="${d}/mail.txt" TAPPAAS_NOTIFY_NODES="tappaas1 tappaas2" \
       TAPPAAS_ALERT_STATE="${d}/open" TAPPAAS_SUPPORT_BUNDLE="${d}/fake-bundle" FAKE_BUNDLE_DIR="${d}"
site() { printf '{"name":"rossen","email":"%s"}\n' "$1" > "${d}/config/site.json"; }
run() { : > "${FAKE_LOG}"; rm -f "${FAKE_MAIL}"; MONITOR_SERVICE_RESULT=exit-code MONITOR_EXIT_STATUS=1 bash "${N}" "$@" >"${d}/out" 2>&1; }

cat > "${d}/config/last-update-result.json" <<'EOF'
{"ok": false, "failed": 1, "failed_modules": ["network"], "not_attempted": 3,
 "control_plane": "refreshed", "reboot": "ok",
 "shared_dependency_down": {"failures": [{"detail": "unbound-dns not answering"}], "culprit_module": "network"}}
EOF

# 1. the first node takes it
site "owner@example.org"
run; rc=$?
[[ ${rc} -eq 0 ]] && grep -q 'through tappaas1' "${d}/out" && ok "sent through the first node" || bad "first node: rc=${rc} $(cat "${d}/out")"
grep -q '^To: owner@example.org$' "${FAKE_MAIL}" && ok "addressed to site.json email" || bad "To header"
grep -q '^Subject: \[TAPPaaS example.org\] update sweep FAILED' "${FAKE_MAIL}" \
    && ok "subject names the site by domain (no environment: the address's domain)" || bad "subject: $(grep -i ^Subject: "${FAKE_MAIL}")"
grep -q '^Site: rossen (example.org) — host ' "${FAKE_MAIL}" \
    && ok "the body names the site and its domain" || bad "body Site line: $(grep -i '^Site:' "${FAKE_MAIL}")"
grep -q 'Failed modules: network' "${FAKE_MAIL}" && grep -q 'Shared dependency DOWN: unbound-dns not answering' "${FAKE_MAIL}" \
    && ok "body carries the failed modules and the shared-dependency detail" || bad "body detail"
grep -q 'result=exit-code exit=1' "${FAKE_MAIL}" && ok "body carries systemd's result" || bad "systemd result"
grep -q 'failure notice sent to owner@example.org through tappaas1' "${d}/config/update-tappaas.failures" \
    && ok "the breadcrumb records the delivery" || bad "breadcrumb"
! grep -q '^From:' "${FAKE_MAIL}" && ok "no From header when Proxmox has no email_from" || bad "unexpected From"

# 1b. --degraded: the run completed, some app modules failed (exit 3)
: > "${d}/config/update-tappaas.failures"
: > "${FAKE_LOG}"; rm -f "${FAKE_MAIL}"
EXIT_STATUS=3 SERVICE_RESULT=success bash "${N}" --degraded >"${d}/out" 2>&1
grep -q '^Subject: \[TAPPaaS example.org\] update sweep: 1 module(s) failed' "${FAKE_MAIL}" \
    && ok "a degraded run has its own subject" || bad "degraded subject: $(grep -i ^Subject: "${FAKE_MAIL}")"
grep -q 'completed at .*, but 1 app module(s) failed' "${FAKE_MAIL}" && grep -q 'result=success exit=3' "${FAKE_MAIL}" \
    && ok "…says the run completed, with ExecStopPost's result" || bad "degraded body: $(head -3 "${FAKE_MAIL}")"
grep -q 'DEGRADED — 1 app module(s) failed' "${d}/config/update-tappaas.failures" \
    && ok "…and is recorded in update-tappaas.failures" || bad "degraded breadcrumb: $(cat "${d}/config/update-tappaas.failures")"

# 2. Proxmox's configured sender is used
FAKE_FROM="pve@example.org" run
grep -q '^From: TAPPaaS <pve@example.org>$' "${FAKE_MAIL}" && ok "From is Proxmox's email_from" || bad "From header"

# 3. the first node refuses, the second takes it
FAKE_DOWN="tappaas1" run; rc=$?
[[ ${rc} -eq 0 ]] && grep -q 'through tappaas2' "${d}/out" && ok "falls through to the next node" || bad "fallback: rc=${rc}"

# 4. no node takes it
FAKE_DOWN="tappaas1 tappaas2" run; rc=$?
[[ ${rc} -eq 1 ]] && grep -q 'NOT sent: no node accepted' "${d}/config/update-tappaas.failures" && ok "no node: exit 1 and recorded" || bad "no node: rc=${rc}"

# 4b. a run that stopped in the rebuild names it and records it
echo rebuild > "${d}/config/.update-stage"
run
grep -q "Stopped in: the mothership's nixos-rebuild" "${FAKE_MAIL}" && ok "the notice names the rebuild stage" || bad "stage line"
[[ "$(jq -r '.stage + " " + (.ok|tostring)' "${d}/config/last-update-result.json")" == "rebuild false" ]] \
    && ok "the result file records the failed stage" || bad "result not rewritten: $(cat "${d}/config/last-update-result.json")"
[[ ! -e "${d}/config/.update-stage" ]] && ok "the stage marker is consumed" || bad "stage marker left"

# 4c. a site name cannot add a header
printf '{"name":"x\\nBcc: spy@example.org","email":"owner@example.org"}\n' > "${d}/config/site.json"
run
! grep -qi '^Bcc:' "${FAKE_MAIL}" \
    && ok "a site name with a header in it never reaches the headers" || bad "site name reached the headers"
grep -q '^Subject: \[TAPPaaS example.org\] update sweep FAILED' "${FAKE_MAIL}" \
    && ok "…and the subject falls back to the domain of the notice address" || bad "fallback label"

# 4d. the domain comes from the default environment, then mgmt (#688)
mkdir -p "${d}/config/environments"
site "owner@example.org"
printf '{"name":"mgmt","domains":{"primary":"mgmt.example.net"}}\n' > "${d}/config/environments/mgmt.json"
run
grep -q '^Subject: \[TAPPaaS mgmt.example.net\]' "${FAKE_MAIL}" \
    && ok "with no default environment, mgmt's domain names the site" || bad "mgmt domain: $(grep -i ^Subject: "${FAKE_MAIL}")"

printf '{"name":"rossen","email":"owner@example.org","defaultEnvironment":"rossen"}\n' > "${d}/config/site.json"
printf '{"name":"rossen","domains":{"primary":"hrossen.dk"}}\n' > "${d}/config/environments/rossen.json"
run
grep -q '^Subject: \[TAPPaaS hrossen.dk\] update sweep FAILED' "${FAKE_MAIL}" \
    && ok "the default environment's domain wins over mgmt's" || bad "default env domain: $(grep -i ^Subject: "${FAKE_MAIL}")"
grep -q '^Site: rossen (hrossen.dk) — host ' "${FAKE_MAIL}" \
    && ok "…and the body says which site this is" || bad "body Site line"

# 4e. a domain cannot add a header either
printf '{"name":"rossen","domains":{"primary":"evil.example\\nBcc: spy@example.org"}}\n' > "${d}/config/environments/rossen.json"
run
! grep -qi '^Bcc:' "${FAKE_MAIL}" \
    && ok "a domain with a header in it never reaches the headers" || bad "domain reached the headers"
grep -q '^Subject: \[TAPPaaS rossen\] update sweep FAILED' "${FAKE_MAIL}" \
    && ok "…and the subject falls back to the site code" || bad "domain fallback"
rm -rf "${d}/config/environments"

# 5. no email, or not a plain address
site ""; run; rc=$?
[[ ${rc} -eq 0 && ! -s "${FAKE_LOG}" ]] && ok "no email: nothing sent, exit 0" || bad "no email: rc=${rc}"
site 'a@b.org\nBcc: x@y.org'; run; rc=$?
[[ ${rc} -eq 1 && ! -s "${FAKE_LOG}" ]] && ok "an address with a header in it is refused" || bad "header injection: rc=${rc}"

# 6. one condition from failure to RESOLVED, with its bundle (#883)
rm -rf "${d}/open"
printf '{"name":"rossen","email":"owner@example.org","supportEmail":"help@tappaas.example"}\n' > "${d}/config/site.json"
echo '{"ok": false, "failed": 1, "failed_modules": ["network"]}' > "${d}/config/last-update-result.json"
touch -d '-1 minute' "${d}/config/last-update-result.json"
run
[[ -f "${d}/open/update-sweep" ]] && ok "a failure notice opens update-sweep" || bad "no open state: $(ls "${d}/open" 2>&1)"
alert_id="$(jq -r .message_id "${d}/open/update-sweep" 2>/dev/null)"
grep -q "^Message-ID: ${alert_id}$" "${FAKE_MAIL}" && ok "…and the mail carries the Message-ID it recorded" || bad "Message-ID: ${alert_id}"
grep -q '^Content-Type: multipart/mixed' "${FAKE_MAIL}" && grep -q 'filename="tappaas-support-test.tar.gz"' "${FAKE_MAIL}" \
    && ok "the notice carries the support bundle as an attachment" || bad "no attachment: $(grep -i content- "${FAKE_MAIL}")"
grep -q "$(printf 'bundle bytes\n' | base64)" "${FAKE_MAIL}" && ok "…base64-encoded" || bad "attachment body"
grep -q 'attachment to help@tappaas.example' "${FAKE_MAIL}" && ok "…and says to forward it to site.json supportEmail" || bad "forward line"

: > "${FAKE_LOG}"; rm -f "${FAKE_MAIL}"
bash "${N}" --resolved >"${d}/out" 2>&1
[[ ! -e "${FAKE_MAIL}" && -f "${d}/open/update-sweep" ]] && ok "--resolved: no sweep since the failure, nothing sent" || bad "resolved too early: $(cat "${d}/out")"

echo '{"ok": false, "failed": 2}' > "${d}/config/last-update-result.json"
bash "${N}" --resolved >"${d}/out" 2>&1
[[ ! -e "${FAKE_MAIL}" ]] && ok "--resolved: a sweep that failed again clears nothing" || bad "resolved a failed sweep"

echo '{"ok": true, "failed": 0, "succeeded": 30, "total": 30, "end_time": "2026-10-27 03:03:29"}' > "${d}/config/last-update-result.json"
bash "${N}" --resolved >"${d}/out" 2>&1
grep -q '^Subject: \[TAPPaaS .*\] RESOLVED: update sweep OK again' "${FAKE_MAIL}" && ok "a clean sweep sends the RESOLVED" || bad "no RESOLVED: $(cat "${d}/out")"
grep -q "^In-Reply-To: ${alert_id}$" "${FAKE_MAIL}" && grep -q "^References: ${alert_id}$" "${FAKE_MAIL}" \
    && ok "…as a reply to the failure notice" || bad "threading: $(grep -iE '^(In-Reply-To|References):' "${FAKE_MAIL}")"
! grep -q multipart "${FAKE_MAIL}" && ok "…with no bundle" || bad "RESOLVED carries a bundle"
[[ ! -e "${d}/open/update-sweep" ]] && ok "…and closes the condition" || bad "still open"

rm -f "${FAKE_MAIL}"
bash "${N}" --resolved >"${d}/out" 2>&1
[[ ! -e "${FAKE_MAIL}" ]] && ok "the next clean sweep sends nothing" || bad "a second RESOLVED"

FAKE_NO_BUNDLE=1 run
grep -q '^Content-Type: text/plain' "${FAKE_MAIL}" && grep -q 'update sweep FAILED' "${FAKE_MAIL}" \
    && ok "no bundle could be made: the notice goes without one" || bad "bundle failure stopped the notice"

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
