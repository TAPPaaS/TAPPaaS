#!/usr/bin/env bash
# test-support-bundle.sh — tappaas-support-bundle.sh and support-anonymize.py (#883).
#
# A config directory full of personal data and secrets, a log that repeats
# them, and stubs for the commands that read the live site (journalctl,
# systemctl, module-manager): the bundle must carry the configuration and the
# log with all of it replaced, keep what a supporter debugs with, leave out the
# files that never go, and keep its map on the site. --test must send the
# ALERT with the bundle and then its RESOLVED.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B="${HERE}/../tappaas-support-bundle.sh"

pass=0; fail=0
ok()  { echo "  ✓ $1"; pass=$((pass+1)); }
bad() { echo "  ✗ $1"; fail=$((fail+1)); }
command -v python3 >/dev/null && command -v jq >/dev/null || { echo "needs python3 and jq"; exit 77; }

d="$(mktemp -d)"; trap 'rm -rf "${d}"' EXIT
c="${d}/config"; mkdir -p "${c}/environments" "${c}/identities/users" "${c}/people/users" "${c}/wgvpn" "${d}/logs" "${d}/bin"
cat > "${c}/site.json" <<'EOF'
{"name": "rossen", "defaultEnvironment": "rossen", "displayName": "Hansen Family", "owner": "Jonna Hansen",
 "email": "jonna.hansen@hansen.example", "supportEmail": "help@tappaas.example",
 "locations": {"elmstreet12": {"displayName": "Elm"}, "home": {"displayName": "Elmstreet house", "address": "Elmstreet 12", "city": "Springfield",
                        "latitude": 55.68, "longitude": 12.57, "timezone": "Europe/Copenhagen"}},
 "primaryLocation": "home", "repositories": [], "channel": "unstable"}
EOF
echo '{"name": "rossen", "domains": {"primary": "hansen.example"}}' > "${c}/environments/rossen.json"
echo '{"name": "jonna", "displayName": "Jonna Hansen", "primaryEmail": "jonna@hansen.example"}' > "${c}/identities/users/jonna.json"
cp "${c}/identities/users/jonna.json" "${c}/people/users/jonna.json"
echo '{"bobs-laptop": {"publicKey": "abc="}}' > "${c}/wgvpn/peers.json"
echo '{"name": "rasmus", "tunnel": {"peerKey": "wgkey="}}' > "${c}/remote-rasmus.json"
cat > "${c}/network.json" <<'EOF'
{"vmname": "network", "wan": {"address": "80.248.138.190/24", "gateway": "80.248.138.1"},
 "lan": {"address": "10.0.0.1"}, "apiToken": "s3cr3t-token", "adminPassword": "hunter2",
 "v6": "2a02:aa7:4000:1234::1", "ula": "fd00::1"}
EOF
echo '{"vmname": "nextcloud", "displayName": "Nextcloud", "dependsOn": ["identity:identity"]}' > "${c}/nextcloud.json"
cp "${c}/network.json" "${c}/network.json.orig"
echo '{"ok": true, "start_time": "2026-10-27 02:00:45", "end_time": "2026-10-27 03:03:29", "succeeded": 30, "total": 30}' > "${c}/last-update-result.json"
cat > "${d}/logs/nextcloud-test-2026-10-27_020000.log" <<'EOF'
[Info] user jonna (Jonna Hansen) logged in from 80.248.138.190 via 10.2.0.76
[Info] mail sent to jonna.hansen@hansen.example; curl -H 'Authorization: Bearer abcdef123'
[Info] password=hunter2 rejected for bobs-laptop at Elmstreet 12
[Info] ssh tappaas@nextcloud.rossen.internal ok; egress to 1.1.1.1:443 ok; the account has a password set
EOF
touch -d '-10 minutes' "${d}/logs/nextcloud-test-2026-10-27_020000.log"
echo old > "${d}/logs/old-test.log"; touch -d '-3 days' "${d}/logs/old-test.log"
for cmd in journalctl systemctl module-manager; do
    printf '#!/usr/bin/env bash\necho "%s stub: jonna@hansen.example on 80.248.138.190"\n' "${cmd}" > "${d}/bin/${cmd}"
    chmod +x "${d}/bin/${cmd}"
done
cat > "${d}/notify" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${d}/notify-args"
cat > /dev/null
EOF
chmod +x "${d}/notify"
export PATH="${d}/bin:${PATH}" TAPPAAS_CONFIG_DIR="${c}" TAPPAAS_LOG_DIR="${d}/logs" \
       TAPPAAS_SUPPORT_DIR="${d}/out" TAPPAAS_SITE_NOTIFY="${d}/notify"

bundle="$(bash "${B}" --reason "test" --unit update-tappaas.service --since '-1 hour' --no-cluster 2>"${d}/err")"; rc=$?
[[ ${rc} -eq 0 && -f "${bundle}" ]] && ok "a bundle is written" || { bad "no bundle: rc=${rc} $(cat "${d}/err")"; echo "── summary: ${pass} pass, ${fail} fail ──"; exit 1; }
[[ "$(stat -c %a "${bundle}")" == 600 ]] && ok "…readable by its owner only" || bad "mode $(stat -c %a "${bundle}")"
map="${bundle%.tar.gz}.map.json"
[[ -f "${map}" && "$(stat -c %a "${map}")" == 600 ]] && ok "the map stays next to it, mode 0600" || bad "map"
mkdir "${d}/x"; tar -C "${d}/x" -xzf "${bundle}"
x="$(echo "${d}"/x/tappaas-support-rossen-*)"
all="$(cat -- $(find "${x}" -type f))"

