#!/usr/bin/env bash
#
# TAPPaaS satellite module test (ADR-010 §8.4)
#
#   ./test.sh <instance>   the module-contract test of one satellite (what
#                          `module-manager module test` and the update gate run):
#                          its config, its tunnel on OPNsense and — when managed —
#                          the machine itself, including the debianhost checks.
#   ./test.sh              the module's offline suite: contract files, the
#                          template, and the library with OPNsense and ssh stubbed.
#                          --deep (or TAPPAAS_TEST_DEEP=1) adds the reverse-proxy
#                          end-to-end test through a live satellite.
#
set -uo pipefail

for _a in "$@"; do [[ "${_a}" == "--deep" ]] && export TAPPAAS_TEST_DEEP=1; done
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INST=""
for _a in "$@"; do [[ "${_a}" != --* ]] && { INST="${_a}"; break; }; done

# ── one satellite, live ──────────────────────────────────────────────────────
if [[ -n "${INST}" ]]; then
    . /home/tappaas/bin/common-install-routines.sh
    . "${here}/lib/satellite-lib.sh"
    PASS=0; FAIL=0
    pass() { info "  ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
    fail() { error "  ✗ $1"; FAIL=$((FAIL + 1)); }
    sat_load "${INST}"
    info "${BOLD}Testing satellite ${BL}${INSTANCE}${CL}${BOLD} (${ADDRESS:-no address}, ${SAT_MGMT})${CL}"

    [[ -n "${ADDRESS}" ]] && pass "address ${ADDRESS}" || fail "no address recorded"
    if [[ -n "${SAT_ROLES}" ]]; then pass "roles ${SAT_ROLES}"; else fail "no roles"; fi
    if jq -e '(.physicalLocation.country // "") | test("^[A-Za-z]{2}$")' "${SAT_CFG}" >/dev/null 2>&1; then
        pass "physicalLocation $(jq -c .physicalLocation "${SAT_CFG}")"
    else
        info "  ${YW}⊘${CL} no physicalLocation — nothing shows it is off-site (#609)"
    fi
    [[ -n "$(sat_opnsense_uuid server)" ]] && pass "OPNsense tunnel server tappaas-edge-${SAT_NAME}" \
        || fail "OPNsense has no tunnel server tappaas-edge-${SAT_NAME}"
    [[ -n "$(sat_opnsense_uuid client)" ]] && pass "OPNsense peer tappaas-${SAT_NAME}" \
        || fail "OPNsense has no peer tappaas-${SAT_NAME}"

    # sshPort (ADR-010 §4.4.2): the home half exactly while it is set.
    SSHP="$(sat_ssh_port)"
    if ! ck="$(sat_check_ssh_config "${SAT_CFG}" 2>&1)"; then
        fail "${ck}"
    elif [[ -n "${SSHP}" ]]; then
        nat="$(sat_ssh_nat_row)"; mother="$(sat_mothership_addr)"
        if [[ -n "${nat}" ]] && jq -e --arg p "${SSHP}" --arg t "${mother}" '.["destination.port"] == $p and .target == $t' <<< "${nat}" >/dev/null; then
            pass "sshPort ${SSHP}: OPNsense forwards ${SAT_HOME_ADDR}:${SSHP} to the mothership ${mother}:22"
        else
            fail "sshPort ${SSHP}: no matching OPNsense port forward '$(sat_ssh_nat_desc)' (${nat:-none})"
        fi
        [[ -n "$(sat_ssh_rule_row)" ]] && pass "sshPort: edge rule '$(sat_ssh_rule_desc)'" \
            || fail "sshPort: no edge rule '$(sat_ssh_rule_desc)'"
    else
        [[ -z "$(sat_ssh_nat_row)" && -z "$(sat_ssh_rule_row)" ]] && pass "sshPort off: no port forward or rule for it on OPNsense" \
            || fail "sshPort is off but OPNsense still has '$(sat_ssh_nat_desc)' or '$(sat_ssh_rule_desc)' — the next update removes them"
    fi

    if [[ "${SAT_MGMT}" == managed ]]; then
        if sat_ssh true 2>/dev/null; then
            pass "the mothership reaches root@${ADDRESS}"
            age="$(TAPPAAS_SSH_RUNNER="" tunnel_handshake_age "${SAT_USER}@${ADDRESS}")" || age="down"
            case "${age}" in
                down|never|unknown) fail "tunnel: ${age}" ;;
                *) if (( age < 300 )); then pass "tunnel handshake ${age}s ago"; else fail "tunnel handshake ${age}s ago (stale)"; fi ;;
            esac
            if sat_has_role reverse-proxy; then
                sat_ssh systemctl is-active --quiet nginx && pass "reverse-proxy: nginx active" || fail "reverse-proxy: nginx not active"
            fi
            if sat_has_role admin-vpn; then
                sat_ssh 'nft list table ip adminvpn' >/dev/null 2>&1 && pass "admin-vpn: relay rules loaded" || fail "admin-vpn: relay rules missing"
            fi
            if [[ -n "${SSHP}" ]]; then
                allow="$(jq -r '.sshAllow[]' "${SAT_CFG}" | sort | paste -sd' ' -)"
                nftl="$(sat_ssh 'nft list chain inet filter input' 2>/dev/null | grep "tcp dport ${SSHP} accept")"
                [[ -n "${nftl}" && "${nftl}" == *"ip saddr"* ]] && pass "sshPort: the satellite firewall admits :${SSHP} from the allow-list only" \
                    || fail "sshPort: the satellite firewall has no allow-listed rule for :${SSHP}"
                ngx="$(sat_ssh 'nginx -T 2>/dev/null' | awk -v p="listen ${SSHP};" '$0 ~ p {f=1} f && /allow /{gsub(/[;]/,"",$2); print $2} f && /deny all/ {exit}' | sort | paste -sd' ' -)"
                [[ -n "${ngx}" && "${ngx}" == "${allow}" ]] && pass "sshPort: nginx passes :${SSHP} for ${allow} and denies the rest" \
                    || fail "sshPort: nginx allows '${ngx:-nothing}' on :${SSHP}, the config says '${allow}'"
                # The path behind nginx: through the tunnel and OPNsense's forward to the mothership's sshd.
                banner="$(sat_ssh "timeout 8 bash -c 'exec 3<>/dev/tcp/${SAT_HOME_ADDR}/${SSHP}; head -c 8 <&3'" 2>/dev/null)"
                [[ "${banner}" == SSH-2.0* ]] && pass "sshPort: through the tunnel to the mothership's sshd (${banner})" \
                    || fail "sshPort: ${SAT_HOME_ADDR}:${SSHP} through the tunnel does not reach an sshd"
            else
                # Off: no allow-listed TCP port outside the tunnel, no nginx listener
                # beyond the reverse proxy's.
                left="$(sat_ssh 'nft list chain inet filter input' 2>/dev/null | grep -v iifname | grep -E 'ip saddr .* tcp dport [0-9]+ accept')"
                left+="$(sat_ssh 'nginx -T 2>/dev/null' | awk '$1=="listen" {gsub(/;/,"",$2); if ($2!="80" && $2!="443") print " nginx:"$2}')"
                [[ -z "${left}" ]] && pass "sshPort off: nothing on the satellite admits or relays it" \
                    || fail "sshPort is off but the satellite still has:${left//$'\n'/ } — the next update re-provisions it"
            fi
            # ADR-031 P3: it watches the home site.
            if [[ "$(sat_ssh systemctl is-active tappaas-pulse.timer 2>/dev/null)" == "active" ]]; then
                pass "the pulse watches the home site ($(sat_ssh /usr/local/sbin/tappaas-pulse --status 2>/dev/null | awk '$1=="tunnel-home"{print $2}'))"
            else
                fail "the pulse is not running — the satellite does not watch the home site"
            fi
            "${here}/../debianhost/test.sh" "${INSTANCE}" || FAIL=$((FAIL + 1))
        else
            fail "the mothership's key does not reach root@${ADDRESS} — a managed satellite must accept it"
        fi
    else
        info "  ${YW}⊘${CL} locked down (unmanaged): the machine admits no login from home — checked from OPNsense only"
    fi
    info "Results: ${PASS} passed, ${FAIL} failed"
    [[ "${FAIL}" -eq 0 ]]
    exit
