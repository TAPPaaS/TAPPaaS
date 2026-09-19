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
for f in README.md INSTALL.md satellite.json satellite.nix install.sh update.sh test.sh delete.sh lockdown.sh \
         lib/satellite-lib.sh lib/provision.sh lib/tunnel.sh \
         debian/provision-debian.sh debian/provision-backup.sh debian/set-management.sh; do
    [[ -f "${here}/${f}" ]] || { no "missing: ${f}"; continue; }
    [[ "${f}" == *.sh ]] && { bash -n "${here}/${f}" && ok "parses: ${f}" || no "syntax: ${f}"; }
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

# 14. deep: reverse-proxy end-to-end through a live satellite (test-vm-creation/)
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
