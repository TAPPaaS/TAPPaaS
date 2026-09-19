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
{ "kind": "machine", "tier": "foundation", "name": "t",
  "roles": ["reverse-proxy"], "host": { "publicIp": "203.0.113.10" } }
JSON
if TAPPAAS_CONFIG_DIR="${tmp}" "${mgr}" validate t >/dev/null; then ok "validate accepts a good config"; else no "validate good"; fi

# 4. validate rejects missing roles
echo '{ "kind":"machine","tier":"foundation","name":"b","host":{"publicIp":"203.0.113.10"} }' > "${tmp}/satellite-b.json"
if TAPPAAS_CONFIG_DIR="${tmp}" "${mgr}" validate b >/dev/null 2>&1; then no "validate should reject missing roles"; else ok "validate rejects missing roles"; fi

# 5. validate rejects missing publicIp
echo '{ "kind":"machine","tier":"foundation","name":"c","roles":["backup"] }' > "${tmp}/satellite-c.json"
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

# 11-13b. the admin VPN moved to network-manager wgvpn (ADR-010 §8.4.6); its tests
#         live in network-manager/test.sh.

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

# 16b. #609: --country/--city become physicalLocation; none given → none recorded
(
    . "${here}/lib/provision.sh" >/dev/null 2>&1
    sat_write_config "${tmp}/pl.json" p hetzner 1.2.3.4 "ssh-ed25519 K o@w" "reverse-proxy,backup" b "" debian fi Helsinki
)
if [[ "$(jq -c .physicalLocation "${tmp}/pl.json" 2>/dev/null)" == '{"country":"FI","city":"Helsinki"}' \
      && "$(jq 'has("physicalLocation")' "${tmp}/osd.json" 2>/dev/null)" == "false" ]]; then
    ok "sat_write_config records physicalLocation (country upper-cased) and invents none (#609)"
else
    no "sat_write_config physicalLocation"
fi

# 16c. the config records where the satellite module's code lives (moduleSource,
#      #609) — absolute — so module_of / `module list --resolution` can name it.
(
    . "${here}/lib/provision.sh" >/dev/null 2>&1
    SATELLITE_SRC="${tmp}/src/satellite"; mkdir -p "${SATELLITE_SRC}"
    sat_write_config "${tmp}/ms.json" m hetzner 1.2.3.4 "ssh-ed25519 K o@w" "reverse-proxy" "" "" debian
)
if [[ "$(jq -r .moduleSource "${tmp}/ms.json" 2>/dev/null)" == "$(cd "${tmp}/src/satellite" && pwd)" ]]; then
    ok "sat_write_config records moduleSource = the satellite module's directory"
else
    no "sat_write_config moduleSource ($(jq -r .moduleSource "${tmp}/ms.json" 2>/dev/null))"
fi

# 17. install --dry-run branches on os (debian => provision-debian, no nixos-anywhere)
echo '{ "kind":"machine","tier":"foundation","name":"dbg","os":"debian","roles":["reverse-proxy"],"host":{"publicIp":"203.0.113.9","operatorSshKeys":["ssh-ed25519 K o@w"]} }' > "${tmp}/satellite-dbg.json"
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

# perm_bits <file> — the octal permission bits, GNU stat first then BSD.
#
# Order and structure both matter. `stat -f` is NOT "format" on GNU coreutils —
# it is "display FILESYSTEM status", which prints seven lines of filesystem
# detail to STDOUT and still exits non-zero. Written BSD-first as
# `stat -f '%Lp' … || stat -c '%a' …` inside one command substitution, the
# fallback therefore also ran and the two outputs CONCATENATED, so the compared
# string was a block of filesystem stats with "600" on the end — never equal to
# "600". The test failed on Linux for a reason that had nothing to do with the
# code under test, which sets 0600 correctly.
perm_bits() {
    local f="$1" m
    m="$(stat -c '%a' "$f" 2>/dev/null)" && [[ -n "$m" ]] && { printf '%s' "$m"; return 0; }
    m="$(stat -f '%Lp' "$f" 2>/dev/null)" && [[ -n "$m" ]] && { printf '%s' "$m"; return 0; }
    return 1
}

# 19. sat_gen_backup_config renders backup.env + a 0600 token when provided
echo '{"name":"v","os":"debian","roles":["backup"],"host":{"operatorSshKeys":["k"]},"backup":{"pull":{"homePbsHost":"10.0.0.20","authId":"satellite@pbs!pull"}}}' > "${tmp}/vb.json"
( . "${here}/lib/provision.sh" >/dev/null 2>&1; TAPPAAS_SAT_PBS_TOKEN="S3CR" sat_gen_backup_config "${tmp}/vb.json" "${tmp}/vbo" )
if grep -q 'HOME_PBS_HOST="10.0.0.20"' "${tmp}/vbo/backup.env" \
   && grep -q 'REMOVE_VANISHED="false"' "${tmp}/vbo/backup.env" \
   && [[ "$(cat "${tmp}/vbo/pbs-remote-token" 2>/dev/null)" == "S3CR" ]] \
   && [[ "$(perm_bits "${tmp}/vbo/pbs-remote-token")" == "600" ]]; then
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
echo '{ "kind":"machine","tier":"foundation","name":"bd","os":"debian","roles":["backup"],"host":{"publicIp":"203.0.113.9","operatorSshKeys":["ssh-ed25519 K o@w"]},"backup":{"pull":{"homePbsHost":"10.0.0.20"}} }' > "${tmp}/satellite-bd.json"
out="$(TAPPAAS_CONFIG_DIR="${tmp}" "${mgr}" install bd --dry-run 2>&1)" || true
echo '{ "kind":"machine","tier":"foundation","name":"bn","os":"nixos","roles":["backup"],"host":{"publicIp":"203.0.113.9","operatorSshKeys":["ssh-ed25519 K o@w"]} }' > "${tmp}/satellite-bn.json"
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

# 28. #644: --help in any position runs nothing; an option the verb lacks is refused.
# `remove <name> --help` used to delete the OPNsense WireGuard peer and server.
rc=0; out="$(TAPPAAS_CONFIG_DIR="${tmp}" "${mgr}" remove t --help 2>&1)" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -q 'remove *<name>' <<< "${out}" && ! grep -q 'install' <<< "${out}"; then
    ok "remove <name> --help prints remove's usage only, rc 0"
else
    no "remove <name> --help rc=${rc}"
fi
rc=0; out="$(TAPPAAS_CONFIG_DIR="${tmp}" "${mgr}" install --help 2>&1)" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -q -- '--s3-endpoint' <<< "${out}"; then ok "install --help lists the install options"; else no "install --help rc=${rc}"; fi
for args in "status t --json"; do
    rc=0
    # shellcheck disable=SC2086  # word-split on purpose
    out="$(TAPPAAS_CONFIG_DIR="${tmp}" "${mgr}" ${args} 2>&1)" || rc=$?
    if [[ "${rc}" -eq 1 ]] && grep -q 'unknown option' <<< "${out}"; then ok "'${args}' is refused"; else no "'${args}' rc=${rc}"; fi
done

echo ""
echo "satellite-manager fast tests: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