fi

# ── offline suite ────────────────────────────────────────────────────────────
pass=0; fail=0
ok() { echo "  ok   - $*"; pass=$((pass+1)); }
no() { echo "  FAIL - $*"; fail=$((fail+1)); }
tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT

# the lib, with the cicd routines stubbed (it needs only these)
lib() {
    info() { :; }; warn() { :; }; error() { echo "$*" >&2; }; debug() { :; }
    die() { echo "DIE: $*" >&2; exit 1; }
    BOLD=""; BL=""; CL=""; GN=""; YW=""
    # shellcheck source=lib/satellite-lib.sh
    . "${here}/lib/satellite-lib.sh"
}

# 1. contract files present, scripts parse
for f in README.md INSTALL.md satellite.json install.sh update.sh test.sh delete.sh lockdown.sh check-config.sh \
         lib/satellite-lib.sh lib/provision.sh lib/tunnel.sh \
         debian/provision-debian.sh debian/provision-backup.sh debian/set-management.sh; do
    [[ -f "${here}/${f}" ]] || { no "missing: ${f}"; continue; }
    [[ "${f}" == *.sh ]] && { bash -n "${here}/${f}" && ok "parses: ${f}" || no "syntax: ${f}"; }
done

# 1b. the NixOS satellite is retired (#712): a satellite is Debian, and the files
#     that backed `--os nixos` are gone. They tracked an EOL branch with no lock,
#     no test exercised them, and the backup role refused that OS outright — so a
#     satellite provisioned that way could not be the vault it exists to be.
for f in flake.nix disk-config.nix satellite.nix satellite-settings.nix; do
    [[ -e "${here}/${f}" ]] && no "retired NixOS file still present: ${f}" || ok "retired: ${f}"
done
# Not a grep for the message — the retired one read "os must be debian (default)
# or nixos", which contains the new text. Assert the BRANCH is gone instead.
grep -q '== nixos' "${here}/lib/satellite-lib.sh" \
    && no "install still branches on os nixos" || ok "install refuses any os but debian"
for fn in sat_nixos_anywhere sat_assemble_deploy sat_gen_settings; do
    grep -q "^${fn}()" "${here}/lib/provision.sh" && no "dead NixOS helper remains: ${fn}" || ok "gone: ${fn}"
done

# 2. the template: a managed Debian machine in the edge zone, with nothing the
#    operator must supply pre-filled (a copied example would look like data).
T="${here}/satellite.json"
if jq empty "${T}" 2>/dev/null; then
    jq -e '.kind == "machine" and .os == "debian" and .management == "managed" and .zone0 == "edge"
           and (.roles | sort) == ["admin-vpn","reverse-proxy"] and .rebootOk == false' "${T}" >/dev/null \
        && ok "template: managed Debian machine in edge, roles reverse-proxy + admin-vpn" || no "template shape"
    jq -e '(has("address") or has("physicalLocation") or has("vault") or has("backup")
            or ((.host // {}) | has("publicIp") or has("operatorSshKeys"))) | not' "${T}" >/dev/null \
        && ok "template: no address, key, location or vault pre-filled" || no "template carries operator values"
    jq -e 'has("tunnel") or has("reverseProxy") or has("adminVpn") or has("update") | not' "${T}" >/dev/null \
        && ok "template: derived values not exposed" || no "template exposes derived values"
else
    no "satellite.json is not valid JSON"
fi

# 3. sat_load: an instance by its name; a legacy satellite-<name>.json by <name>;
#    the name defaults to the instance; the address, legacy host.publicIp too.
mkdir -p "${tmp}/cfg"
echo '{"moduleSource":"/r/satellite","address":"203.0.113.7","roles":["reverse-proxy"]}' > "${tmp}/cfg/hel1.json"
echo '{"name":"satellite1","roles":["admin-vpn"],"host":{"publicIp":"198.51.100.4"},"os":"debian"}' > "${tmp}/cfg/satellite-satellite1.json"
got="$( lib; CONFIG_DIR="${tmp}/cfg"; sat_load hel1; printf '%s|%s|%s|%s|%s ' "${INSTANCE}" "${SAT_NAME}" "${ADDRESS}" "${SAT_MGMT}" "${SAT_OS}"
        sat_load satellite1; printf '%s|%s|%s' "${INSTANCE}" "${SAT_NAME}" "${ADDRESS}" )"
[[ "${got}" == "hel1|hel1|203.0.113.7|managed|debian satellite-satellite1|satellite1|198.51.100.4" ]] \
    && ok "sat_load: instance, legacy satellite-<name>.json, name + address defaults" || no "sat_load: '${got}'"

# 4. roles at add: backup is refused (lockdown sets it); an unknown role too
roles_rc() { ( lib; SAT_ROLES="$1"; SAT_MGMT="$2"; INSTANCE=t; sat_check_roles ) >/dev/null 2>&1; echo $?; }
if [[ "$(roles_rc reverse-proxy,admin-vpn managed)" == 0 && "$(roles_rc reverse-proxy,backup managed)" == 1 \
      && "$(roles_rc bogus managed)" == 1 && "$(roles_rc "" managed)" == 1 && "$(roles_rc admin-vpn,backup unmanaged)" == 0 ]]; then
    ok "roles: reverse-proxy/admin-vpn accepted; backup only when locked down; unknown/none refused"
else
    no "sat_check_roles"
fi
out="$( ( lib; SAT_ROLES=backup; SAT_MGMT=managed; INSTANCE=s1; sat_check_roles ) 2>&1 )"
grep -q -- '--lockdown' <<< "${out}" && ok "backup at add names the lockdown step" || no "backup refusal message: ${out}"

# 5. operator keys: the config's, else TAPPAAS_OPERATOR_KEY — never the mothership's
echo "ssh-ed25519 CICDKEY tappaas@cicd" > "${tmp}/id_ed25519.pub"
echo '{"host":{}}' > "${tmp}/cfg/k.json"
k1="$( lib; SAT_CICD_PUB="${tmp}/id_ed25519.pub"; SAT_CFG="${tmp}/cfg/k.json"
       TAPPAAS_OPERATOR_KEY=$'ssh-ed25519 OPKEY op@laptop\nssh-ed25519 CICDKEY tappaas@cicd' sat_operator_keys )"
