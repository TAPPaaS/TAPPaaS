#!/usr/bin/env bash
# test.sh — satellite-manager fast tests (schema/CLI/validation; no live host).
# Deep/live tests (real provisioning) gate behind TAPPAAS_TEST_DEEP=1 (P2-P6).
set -euo pipefail

# Accept --deep as well as TAPPAAS_TEST_DEEP=1. Every gate below reads the
# variable, so exporting it here is all a flag needs to do — and exporting (not
# just setting) is what carries it into any suite this one dispatches. Without
# this, `test.sh --deep` silently ran the fast path.
for _a in "$@"; do [[ "${_a}" == "--deep" ]] && export TAPPAAS_TEST_DEEP=1; done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mgr="${here}/satellite-manager.sh"
pass=0; fail=0
ok()  { echo "  ok   - $*"; pass=$((pass+1)); }
no()  { echo "  FAIL - $*"; fail=$((fail+1)); }

# 1. parses
if bash -n "${mgr}"; then ok "satellite-manager.sh parses"; else no "syntax error"; fi

# 2. --help exits 0 and prints usage
if "${mgr}" --help | grep -q "TAPPaaS VPS satellite manager"; then ok "--help prints usage"; else no "--help"; fi

# 3. validate accepts a good fixture
tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT
cat > "${tmp}/satellite-t.json" << 'JSON'
{ "kind": "external-host", "tier": "foundation", "name": "t",
  "roles": ["reverse-proxy"], "host": { "publicIp": "203.0.113.10" } }
JSON
if TAPPAAS_CONFIG_DIR="${tmp}" "${mgr}" validate t >/dev/null; then ok "validate accepts a good config"; else no "validate good"; fi

# 4. validate rejects missing roles
echo '{ "kind":"external-host","tier":"foundation","name":"b","host":{"publicIp":"203.0.113.10"} }' > "${tmp}/satellite-b.json"
if TAPPAAS_CONFIG_DIR="${tmp}" "${mgr}" validate b >/dev/null 2>&1; then no "validate should reject missing roles"; else ok "validate rejects missing roles"; fi

# 5. validate rejects missing publicIp
echo '{ "kind":"external-host","tier":"foundation","name":"c","roles":["backup"] }' > "${tmp}/satellite-c.json"
if TAPPAAS_CONFIG_DIR="${tmp}" "${mgr}" validate c >/dev/null 2>&1; then no "validate should reject missing publicIp"; else ok "validate rejects missing publicIp"; fi

# 6. install --dry-run prints the provisioning plan (exit 0, no side effects).
#    (|| rc=$? keeps the exit code without tripping `set -e`.)
rc=0
out="$(TAPPAAS_CONFIG_DIR="${tmp}" "${mgr}" install t --dry-run 2>&1)" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -q "nixos-anywhere" <<< "${out}"; then ok "install --dry-run prints plan"; else no "install --dry-run rc=${rc}"; fi
# update still reports not-implemented (exit 2) — P3 autoUpgrade.
rc=0
TAPPAAS_CONFIG_DIR="${tmp}" "${mgr}" update t >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -eq 2 ]]; then ok "update reports not-implemented (exit 2)"; else no "update exit code ${rc}"; fi

# --- P2 tunnel: mock the satellite over SSH ($TAPPAAS_SSH_RUNNER) ---
cat > "${tmp}/mockssh" << 'SH'
#!/usr/bin/env bash
# args: <target> <remote-command-string>
case "$2" in
  *latest-handshakes*) printf 'FAKEPEERKEY\t1700000000\n' ;;
  "date +%s")          echo 1700000100 ;;
  *public-key*)        echo "FAKEPUBKEY=" ;;
  *)                   exit 1 ;;
esac
SH
chmod +x "${tmp}/mockssh"
printf '#!/usr/bin/env bash\nexit 1\n' > "${tmp}/mockdown"; chmod +x "${tmp}/mockdown"

# 7. status: reachable (mocked) host -> reports handshake age, exit 0
rc=0
out="$(TAPPAAS_CONFIG_DIR="${tmp}" TAPPAAS_SSH_RUNNER="${tmp}/mockssh" "${mgr}" status t 2>&1)" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -q "last handshake 100s ago" <<< "${out}"; then ok "status reports handshake (mocked)"; else no "status mocked: rc=${rc}"; fi

# 8. status: unreachable host -> exit 1 with a clear message
rc=0
TAPPAAS_CONFIG_DIR="${tmp}" TAPPAAS_SSH_RUNNER="${tmp}/mockdown" "${mgr}" status t >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -eq 1 ]]; then ok "status reports unreachable (exit 1)"; else no "status down: rc=${rc}"; fi