[[ -f "${x}/manifest.json" ]] && [[ "$(jq -r .reason "${x}/manifest.json")" == "test" ]] && ok "manifest.json says why" || bad "manifest"
[[ -f "${x}/config/site.json" && -f "${x}/config/network.json" && -f "${x}/config/nextcloud.json" && -f "${x}/config/environments/rossen.json" ]] \
    && ok "the site, network, a module and the environments go in" || bad "config files: $(cd "${x}" && find config -type f | paste -sd' ')"
[[ ! -e "${x}/config/identities" && ! -e "${x}/config/people" && ! -e "${x}/config/wgvpn" && ! -e "${x}/config/remote-rasmus.json" && ! -e "${x}/config/network.json.orig" ]] \
    && ok "people, identities, VPN and backup peers and file backups stay out" || bad "denied files went in: $(cd "${x}" && find config -type f | paste -sd' ')"
[[ -f "${x}/logs/nextcloud-test-2026-10-27_020000.log" && ! -e "${x}/logs/old-test.log" ]] \
    && ok "the test logs of the window go in, older ones do not" || bad "logs: $(ls "${x}/logs")"

leaks=0
for leak in "elmstreet12" "Jonna" "jonna" "Hansen Family" "Elmstreet" "Springfield" "80.248.138.190" "80.248.138.1\"" "2a02:aa7:4000:1234::1" \
            "hunter2" "s3cr3t-token" "abcdef123" "bobs-laptop" "55.68" "jonna.hansen@"; do
    grep -qF -- "${leak}" <<<"${all}" && { leaks=1; bad "'${leak}' leaks into the bundle: $(grep -rlF -- "${leak}" "${x}" | sed "s|${x}/||" | paste -sd' ')"; }
done
[[ ${leaks} -eq 0 ]] && ok "no name, address, public IP, secret or e-mail local part from the fixture is in it"
grep -qF 'hansen.example' <<<"${all}" && ok "domains are kept" || bad "the domain was replaced"
grep -qF 'ssh tappaas@nextcloud.rossen.internal ok; egress to 1.1.1.1:443 ok; the account has a password set' "${x}/logs/"*.log \
    && ok "logins at internal hosts, public resolvers and prose about passwords are kept" || bad "over-redacted: $(tail -1 "${x}/logs/"*.log)"
[[ "$(jq -r '.locations | keys | map(select(startswith("place-"))) | length' "${x}/config/site.json")" == 1 ]] \
    && ok "a location's name, a JSON key, is replaced too" || bad "location keys: $(jq -c '.locations|keys' "${x}/config/site.json")"
grep -qF '10.2.0.76' "${x}/logs/"*.log && grep -qF '"10.0.0.1"' "${x}/config/network.json" && grep -qF 'fd00::1' "${x}/config/network.json" \
    && ok "private addresses are kept" || bad "a private address was replaced"
grep -qE 'user-[0-9]+@hansen\.example' "${x}/config/site.json" && ok "an e-mail address becomes user-N at its own domain" || bad "email: $(jq .email "${x}/config/site.json")"
[[ "$(jq -r .adminPassword "${x}/config/network.json")" == REDACTED && "$(jq -r .apiToken "${x}/config/network.json")" == REDACTED ]] \
    && ok "fields named like a secret are REDACTED" || bad "secret fields"
pub="$(jq -r .wan.address "${x}/config/network.json")"
grep -qF "${pub%/24}" "${x}/logs/nextcloud-test-2026-10-27_020000.log" && [[ "${pub}" == 203.0.113.*/24 ]] \
    && ok "a public IP has one replacement in config and log alike (${pub})" || bad "public IP: ${pub}"
[[ "$(jq -r '.rossen // empty' "${map}")" == "" ]] && [[ "$(jq -r '."Jonna Hansen"' "${map}")" == person-* ]] \
    && ok "the map decodes a person, and the site code is no person" || bad "map: $(cat "${map}")"
grep -qF 'rossen' "${x}/config/site.json" && ok "the site and environment code is kept" || bad "site code replaced"
[[ "$(jq -r .anonymized.redacted.people "${x}/manifest.json")" -gt 0 ]] && ok "the manifest counts what was replaced" || bad "manifest counts"

# The newest 20 are kept.
for i in $(seq 1 21); do touch -d "-$((i + 1)) days" "${d}/out/tappaas-support-rossen-2026010${i}-000000.tar.gz"; done
bash "${B}" --reason again --no-cluster >/dev/null 2>&1
[[ "$(ls "${d}/out"/tappaas-support-*.tar.gz | wc -l)" -eq 20 ]] && ok "only the newest 20 bundles are kept" || bad "kept $(ls "${d}/out"/tappaas-support-*.tar.gz | wc -l)"

# --test: the ALERT with the bundle, then its RESOLVED.
rm -f "${d}/notify-args"
out="$(bash "${B}" --test --to ops@example.org 2>"${d}/err")"; rc=$?
[[ ${rc} -eq 0 && -f "${out}" ]] && ok "--test prints the bundle it sent" || bad "--test: rc=${rc} out=${out} $(cat "${d}/err")"
first="$(grep -- 'ALERT: TEST' "${d}/notify-args")"; second="$(grep -- 'RESOLVED: TEST' "${d}/notify-args")"
[[ "${first}" == *"--key test:support-bundle"*"--to ops@example.org"*"--attach ${out}"*"ALERT: TEST"* ]] \
    && ok "…the ALERT carries the bundle, to the address given" || bad "ALERT args: ${first}"
[[ "${second}" == *"--key test:support-bundle"*"--resolve"*"RESOLVED: TEST"* && "${second}" != *--attach* ]] \
    && ok "…then the RESOLVED, for the same key and without it" || bad "RESOLVED args: ${second}"

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