echo '{"host":{"operatorSshKeys":["ssh-ed25519 REC op@ws"]}}' > "${tmp}/cfg/k2.json"
# shellcheck disable=SC2034  # read by sat_operator_keys
k2="$( lib; SAT_CICD_PUB="${tmp}/id_ed25519.pub"; SAT_CFG="${tmp}/cfg/k2.json"; TAPPAAS_OPERATOR_KEY="ssh-ed25519 OTHER x" sat_operator_keys )"
[[ "${k1}" == "ssh-ed25519 OPKEY op@laptop" && "${k2}" == "ssh-ed25519 REC op@ws" ]] \
    && ok "operator keys: recorded ones win; the mothership's key is never taken as one" || no "sat_operator_keys: '${k1}' / '${k2}'"

# 6. Debian configs: role-gated files; MANAGEMENT recorded; the cicd key shipped
#    only when given (managed)
( lib
  echo '{"os":"debian","roles":["reverse-proxy","admin-vpn"],"host":{"operatorSshKeys":["k"]}}' > "${tmp}/a.json"
  sat_gen_debian_configs "${tmp}/a.json" "HPUB=" "${tmp}/ao" "${tmp}/id_ed25519.pub"
  echo '{"os":"debian","roles":["reverse-proxy"],"management":"unmanaged","host":{"operatorSshKeys":["k"]}}' > "${tmp}/b.json"
  sat_gen_debian_configs "${tmp}/b.json" "HPUB=" "${tmp}/bo" "" )
if [[ -f "${tmp}/ao/nginx-stream.conf" && -f "${tmp}/ao/99-tappaas-ipforward.conf" ]] \
   && grep -q "table ip adminvpn" "${tmp}/ao/nftables.conf" && [[ ! -f "${tmp}/bo/99-tappaas-ipforward.conf" ]] \
   && ! grep -q "table ip adminvpn" "${tmp}/bo/nftables.conf" && [[ -f "${tmp}/bo/nginx-stream.conf" ]]; then
    ok "sat_gen_debian_configs role-gates files (nginx/ip_forward/admin-NAT)"
else
    no "sat_gen_debian_configs role-gating"
fi
if grep -q 'MANAGEMENT="managed"' "${tmp}/ao/roles.env" && grep -q 'MANAGEMENT="unmanaged"' "${tmp}/bo/roles.env" \
   && grep -q CICDKEY "${tmp}/ao/cicd_key.pub" && [[ ! -f "${tmp}/bo/cicd_key.pub" ]]; then
    ok "roles.env carries MANAGEMENT; the mothership's key ships only when given"
else
    no "MANAGEMENT / cicd_key.pub rendering"
fi
# set-management.sh (run last on the machine), on a scratch tree: managed
# authorizes the mothership's key and turns self-patching off; unmanaged turns it
# on and removes that key — and refuses when no operator key would remain.
sm() {  # <MANAGEMENT> <authorized_keys-content> → prints rc
    local d="${tmp}/sm"; rm -rf "${d}"; mkdir -p "${d}/apt" "${d}/ssh"
    cp "${here}/debian/set-management.sh" "${d}/"
    printf 'MANAGEMENT="%s"\n' "$1" > "${d}/roles.env"
    echo "ssh-ed25519 CICDKEY tappaas@cicd" > "${d}/cicd_key.pub"
    echo "U" > "${d}/20auto-upgrades"; echo "P" > "${d}/52tappaas-unattended-upgrades"
    printf '%s' "$2" > "${d}/ssh/authorized_keys"
    SAT_SM_TEST=1 SAT_SM_AUTHORIZED_KEYS="${d}/ssh/authorized_keys" SAT_SM_APT_DIR="${d}/apt" \
        bash "${d}/set-management.sh" >/dev/null 2>&1; echo $?
}
AKF="${tmp}/sm/ssh/authorized_keys"
rc="$(sm managed $'ssh-ed25519 OPKEY op@laptop\n')"
[[ "${rc}" == 0 ]] && grep -q CICDKEY "${AKF}" && grep -q OPKEY "${AKF}" && grep -q '"0"' "${tmp}/sm/apt/20auto-upgrades" \
   && [[ ! -f "${tmp}/sm/apt/52tappaas-unattended-upgrades" ]] \
    && ok "set-management managed: the mothership's key authorized, unattended-upgrades off" || no "set-management managed (rc=${rc})"
rc="$(sm unmanaged $'ssh-ed25519 OPKEY op@laptop\nssh-ed25519 CICDKEY tappaas@cicd\n')"
[[ "${rc}" == 0 ]] && ! grep -q CICDKEY "${AKF}" && grep -q OPKEY "${AKF}" && [[ -f "${tmp}/sm/apt/52tappaas-unattended-upgrades" ]] \
    && ok "set-management unmanaged: self-patching on, the mothership's key removed, the operator's kept" || no "set-management unmanaged (rc=${rc})"
rc="$(sm unmanaged $'ssh-ed25519 CICDKEY tappaas@cicd\n')"
[[ "${rc}" != 0 ]] && grep -q CICDKEY "${AKF}" \
    && ok "set-management unmanaged refuses — and keeps the key — when no operator key would remain" || no "set-management lock-out guard (rc=${rc})"