# 9. tunnel_satellite_pubkey reads the public key (mocked)
if ( . "${here}/lib/tunnel.sh"; export TAPPAAS_SSH_RUNNER="${tmp}/mockssh"; [[ "$(tunnel_satellite_pubkey root@x)" == "FAKEPUBKEY=" ]] ); then
    ok "tunnel_satellite_pubkey reads pubkey (mocked)"
else
    no "tunnel_satellite_pubkey"
fi

# 10. sat_write_config (manager owns the JSON): --bucket => backup role + slim shape
( . "${here}/lib/provision.sh"; sat_write_config "${tmp}/w.json" n hetzner 1.2.3.4 "ssh-ed25519 K o@w" "reverse-proxy,admin-vpn,backup" mybkt )
if [[ "$(jq -r '.roles|join(",")' "${tmp}/w.json" 2>/dev/null)" == "reverse-proxy,admin-vpn,backup" \
      && "$(jq -r '.backup.s3.bucket' "${tmp}/w.json" 2>/dev/null)" == "mybkt" \
      && "$(jq -r 'has("tunnel")' "${tmp}/w.json" 2>/dev/null)" == "false" ]]; then
    ok "sat_write_config writes slim config + backup from bucket"
else
    no "sat_write_config shape"
fi

# 11. admin-vpn lib parses (ADR-010 §6 / Q3)
if bash -n "${here}/lib/admin-vpn.sh"; then ok "lib/admin-vpn.sh parses"; else no "admin-vpn.sh syntax"; fi

# 12. `admin --help` prints usage, exits 0, no side effects
rc=0
out="$(TAPPAAS_CONFIG_DIR="${tmp}" "${mgr}" admin --help 2>&1)" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -q "add-peer" <<< "${out}" && grep -q -- "--endpoint" <<< "${out}"; then
    ok "admin --help prints usage (incl. add-peer --endpoint)"
else
    no "admin --help rc=${rc}"
fi

# 13. av_client_config renders a valid stanza (server pubkey + API mocked → offline)
out="$( . "${here}/lib/admin-vpn.sh" >/dev/null 2>&1
        av_server_pubkey() { echo "FAKEKEY="; }
        _ow_api() { :; }
        av_client_config "10.255.1.7/32" "203.0.113.5:51821" "PRIVKEY" )"
if grep -q 'Endpoint            = 203.0.113.5:51821' <<< "${out}" \
   && grep -q 'PublicKey           = FAKEKEY=' <<< "${out}" \
   && grep -q 'AllowedIPs          = 10.0.0.0/24' <<< "${out}" \
   && grep -q 'MTU        = 1340' <<< "${out}"; then
    ok "av_client_config renders a valid client stanza"
else
    no "av_client_config format"
fi

# 13b. av_discover_endpoint: an admin-vpn satellite's recorded IP:port when one is
#      configured; a template placeholder otherwise (role-gated, offline / files+jq).
EPDIR="${tmp}/epcfg"; mkdir -p "${EPDIR}"
ep_none="$( . "${here}/lib/admin-vpn.sh" >/dev/null 2>&1; av_discover_endpoint "${EPDIR}" )"
printf '%s' '{"name":"sat1","roles":["reverse-proxy"],"host":{"publicIp":"9.9.9.9"}}' > "${EPDIR}/satellite-sat1.json"
ep_norole="$( . "${here}/lib/admin-vpn.sh" >/dev/null 2>&1; av_discover_endpoint "${EPDIR}" )"
printf '%s' '{"name":"sat2","roles":["reverse-proxy","admin-vpn"],"host":{"publicIp":"1.2.3.4"}}' > "${EPDIR}/satellite-sat2.json"
ep_found="$( . "${here}/lib/admin-vpn.sh" >/dev/null 2>&1; av_discover_endpoint "${EPDIR}" )"
if [[ "${ep_none}" == "<satellite-or-cluster-public-ip>:51821" \
   && "${ep_norole}" == "<satellite-or-cluster-public-ip>:51821" \
   && "${ep_found}" == "1.2.3.4:51821" ]]; then
    ok "av_discover_endpoint: admin-vpn satellite IP, else placeholder"
else
    no "av_discover_endpoint (none='${ep_none}' norole='${ep_norole}' found='${ep_found}')"
fi

# --- Debian satellite (ADR-010 Option 3 / Q8→D19) ---------------------------
deb_src="${here}/../../../satellite/debian/provision-debian.sh"