# 7. the vault's pull config (from `vault`, and a legacy `backup` block) + 0600 token
perm_bits() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
echo '{"roles":["backup"],"vault":{"pull":{"homePbsHost":"10.0.0.20","authId":"satellite@pbs!pull"}}}' > "${tmp}/v.json"
echo '{"roles":["backup"],"backup":{"pull":{"homePbsHost":"10.0.0.21"}}}' > "${tmp}/vl.json"
( lib; TAPPAAS_SAT_PBS_TOKEN="S3CR" sat_gen_backup_config "${tmp}/v.json" "${tmp}/vo"; sat_gen_backup_config "${tmp}/vl.json" "${tmp}/vlo" )
if grep -q 'HOME_PBS_HOST="10.0.0.20"' "${tmp}/vo/backup.env" && grep -q 'REMOVE_VANISHED="false"' "${tmp}/vo/backup.env" \
   && grep -q 'HOME_PBS_HOST="10.0.0.21"' "${tmp}/vlo/backup.env" \
   && [[ "$(cat "${tmp}/vo/pbs-remote-token" 2>/dev/null)" == "S3CR" && "$(perm_bits "${tmp}/vo/pbs-remote-token")" == "600" ]]; then
    ok "sat_gen_backup_config reads vault (and a legacy backup block); token 0600"
else
    no "sat_gen_backup_config"
fi
# the backup role widens the tunnel's AllowedIPs to the home PBS; others do not
( lib
  echo '{"roles":["backup"],"management":"unmanaged","vault":{"pull":{"homePbsHost":"10.0.0.20"}},"host":{"operatorSshKeys":["k"]}}' > "${tmp}/w.json"
  sat_gen_debian_configs "${tmp}/w.json" "HPUB=" "${tmp}/wo" "" )
grep -q 'AllowedIPs = 10.255.0.1/32, 10.0.0.20/32' "${tmp}/wo/wg-infra.conf" && grep -q 'AllowedIPs = 10.255.0.1/32$' "${tmp}/ao/wg-infra.conf" \
    && ok "backup widens wg AllowedIPs to the home PBS, others do not" || no "AllowedIPs gating"

# 8. edge rules are role-gated (API stubbed)
EDGE="${tmp}/edge"; : > "${EDGE}"
( lib
  _ow_api() { case "$*" in *searchRule*) echo '{"rows":[]}' ;; *apply*) : ;; *) printf '%s\n' "$*" >> "${EDGE}" ;; esac; }
  sat_ensure_edge_rules "reverse-proxy,admin-vpn" >/dev/null 2>&1 )
grep -q 'edge->caddy 80' "${EDGE}" && grep -q 'edge->caddy 443' "${EDGE}" && grep -q 'edge->admin-wg' "${EDGE}" \
    && ok "sat_ensure_edge_rules emits caddy + admin-wg rules" || no "sat_ensure_edge_rules output"

# 9. tunnel helpers over a mocked ssh
cat > "${tmp}/mockssh" << 'SH'
#!/usr/bin/env bash
case "$2" in
  *latest-handshakes*) printf 'FAKEPEERKEY\t1700000000\n' ;;
  "date +%s")          echo 1700000100 ;;
  *public-key*)        echo "FAKEPUBKEY=" ;;
  *)                   exit 1 ;;
esac
SH
chmod +x "${tmp}/mockssh"
[[ "$( lib; TAPPAAS_SSH_RUNNER="${tmp}/mockssh" tunnel_satellite_pubkey root@x )" == "FAKEPUBKEY=" \
   && "$( lib; TAPPAAS_SSH_RUNNER="${tmp}/mockssh" tunnel_handshake_age root@x )" == "100" ]] \
    && ok "tunnel helpers read the key and the handshake age (mocked)" || no "tunnel helpers"

# 10. install refuses — before touching anything — without an address, and when
#     OPNsense already has this satellite's tunnel (a second install would add a
#     duplicate server)
echo '{"roles":["reverse-proxy"],"host":{"operatorSshKeys":["ssh-ed25519 K o"]}}' > "${tmp}/cfg/na.json"
out="$( ( lib; CONFIG_DIR="${tmp}/cfg"; sat_load na; sat_install ) 2>&1 )"
grep -q 'no address' <<< "${out}" && ok "install refuses without an address, naming --address" || no "install without address: ${out}"
echo '{"roles":["reverse-proxy"],"address":"203.0.113.9","host":{"operatorSshKeys":["ssh-ed25519 K o"]}}' > "${tmp}/cfg/dup.json"
out="$( ( lib; CONFIG_DIR="${tmp}/cfg"; sat_load dup
          _ow_api() { case "$*" in *searchServer*) echo '{"rows":[{"name":"tappaas-edge-dup","uuid":"S1"}]}' ;; *) echo "CALLED $*" ;; esac; }
          ow_genkey() { echo "GENKEY-CALLED"; }
          sat_install ) 2>&1 )"
grep -q 'already has tappaas-edge-dup' <<< "${out}" && ! grep -q 'GENKEY-CALLED\|addServer' <<< "${out}" \
    && ok "install refuses a satellite already wired on OPNsense, naming --decommission" || no "install over an existing tunnel: ${out}"

# 11. decommission removes this satellite's peer and server; the shared edge rules
#     go only with the last satellite
DEC="${tmp}/dec"
dec() {  # <other-satellite-present:0|1>
    : > "${DEC}"
    rm -rf "${tmp}/dcfg"; mkdir -p "${tmp}/dcfg"
    cp "${tmp}/cfg/hel1.json" "${tmp}/dcfg/"
    echo '{"moduleSource":"/r/debianhost"}' > "${tmp}/dcfg/dh1.json"     # not a satellite
    [[ "$1" == 1 ]] && echo '{"moduleSource":"/r/satellite"}' > "${tmp}/dcfg/other.json"
    ( lib; CONFIG_DIR="${tmp}/dcfg"; sat_load hel1
      _ow_api() {
          case "$*" in
              *searchClient*) echo '{"rows":[{"name":"tappaas-hel1","uuid":"C1"},{"name":"tappaas-x","uuid":"C9"}]}' ;;
              *searchServer*) echo '{"rows":[{"name":"tappaas-edge-hel1","uuid":"S1"}]}' ;;
              *searchRule*)   echo '{"rows":[{"description":"tappaas-satellite edge->caddy 80","uuid":"R1"}]}' ;;
              *)              printf '%s\n' "$*" >> "${DEC}" ;;
          esac; }
      sat_decommission ) >/dev/null 2>&1
}
dec 1
grep -q 'delClient/C1' "${DEC}" && grep -q 'delServer/S1' "${DEC}" && ! grep -q 'C9' "${DEC}" && ! grep -q 'delRule' "${DEC}" \
    && ok "decommission removes its own peer + server, keeps edge rules another satellite uses" || no "decommission (other present): $(tr '\n' ' ' < "${DEC}")"
dec 0
grep -q 'delRule/R1' "${DEC}" && ok "decommission of the last satellite removes the edge rules" || no "decommission (last): $(tr '\n' ' ' < "${DEC}")"