# 14. provision-debian.sh parses
if [[ -f "${deb_src}" ]] && bash -n "${deb_src}"; then ok "provision-debian.sh parses"; else no "provision-debian.sh syntax/missing"; fi

# 15. sat_gen_debian_configs role-gating (offline render)
(
    . "${here}/lib/provision.sh" >/dev/null 2>&1
    # all three roles -> nginx + ip_forward + admin-vpn NAT present
    echo '{"name":"a","os":"debian","roles":["reverse-proxy","admin-vpn","backup"],"host":{"operatorSshKeys":["k"]}}' > "${tmp}/a.json"
    sat_gen_debian_configs "${tmp}/a.json" "HPUB=" "${tmp}/ao"
    # reverse-proxy only -> NO ip_forward, NO admin NAT, NO nginx? (nginx yes)
    echo '{"name":"b","os":"debian","roles":["reverse-proxy"],"host":{"operatorSshKeys":["k"]}}' > "${tmp}/b.json"
    sat_gen_debian_configs "${tmp}/b.json" "HPUB=" "${tmp}/bo"
)
if [[ -f "${tmp}/ao/nginx-stream.conf" && -f "${tmp}/ao/99-tappaas-ipforward.conf" ]] \
   && grep -q "table ip adminvpn" "${tmp}/ao/nftables.conf" \
   && [[ ! -f "${tmp}/bo/99-tappaas-ipforward.conf" ]] \
   && ! grep -q "table ip adminvpn" "${tmp}/bo/nftables.conf" \
   && [[ -f "${tmp}/bo/nginx-stream.conf" ]]; then
    ok "sat_gen_debian_configs role-gates files (nginx/ip_forward/admin-NAT)"
else
    no "sat_gen_debian_configs role-gating"
fi

# 16. sat_write_config records os (default debian; explicit nixos honoured)
(
    . "${here}/lib/provision.sh" >/dev/null 2>&1
    sat_write_config "${tmp}/osd.json" d hetzner 1.2.3.4 "ssh-ed25519 K o@w" "reverse-proxy" "" "" ""
    sat_write_config "${tmp}/osn.json" n hetzner 1.2.3.4 "ssh-ed25519 K o@w" "reverse-proxy" "" "" nixos
)
if [[ "$(jq -r .os "${tmp}/osd.json" 2>/dev/null)" == "debian" \
      && "$(jq -r .os "${tmp}/osn.json" 2>/dev/null)" == "nixos" ]]; then
    ok "sat_write_config records os (default debian / explicit nixos)"
else
    no "sat_write_config os field"
fi

# 17. install --dry-run branches on os (debian => provision-debian, no nixos-anywhere)
echo '{ "kind":"external-host","tier":"foundation","name":"dbg","os":"debian","roles":["reverse-proxy"],"host":{"publicIp":"203.0.113.9","operatorSshKeys":["ssh-ed25519 K o@w"]} }' > "${tmp}/satellite-dbg.json"
rc=0; out="$(TAPPAAS_CONFIG_DIR="${tmp}" "${mgr}" install dbg --dry-run 2>&1)" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -q "provision-debian.sh" <<< "${out}" && ! grep -q "nixos-anywhere" <<< "${out}"; then
    ok "install --dry-run (os=debian) plans the Debian path"
else
    no "install --dry-run debian branch rc=${rc}"
fi

# --- backup role body (ADR-010 P6) ------------------------------------------
bkp_src="${here}/../../../satellite/debian/provision-backup.sh"

# 18. provision-backup.sh parses
if [[ -f "${bkp_src}" ]] && bash -n "${bkp_src}"; then ok "provision-backup.sh parses"; else no "provision-backup.sh syntax/missing"; fi

# 19. sat_gen_backup_config renders backup.env + a 0600 token when provided
echo '{"name":"v","os":"debian","roles":["backup"],"host":{"operatorSshKeys":["k"]},"backup":{"pull":{"homePbsHost":"10.0.0.20","authId":"satellite@pbs!pull"}}}' > "${tmp}/vb.json"
( . "${here}/lib/provision.sh" >/dev/null 2>&1; TAPPAAS_SAT_PBS_TOKEN="S3CR" sat_gen_backup_config "${tmp}/vb.json" "${tmp}/vbo" )
if grep -q 'HOME_PBS_HOST="10.0.0.20"' "${tmp}/vbo/backup.env" \
   && grep -q 'REMOVE_VANISHED="false"' "${tmp}/vbo/backup.env" \
   && [[ "$(cat "${tmp}/vbo/pbs-remote-token" 2>/dev/null)" == "S3CR" ]] \
   && [[ "$(stat -f '%Lp' "${tmp}/vbo/pbs-remote-token" 2>/dev/null || stat -c '%a' "${tmp}/vbo/pbs-remote-token" 2>/dev/null)" == "600" ]]; then
    ok "sat_gen_backup_config renders backup.env + 0600 token"
else
    no "sat_gen_backup_config backup.env/token"
fi

# 20. backup role widens wg AllowedIPs to the home PBS; non-backup does not
( . "${here}/lib/provision.sh" >/dev/null 2>&1
  sat_gen_debian_configs "${tmp}/vb.json" "HP=" "${tmp}/vwg" )
echo '{"name":"w","os":"debian","roles":["reverse-proxy"],"host":{"operatorSshKeys":["k"]}}' > "${tmp}/w2.json"
( . "${here}/lib/provision.sh" >/dev/null 2>&1
  sat_gen_debian_configs "${tmp}/w2.json" "HP=" "${tmp}/vwg2" )
if grep -q '10.0.0.20/32' "${tmp}/vwg/wg-infra.conf" && ! grep -q '10.0.0.20/32' "${tmp}/vwg2/wg-infra.conf"; then
    ok "backup role widens wg AllowedIPs to home PBS"
else
    no "AllowedIPs widening"
fi

# 21. install --dry-run: backup+debian plans the pull; backup+nixos is skipped
echo '{ "kind":"external-host","tier":"foundation","name":"bd","os":"debian","roles":["backup"],"host":{"publicIp":"203.0.113.9","operatorSshKeys":["ssh-ed25519 K o@w"]},"backup":{"pull":{"homePbsHost":"10.0.0.20"}} }' > "${tmp}/satellite-bd.json"
out="$(TAPPAAS_CONFIG_DIR="${tmp}" "${mgr}" install bd --dry-run 2>&1)" || true
echo '{ "kind":"external-host","tier":"foundation","name":"bn","os":"nixos","roles":["backup"],"host":{"publicIp":"203.0.113.9","operatorSshKeys":["ssh-ed25519 K o@w"]} }' > "${tmp}/satellite-bn.json"
outn="$(TAPPAAS_CONFIG_DIR="${tmp}" "${mgr}" install bn --dry-run 2>&1)" || true
if grep -q "pull sync-job" <<< "${out}" && grep -qi "SKIPPED" <<< "${outn}"; then
    ok "install --dry-run backup: debian plans pull, nixos skipped"
else
    no "install --dry-run backup branch"
fi

# 22. sat_ensure_edge_rules emits the right role-gated rules (API mocked → offline).
#     Mock _ow_api records each addRule payload to a file (searchRule returns empty
#     so every rule is 'created'; apply is a no-op).
EDGE_OUT="${tmp}/edge_rules.txt"; : > "${EDGE_OUT}"
(
    . "${here}/lib/provision.sh" >/dev/null 2>&1
    _ow_api() {
        case "$*" in
            *searchRule*) echo '{"rows":[]}' ;;
            *apply*)      : ;;
            *)            printf '%s\n' "$*" >> "${EDGE_OUT}" ;;
        esac
    }
    sat_ensure_edge_rules "reverse-proxy,admin-vpn" >/dev/null 2>&1
)
if grep -q 'edge->caddy 80' "${EDGE_OUT}" && grep -q 'edge->caddy 443' "${EDGE_OUT}" && grep -q 'edge->admin-wg' "${EDGE_OUT}"; then
    ok "sat_ensure_edge_rules emits caddy+admin-wg rules"
else
    no "sat_ensure_edge_rules output"
fi

# 23. av_ensure_wan_rule creates the WAN UDP :51821 -> This Firewall pass via the
#     opnsense-controller CLI (opnsense-firewall create-rule), NOT raw REST. A fake
#     opnsense-firewall records its args; raw _ow_api must NOT be reached.
WAN_OUT="${tmp}/wan_rule_args.txt"; : > "${WAN_OUT}"
fakebin="${tmp}/fakebin"; mkdir -p "${fakebin}"
cat > "${fakebin}/opnsense-firewall" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${WAN_OUT}"
FAKE
chmod +x "${fakebin}/opnsense-firewall"
(
    . "${here}/lib/admin-vpn.sh" >/dev/null 2>&1
    av_fw_cli() { printf '%s' "${fakebin}/opnsense-firewall"; }        # force the fake CLI
    _ow_api() { printf 'RAW-REST-CALLED\n' >> "${WAN_OUT}"; }          # fallback must not fire
    av_ensure_wan_rule >/dev/null 2>&1
)
if grep -q 'create-rule' "${WAN_OUT}" \
   && grep -q -- '--interface wan' "${WAN_OUT}" \
   && grep -q -- '--protocol udp' "${WAN_OUT}" \
   && grep -q -- '--destination wanip' "${WAN_OUT}" \
   && grep -q -- '--destination-port 51821' "${WAN_OUT}" \
   && ! grep -q 'RAW-REST-CALLED' "${WAN_OUT}"; then
    ok "av_ensure_wan_rule creates WAN :51821 rule via opnsense-controller CLI"