# 12. lockdown (ADR-010 §8.4.4) — its refusals, before anything is touched
L="${tmp}/lcfg"; mkdir -p "${L}"
lk() {  # <backup.json> <instance.json> → the lockdown's output (lib stubbed; nothing real is reached)
    printf '%s' "$1" > "${L}/backup.json"; printf '%s' "$2" > "${L}/v1.json"
    ( lib; CONFIG_DIR="${L}"; sat_load v1
      sat_ssh() { return 0; }; _ow_api() { echo '{}'; }; backup-manager() { echo "BM-CALLED"; }
      sat_lockdown ) 2>&1
}
V='{"moduleSource":"/r/satellite","address":"203.0.113.7","roles":["reverse-proxy"],"host":{"operatorSshKeys":["ssh-ed25519 OP o"]}'
out="$(lk '{"placementState":"node","node":"v1"}' "${V}}")"
grep -q "the Site's PBS Host" <<< "${out}" && ! grep -q BM-CALLED <<< "${out}" && ok "lockdown refused when the satellite is the Site's PBS Host" || no "lockdown on the PBS Host: ${out}"
out="$(lk '{"placementState":"external","pbsUrl":"x"}' "${V}}")"
grep -q "a PBS of the Site's own" <<< "${out}" && ok "lockdown refused when the Site has no PBS of its own to pull" || no "lockdown without a Site PBS: ${out}"
out="$(lk '{"placementState":"node","node":"tappaas3"}' '{"moduleSource":"/r/satellite","address":"203.0.113.7","host":{}}')"
grep -q "no operator key" <<< "${out}" && ok "lockdown refused when no operator key is recorded (it would lock everyone out)" || no "lockdown without operator key: ${out}"
out="$(lk '{"placementState":"node","node":"tappaas3"}' "${V},\"management\":\"unmanaged\"}")"
grep -q "already locked down" <<< "${out}" && ok "lockdown refused when already unmanaged" || no "lockdown twice: ${out}"

# 13. lockdown's happy path, every outside call stubbed: the grant is made with
#     the password the vault is handed; the vault is rendered locked down; the
#     three scripts run in order, set-management last; then it is recorded.
LOG="${tmp}/lockdown.log"; : > "${LOG}"
lkrun() {  # <still-reachable-after:0|1>
    local still="$1"
    printf '%s' '{"placementState":"node","node":"tappaas3","pbsStorageName":"tappaas_backup"}' > "${L}/backup.json"
    printf '%s' "${V},\"physicalLocation\":{\"country\":\"FI\",\"city\":\"Helsinki\"}}" > "${L}/v1.json"
    echo "ssh-ed25519 CICDKEY tappaas@cicd" > "${tmp}/cicd.pub"
    # shellcheck disable=SC2034  # read by sat_lockdown
    ( lib; CONFIG_DIR="${L}"; SAT_CICD_PUB="${tmp}/cicd.pub"; sat_load v1
      n=0; sat_ssh() { n=$((n + 1)); [[ "${n}" -eq 1 || "${still}" == 1 ]]; }
      sat_home_pbs_address() { echo 10.0.0.23; }
      sat_pbs_fingerprint() { echo "aa:bb"; }
      _ow_api() { case "$*" in *searchServer*) echo '{"rows":[{"name":"tappaas-edge-v1","uuid":"S1"}]}' ;;
                               *getServer/S1*) echo '{"server":{"pubkey":"HOMEPUB="}}' ;;
                               *searchRule*) echo '{"rows":[]}' ;; *) echo "API $*" >> "${LOG}" ;; esac; }
      backup-manager() { echo "BM $* PW=${TAPPAAS_REMOTE_PASSWORD}" >> "${LOG}"; }
      sat_deploy_run() {
          echo "DEPLOY ${*:4}" >> "${LOG}"
          grep -q 'MANAGEMENT="unmanaged"' "$1/roles.env" && grep -q backup "$1/roles.env" && echo "RENDER unmanaged+backup" >> "${LOG}"
          grep -q CICDKEY "$1/cicd_key.pub" && echo "RENDER cicd-key" >> "${LOG}"
          grep -q 'HOME_PBS_HOST="10.0.0.23"' "$1/backup.env" && grep -q 'REMOTE_AUTHID="v1@pbs"' "$1/backup.env" && echo "RENDER backup.env" >> "${LOG}"
          grep -q 'AllowedIPs = 10.255.0.1/32, 10.0.0.23/32' "$1/wg-infra.conf" && echo "RENDER allowedips" >> "${LOG}"
          echo "TOKEN $(cat "$1/pbs-remote-token")" >> "${LOG}"
      }
      sat_lockdown ) >/dev/null 2>&1
    echo $?
}
rc="$(lkrun 0)"
pw_bm="$(sed -n 's/^BM .* PW=//p' "${LOG}")"; pw_sat="$(sed -n 's/^TOKEN //p' "${LOG}")"
if [[ "${rc}" == 0 ]] && grep -q '^BM peer add remote v1 --auth-id v1@pbs --country FI --city Helsinki --force' "${LOG}" \
   && [[ -n "${pw_bm}" && "${pw_bm}" == "${pw_sat}" ]] \
   && grep -q 'DEPLOY provision-debian.sh provision-backup.sh set-management.sh' "${LOG}" \
   && grep -q 'RENDER unmanaged+backup' "${LOG}" && grep -q 'RENDER cicd-key' "${LOG}" \
   && grep -q 'RENDER backup.env' "${LOG}" && grep -q 'RENDER allowedips' "${LOG}" && grep -q 'addRule' "${LOG}" \
   && jq -e '.management == "unmanaged" and (.roles | index("backup")) and .vault.pull.homePbsHost == "10.0.0.23"
             and .vault.pull.fingerprint == "aa:bb"' "${L}/v1.json" >/dev/null; then
    ok "lockdown: read-only grant with the vault's own password, vault rendered locked down, set-management last, recorded unmanaged"
else
    no "lockdown happy path (rc=${rc}): $(tr '\n' '|' < "${LOG}")"
fi
: > "${LOG}"
rc="$(lkrun 1)"
[[ "${rc}" != 0 ]] && jq -e '.management != "unmanaged"' "${L}/v1.json" >/dev/null \
    && ok "lockdown: when the mothership can still log in afterwards, it fails and stays managed" || no "lockdown stale key (rc=${rc})"