else
    no "av_ensure_wan_rule controller invocation"
fi

# 24-26. av_setup must VERIFY the live rule set, not assert what it intended, and must
#        enable WireGuard before binding a rule to the `wireguard` group interface
#        (OPNsense rejects a rule on an interface it has not registered yet). A live
#        cluster was found with server+WAN present but admin->mgmt MISSING while setup
#        had reported "ready" -- these pin that regression.
#        av_setup is driven with stubs; ORDER records the call sequence.
_av_setup_probe() {  # <mgmt-rule-present:0|1> <wan-rule-present:0|1> <order-file>
    local mgmt="$1" wan="$2" order="$3"
    (
        . "${here}/lib/admin-vpn.sh" >/dev/null 2>&1
        av_ensure_server()   { echo "uuid-1"; }
        av_server_pubkey()   { echo "PUBKEY="; }
        av_enable_wg()       { printf 'enable\n'  >> "${order}"; echo enabled; }
        av_ensure_mgmt_rule() { printf 'mgmt\n'   >> "${order}"; echo ok; }
        av_ensure_wan_rule()  { printf 'wan\n'    >> "${order}"; echo ok; }
        av_apply()           { printf 'apply\n'   >> "${order}"; echo applied; }
        av_rule_uuid()       { [[ "${mgmt}" == 1 ]] && echo "r-uuid" || true; }
        av_wan_rule_uuid()   { [[ "${wan}"  == 1 ]] && echo "w-uuid" || true; }
        av_setup
    )
}

# 24. mgmt rule absent -> non-zero, and the missing rule is named on stderr.
ORDER="${tmp}/av_order_24.txt"; : > "${ORDER}"
rc=0; out="$(_av_setup_probe 0 1 "${ORDER}" 2>&1)" || rc=$?
if [[ "${rc}" -ne 0 ]] && grep -q "setup incomplete" <<< "${out}" \
   && grep -q "admin->mgmt" <<< "${out}" && ! grep -q "admin-vpn ready" <<< "${out}"; then
    ok "av_setup fails loudly when the admin->mgmt rule is absent"
else
    no "av_setup should fail when admin->mgmt is missing (rc=${rc})"
fi

# 25. both rules present -> exit 0 and the ready banner.
ORDER="${tmp}/av_order_25.txt"; : > "${ORDER}"
rc=0; out="$(_av_setup_probe 1 1 "${ORDER}" 2>&1)" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -q "admin-vpn ready" <<< "${out}"; then
    ok "av_setup succeeds when both rules are present"
else
    no "av_setup should succeed when both rules exist (rc=${rc})"
fi

# 26. WireGuard is enabled BEFORE the mgmt rule is created (the ordering bug).
if [[ "$(grep -n -m1 '^enable$' "${ORDER}" | cut -d: -f1)" -lt \
      "$(grep -n -m1 '^mgmt$'   "${ORDER}" | cut -d: -f1)" ]]; then
    ok "av_setup enables WireGuard before creating the admin->mgmt rule"
else
    no "av_setup must enable WireGuard before the mgmt rule (order: $(tr '\n' ',' < "${ORDER}"))"
fi

# 27. av_apply still enables WireGuard (add-peer/remove-peer rely on it) and applies filters.
APPLY_OUT="${tmp}/av_apply.txt"; : > "${APPLY_OUT}"
(
    . "${here}/lib/admin-vpn.sh" >/dev/null 2>&1
    av_enable_wg() { printf 'enable\n' >> "${APPLY_OUT}"; }
    _ow_api() { printf '%s\n' "$*" >> "${APPLY_OUT}"; }
    av_apply >/dev/null 2>&1
)
if grep -q '^enable$' "${APPLY_OUT}" && grep -q 'filter/apply' "${APPLY_OUT}"; then
    ok "av_apply enables WireGuard and applies filter changes"
else
    no "av_apply behaviour changed"
fi

echo ""
echo "satellite-manager fast tests: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