# 14. the satellite as the Site's PBS Host (ADR-010 §8.4.3)
#   rendering: the nodes' subnet joins the AllowedIPs and may reach :8007 — on
#   the tunnel interface only; without it neither appears
( lib
  echo '{"os":"debian","roles":["reverse-proxy"],"host":{"operatorSshKeys":["k"]}}' > "${tmp}/p.json"
  SAT_PBS_CLIENTS="10.0.0.0/24" sat_gen_debian_configs "${tmp}/p.json" "HPUB=" "${tmp}/po" ""
  sat_gen_debian_configs "${tmp}/p.json" "HPUB=" "${tmp}/pn" "" )
grep -q 'AllowedIPs = 10.255.0.1/32, 10.0.0.0/24' "${tmp}/po/wg-infra.conf" \
   && grep -q 'iifname "wg-infra" ip saddr 10.0.0.0/24 tcp dport 8007 accept' "${tmp}/po/nftables.conf" \
   && ! grep -q '8007' "${tmp}/pn/nftables.conf" && ! grep -q '10.0.0.0/24' "${tmp}/pn/wg-infra.conf" \
    && ok "PBS Host rendering: the nodes admitted to :8007 through the tunnel only; a relay admits none" || no "PBS Host rendering"

P="${tmp}/pcfg"; mkdir -p "${P}"
echo '{"mgmt":{"ip":"10.0.0.0/24","bridge":"lan"}}' > "${P}/zones.json"
echo '{"moduleSource":"/r/satellite","address":"203.0.113.7","roles":["reverse-proxy"],"host":{"operatorSshKeys":["k"]}}' > "${P}/sat1.json"
isph() { printf '%s' "$1" > "${P}/backup.json"; ( lib; CONFIG_DIR="${P}"; sat_load sat1; sat_is_pbs_host ) && echo yes || echo no; }
[[ "$(isph '{"placementState":"node","node":"sat1"}')" == yes && "$(isph '{"placementState":"node:sat1"}')" == yes \
   && "$(isph '{"placementState":"node","node":"tappaas3"}')" == no && "$(isph '{"placementState":"shim","node":"sat1"}')" == no ]] \
    && ok "sat_is_pbs_host: node (and the pre-#600 node:<name>) naming it; a shim constraint does not" || no "sat_is_pbs_host"

#   the DNS entry is at the tunnel end: added when missing, replaced when it
#   points elsewhere (the public address), left when right
DNSLOG="${tmp}/dns.log"
dnsrun() {  # <current-ip-or-empty>
    : > "${DNSLOG}"
    ( lib; CONFIG_DIR="${P}"; sat_load sat1
      dns-manager() { case "$*" in *list*) if [[ -n "${_dns_cur}" ]]; then echo "  sat1.mgmt.internal  -> ${_dns_cur}  (x)"; fi ;; *) echo "$*" >> "${DNSLOG}" ;; esac; }
      _dns_cur="$1"; sat_dns_ensure ) >/dev/null 2>&1
    tr '\n' '|' < "${DNSLOG}"
}
[[ "$(dnsrun "")" == "--no-ssl-verify add sat1 mgmt.internal 10.255.0.0 --description TAPPaaS satellite sat1 (its tunnel end)|" \
   && "$(dnsrun 203.0.113.7)" == "--no-ssl-verify delete sat1 mgmt.internal|--no-ssl-verify add sat1 mgmt.internal 10.255.0.0 --description TAPPaaS satellite sat1 (its tunnel end)|" \
   && "$(dnsrun 10.255.0.0)" == "" ]] \
    && ok "sat_dns_ensure: <name>.mgmt.internal at the tunnel end — added, corrected, or left" || no "sat_dns_ensure: '$(dnsrun "")' / '$(dnsrun 203.0.113.7)' / '$(dnsrun 10.255.0.0)'"

#   opening and closing the path: the OPNsense rule, and a re-provision only on
#   a change — with the nodes' subnet when opening, without when closing
PLOG="${tmp}/path.log"
pathrun() {  # <open|close> <rule-present:0|1> <satellite-open:0|1>
    : > "${PLOG}"
    local want="$1" rule="$2" sopen="$3"
    # shellcheck disable=SC2034  # read by sat_pbs_path
    ( lib; CONFIG_DIR="${P}"; SAT_CICD_PUB="${tmp}/cicd.pub"; sat_load sat1
      sat_dns_ensure() { echo "DNS" >> "${PLOG}"; }
      sat_pbs_path_is_open() { [[ "${sopen}" == 1 ]]; }
      sat_home_pubkey() { echo HPUB=; }
      _ow_api() { case "$*" in
          *searchRule*) if [[ "${rule}" == 1 ]]; then echo '{"rows":[{"description":"tappaas-satellite mgmt->pbs sat1","uuid":"R7"}]}'; else echo '{"rows":[]}'; fi ;;
          *addRule*) rule=1; echo "ADD $*" >> "${PLOG}" ;; *delRule*) echo "DEL $*" >> "${PLOG}" ;; esac; }
      sat_deploy_run() { echo "DEPLOY ${*:4} $(grep -c 'dport 8007' "$1/nftables.conf")" >> "${PLOG}"; }
      sat_pbs_path "${want}" ) >/dev/null 2>&1
    echo "rc=$? $(tr '\n' '|' < "${PLOG}")"
}
o1="$(pathrun open 0 0)"; o2="$(pathrun open 1 1)"; c1="$(pathrun close 1 1)"; c2="$(pathrun close 0 0)"
if [[ "${o1}" == rc=0\ DNS\|ADD*'"interface":"lan"'*'"source_net":"10.0.0.0/24"'*'"destination_net":"10.255.0.0"'*'"destination_port":"8007"'*\|DEPLOY\ provision-debian.sh\ set-management.sh\ 1\| ]] \
   && [[ "${o2}" == "rc=0 DNS|" ]] \
   && [[ "${c1}" == rc=0\ DEL*R7*\|DEPLOY\ provision-debian.sh\ set-management.sh\ 0\| ]] \
   && [[ "${c2}" == "rc=0 " ]]; then
    ok "sat_pbs_path: open adds the mgmt rule and re-provisions with :8007; close reverses it; nothing when already so"
else
    no "sat_pbs_path: open='${o1}' open-again='${o2}' close='${c1}' close-again='${c2}'"
fi

#   decommission refuses while it is the Site's PBS Host
printf '%s' '{"placementState":"node","node":"sat1"}' > "${P}/backup.json"
out="$( ( lib; CONFIG_DIR="${P}"; sat_load sat1; _ow_api() { echo "CALLED"; }; sat_decommission ) 2>&1 )"
grep -q "the Site's PBS Host" <<< "${out}" && ! grep -q CALLED <<< "${out}" \
    && ok "decommission refused while the satellite is the Site's PBS Host" || no "decommission of the PBS Host: ${out}"

# 15. sshPort — SSH to the mothership through the satellite (ADR-010 §4.4.2)
#   validation (check-config.sh: module add, modify --set): an allow-list is
#   required, the port must be free on the satellite, a vault takes none
cc() { printf '%s' "$1" > "${tmp}/cc.json"; "${here}/check-config.sh" "${tmp}/cc.json" >/dev/null 2>&1; echo $?; }
if [[ "$(cc '{}')" == 0 && "$(cc '{"sshPort":0}')" == 0 \
      && "$(cc '{"sshPort":2222,"sshAllow":["198.51.100.7","10.20.0.0/16"]}')" == 0 \
      && "$(cc '{"sshPort":2222}')" == 1 && "$(cc '{"sshPort":2222,"sshAllow":[]}')" == 1 \
      && "$(cc '{"sshPort":2222,"sshAllow":["0.0.0.0/0"]}')" == 1 && "$(cc '{"sshPort":2222,"sshAllow":["198.51.100.7/24"]}')" == 1 \
      && "$(cc '{"sshPort":2222,"sshAllow":["2001:db8::1"]}')" == 1 && "$(cc '{"sshPort":"2222","sshAllow":["198.51.100.7"]}')" == 1 \
      && "$(cc '{"sshPort":22,"sshAllow":["198.51.100.7"]}')" == 1 && "$(cc '{"sshPort":443,"sshAllow":["198.51.100.7"]}')" == 1 \
      && "$(cc '{"sshPort":2222,"sshAllow":["198.51.100.7"],"management":"unmanaged"}')" == 1 ]]; then
    ok "check-config: sshPort needs a non-empty IPv4 allow-list, a free port, a managed satellite"
else
    no "check-config sshPort rules"
fi
out="$(printf '%s' '{"sshPort":2222}' > "${tmp}/cc.json"; "${here}/check-config.sh" "${tmp}/cc.json" 2>&1)"
grep -q 'sshAllow' <<< "${out}" && ok "check-config names sshAllow when the allow-list is missing" || no "check-config message: ${out}"

#   rendering: nftables admits the port from the list only; nginx allows the
#   list, denies the rest and passes to the tunnel's home end; a satellite with
#   only admin-vpn gets nginx for it; without sshPort none of it appears
( lib
  echo '{"roles":["reverse-proxy","admin-vpn"],"sshPort":2222,"sshAllow":["198.51.100.7","10.20.0.0/16"],"host":{"operatorSshKeys":["k"]}}' > "${tmp}/s.json"
  sat_gen_debian_configs "${tmp}/s.json" "HPUB=" "${tmp}/so" ""
  echo '{"roles":["admin-vpn"],"sshPort":2222,"sshAllow":["198.51.100.7"],"host":{"operatorSshKeys":["k"]}}' > "${tmp}/s2.json"
  sat_gen_debian_configs "${tmp}/s2.json" "HPUB=" "${tmp}/so2" "" )
if grep -q 'ip saddr { 198.51.100.7, 10.20.0.0/16 } tcp dport 2222 accept' "${tmp}/so/nftables.conf" \
   && grep -q 'SSH_PORT="2222"' "${tmp}/so/roles.env" && grep -q 'SSH_PORT=""' "${tmp}/ao/roles.env" \
   && awk '/listen 2222;/{f=1} f' "${tmp}/so/nginx-stream.conf" | tr -d '\n ' | grep -c 'allow198.51.100.7;allow10.20.0.0/16;denyall;proxy_timeout12h;proxy_pass10.255.0.1:2222;' >/dev/null \
   && grep -q 'listen 443;' "${tmp}/so/nginx-stream.conf" \
   && grep -q 'listen 2222;' "${tmp}/so2/nginx-stream.conf" && ! grep -q 'listen 443;' "${tmp}/so2/nginx-stream.conf" \
   && ! grep -q 'dport 2222\|ip saddr {' "${tmp}/ao/nftables.conf" && ! grep -q 'listen 2222\|deny all' "${tmp}/ao/nginx-stream.conf"; then
    ok "sshPort rendering: nftables + nginx allow-list, passthrough to the tunnel; nothing without it"
else
    no "sshPort rendering"
fi
grep -q 'wants_nginx && PKGS+=(nginx' "${here}/debian/provision-debian.sh" && grep -q 'systemctl disable --now nginx' "${here}/debian/provision-debian.sh" \
    && ok "provision-debian: nginx for reverse-proxy or sshPort, stopped when neither needs it" || no "provision-debian nginx gating"

#   the home half: a port forward on the tunnel to the mothership :22 and the
#   edge rule, by this satellite's name — added, left, replaced, removed
S="${tmp}/scfg"; mkdir -p "${S}"
HLOG="${tmp}/home.log"
SSHCFG='{"moduleSource":"/r/satellite","address":"203.0.113.7","roles":["reverse-proxy"],"sshPort":2222,"sshAllow":["198.51.100.7"]}'
homerun() {  # <ensure|remove> <nat-row-json-or-empty> <rule-row-json-or-empty> [config]
    : > "${HLOG}"
    printf '%s' "${4:-${SSHCFG}}" > "${S}/sat1.json"
    printf '%s' "$2" > "${tmp}/nat.row"; printf '%s' "$3" > "${tmp}/rule.row"
    # shellcheck disable=SC2034  # read by sat_mothership_addr
    ( lib; CONFIG_DIR="${S}"; SAT_MOTHERSHIP_ADDR=10.0.0.10; sat_load sat1
      _ow_api() { case "$*" in
          *d_nat/searchRule*) echo "{\"rows\":[$(cat "${tmp}/nat.row")]}" ;;
          *filter/searchRule*) echo "{\"rows\":[$(cat "${tmp}/rule.row")]}" ;;
          *d_nat/addRule*) echo '{"uuid":"N2","descr":"tappaas-satellite sat1 sshPort->mothership"}' > "${tmp}/nat.row"; printf 'NATADD %s\n' "$*" >> "${HLOG}" ;;
          *filter/addRule*) echo '{"uuid":"F2","description":"tappaas-satellite edge->mothership ssh sat1"}' > "${tmp}/rule.row"; printf 'RULEADD %s\n' "$*" >> "${HLOG}" ;;
          *) printf '%s\n' "$*" >> "${HLOG}" ;;
      esac; }
      sat_ssh_home "$1" ) >/dev/null 2>&1
    echo "rc=$? $(tr '\n' '|' < "${HLOG}")"
}
NATOK='{"uuid":"N1","descr":"tappaas-satellite sat1 sshPort->mothership","destination.port":"2222","target":"10.0.0.10","local-port":"22","disabled":"0"}'
RULEOK='{"uuid":"F1","description":"tappaas-satellite edge->mothership ssh sat1","destination_net":"10.0.0.10","destination_port":"22"}'
h1="$(homerun ensure "" "")"; h2="$(homerun ensure "${NATOK}" "${RULEOK}")"
h3="$(homerun ensure "${NATOK/2222/2200}" "${RULEOK}")"; h4="$(homerun remove "${NATOK}" "${RULEOK}")"
h5="$(homerun remove "" "" '{"moduleSource":"/r/satellite","address":"203.0.113.7","roles":["reverse-proxy"]}')"
if [[ "${h1}" == rc=0\ NATADD*'"interface":"wireguard"'*'"source":{"network":"10.255.0.0"}'*'"destination":{"network":"10.255.0.1","port":"2222"}'*'"target":"10.0.0.10","local-port":"22"'*'sat1 sshPort->mothership'*\|RULEADD*'"source_net":"10.255.0.0/31","destination_net":"10.0.0.10","destination_port":"22","description":"tappaas-satellite edge->mothership ssh sat1"'*\|*d_nat/apply*filter/apply*\| ]] \
   && [[ "${h2}" == "rc=0 " ]] \
   && [[ "${h3}" == rc=0\ *d_nat/delRule/N1*\|NATADD*'"port":"2222"'*\|*d_nat/apply* && "${h3}" != *RULEADD* && "${h3}" != *filter/delRule* ]] \
   && [[ "${h4}" == rc=0\ *d_nat/delRule/N1*filter/delRule/F1*d_nat/apply*filter/apply* ]] \
   && [[ "${h5}" == "rc=0 " ]]; then
    ok "sat_ssh_home: forward + edge rule added, left when right, replaced on a new port, removed when off"
else
    no "sat_ssh_home: add='${h1}' same='${h2}' port='${h3}' remove='${h4}' none='${h5}'"
fi

#   the satellite half: re-provisioned only when its firewall or nginx differs
#   from what the config renders (comments aside)
RLOG="${tmp}/relay.log"
relayrun() {  # <sshPort-in-config:0|1> <satellite-has-it:0|1>
    : > "${RLOG}"
    local conf='{"moduleSource":"/r/satellite","address":"203.0.113.7","roles":["reverse-proxy"],"host":{"operatorSshKeys":["k"]}'
    [[ "$1" == 1 ]] && conf+=',"sshPort":2222,"sshAllow":["198.51.100.7"]'
    printf '%s}' "${conf}" > "${S}/sat1.json"
    local on='{"moduleSource":"/r/satellite","roles":["reverse-proxy"],"sshPort":2222,"sshAllow":["198.51.100.7"],"host":{"operatorSshKeys":["k"]}}'
    local off='{"moduleSource":"/r/satellite","roles":["reverse-proxy"],"host":{"operatorSshKeys":["k"]}}'
    ( lib; [[ "$2" == 1 ]] && printf '%s' "${on}" > "${tmp}/live.json" || printf '%s' "${off}" > "${tmp}/live.json"
      sat_gen_debian_configs "${tmp}/live.json" "HPUB=" "${tmp}/live" ""
      sed -i.bak 's/the satellite module/satellite-manager/' "${tmp}/live/nftables.conf" "${tmp}/live/nginx-stream.conf" )
    # shellcheck disable=SC2034  # read by sat_relay_converge
    ( lib; CONFIG_DIR="${S}"; SAT_CICD_PUB="${tmp}/cicd.pub"; sat_load sat1
      sat_home_pubkey() { echo HPUB=; }
      sat_ssh() { case "$*" in *nftables.conf*) cat "${tmp}/live/nftables.conf" ;; *nginx.conf*) cat "${tmp}/live/nginx-stream.conf" ;; *) return 0 ;; esac; }
      sat_deploy_run() { echo "DEPLOY ${*:4} $(grep -c 'dport 2222' "$1/nftables.conf")" >> "${RLOG}"; }
      sat_relay_converge ) >/dev/null 2>&1
    echo "rc=$? $(tr '\n' '|' < "${RLOG}")"
}
r1="$(relayrun 1 0)"; r2="$(relayrun 1 1)"; r3="$(relayrun 0 1)"; r4="$(relayrun 0 0)"
[[ "${r1}" == "rc=0 DEPLOY provision-debian.sh set-management.sh 1|" && "${r2}" == "rc=0 " \
   && "${r3}" == "rc=0 DEPLOY provision-debian.sh set-management.sh 0|" && "${r4}" == "rc=0 " ]] \
    && ok "sat_relay_converge: re-provisions on a difference only, a legacy file's comments aside" \
    || no "sat_relay_converge: on='${r1}' on-again='${r2}' off='${r3}' off-again='${r4}'"

#   decommission removes this satellite's forward and rule; lockdown refuses
#   while sshPort is on
printf '%s' '{"moduleSource":"/r/satellite","address":"203.0.113.7","roles":["reverse-proxy"],"sshPort":2222,"sshAllow":["198.51.100.7"]}' > "${S}/sat1.json"
rm -f "${S}/backup.json"
: > "${HLOG}"
( lib; CONFIG_DIR="${S}"; sat_load sat1
  _ow_api() { case "$*" in
      *d_nat/searchRule*) echo "{\"rows\":[${NATOK}]}" ;; *filter/searchRule*) echo "{\"rows\":[${RULEOK}]}" ;;
      *search*) echo '{"rows":[]}' ;; *) printf '%s\n' "$*" >> "${HLOG}" ;; esac; }
  sat_decommission ) >/dev/null 2>&1
grep -q 'd_nat/delRule/N1' "${HLOG}" && grep -q 'filter/delRule/F1' "${HLOG}" \
    && ok "decommission removes the sshPort forward and edge rule" || no "decommission sshPort: $(tr '\n' ' ' < "${HLOG}")"
out="$(lk '{"placementState":"node","node":"tappaas3"}' "${V},\"sshPort\":2222,\"sshAllow\":[\"198.51.100.7\"]}")"
grep -q 'sshPort=0' <<< "${out}" && ! grep -q BM-CALLED <<< "${out}" \
    && ok "lockdown refused while sshPort is on" || no "lockdown with sshPort: ${out}"

# 16. deep: reverse-proxy end-to-end through a live satellite (test-vm-creation/)
if [[ "${TAPPAAS_TEST_DEEP:-0}" == "1" ]]; then
    echo "  deep: reverse-proxy end-to-end (test-vm-creation/)"
    if [[ -x "${here}/test-vm-creation/test.sh" ]]; then
        "${here}/test-vm-creation/test.sh" && ok "reverse-proxy deep test passed (or skipped: prerequisites absent)" \
            || no "reverse-proxy deep test failed"
    else
        no "missing: test-vm-creation/test.sh"
    fi
fi

echo ""
echo "satellite module tests: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
