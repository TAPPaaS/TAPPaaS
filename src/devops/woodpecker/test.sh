#!/usr/bin/env bash
# TAPPaaS Module: woodpecker — Verification Tests
#
# Run from tappaas-cicd as the tappaas user. Usage: ./test.sh [vmname]

set -uo pipefail

. /home/tappaas/bin/common-install-routines.sh "${1:-woodpecker}" 2>/dev/null || true

VMNAME="$(get_config_value 'vmname' 'woodpecker' 2>/dev/null || echo woodpecker)"
ZONE0NAME="$(get_config_value 'zone0' 'srv' 2>/dev/null || echo srv)"
TARGET="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes)
remote() { ssh "${SSH_OPTS[@]}" "tappaas@${TARGET}" "$@" 2>/dev/null; }

PASSED=0; FAILED=0
pass() { info "  ${GN}✓${CL} $1"; PASSED=$((PASSED + 1)); }
fail() { error "  ✗ $1"; FAILED=$((FAILED + 1)); }
skipt() { info "  - $1 (skipped)"; }

info "${BOLD}Woodpecker on ${TARGET}${CL}"
remote "exit 0" || { fail "cannot reach tappaas@${TARGET}"; echo "Results: ${PASSED} passed, ${FAILED} failed"; exit 1; }

if [[ "$(remote "sudo test -s /etc/secrets/forgejo-oauth.env && echo yes")" != "yes" ]]; then
    fail "no Forgejo client (/etc/secrets/forgejo-oauth.env) — forgejo:oauth has not run"
    echo ""; info "Results: ${PASSED} passed, ${FAILED} failed"; exit 1
fi

# 1. The server, the agent, Docker and the pipelines' fence run.
for u in docker woodpecker-server woodpecker-agent-docker woodpecker-egress; do
    [[ "$(remote "systemctl is-active ${u}")" == "active" ]] && pass "${u} is active" || fail "${u} is not active"
done

# 2. Both answer; the agents' port is the VM's own.
[[ "$(remote "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:8000/healthz")" == "200" ]] \
    && pass "the server's /healthz answers 200" || fail "the server's /healthz does not answer 200"
[[ "$(remote "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:3000/healthz")" == "200" ]] \
    && pass "the agent is healthy (connected to the server)" || fail "the agent's /healthz does not answer 200"
_grpc="$(remote "ss -Hltn 'sport = :9000'" | awk '{print $4}' | sort -u | paste -sd' ' -)"
[[ "${_grpc}" == "127.0.0.1:9000" ]] && pass "the agents' gRPC port listens on 127.0.0.1 only" \
    || fail "the agents' gRPC port listens on ${_grpc:-nothing}"

# 3. Sign-in goes to Forgejo.
_forge="$(remote "sudo sed -n 's/^FORGEJO_URL=//p' /etc/secrets/forgejo-oauth.env")"
_loc="$(remote "curl -s -o /dev/null -w '%{redirect_url}' --max-time 10 http://localhost:8000/authorize")"
[[ -n "${_forge}" && "${_loc}" == "${_forge}/login/oauth/authorize"* ]] && pass "Login goes to Forgejo (${_forge})" \
    || fail "/authorize does not hand over to Forgejo (${_loc:-no redirect})"

# 4. No plugin may run privileged.
_priv="$(remote "systemctl show -p Environment --value woodpecker-server" | tr ' ' '\n' | sed -n 's/^WOODPECKER_PLUGINS_PRIVILEGED=//p')"
[[ -z "${_priv}" ]] && pass "no plugin may run privileged" || fail "privileged plugins allowed: ${_priv}"

# 5. A pipeline container reaches the internet and Forgejo, not the site's other addresses.
_fhost="${_forge#*://}"; _fhost="${_fhost%%/*}"; _fhost="${_fhost%%:*}"
_fport=443; [[ "${_forge}" == http://* ]] && _fport=80; [[ "${_forge#*://}" =~ ^[^/]+:([0-9]+) ]] && _fport="${BASH_REMATCH[1]}"
# A neighbour the VM itself reaches (Forgejo's VM, SSH, same zone): refused to
# a container only by the fence, not by the firewall.
_fj="$(jq -r '"\(.vmname).\(.zone0).internal"' "${CONFIG_DIR:-/home/tappaas/config}/forgejo.json" 2>/dev/null)"
_fjip="$(getent ahostsv4 "${_fj}" | awk '{print $1; exit}')"
_probe="$(remote "sudo bash -s" <<EOF
net=tappaas-test-\$\$
docker network create "\$net" >/dev/null
timeout 5 bash -c "</dev/tcp/${_fjip}/22" 2>/dev/null && echo vm-site=open || echo vm-site=closed
docker run --rm --network "\$net" docker.io/library/busybox:1.37.0 sh -c "
  nc -z -w 5 1.1.1.1 443 && echo internet=open || echo internet=closed
  nc -z -w 5 ${_fhost} ${_fport} && echo forge=open || echo forge=closed
  nc -z -w 5 ${_fjip} 22 && echo site=open || echo site=closed
" 2>/dev/null
docker network rm "\$net" >/dev/null
EOF
)"
[[ "${_probe}" == *"internet=open"* ]] && pass "a pipeline container reaches the internet" || fail "a pipeline container cannot reach the internet (${_probe//$'\n'/ })"
[[ "${_probe}" == *"forge=open"* ]] && pass "a pipeline container reaches Forgejo (${_fhost}:${_fport}) for the clone" || fail "a pipeline container cannot reach ${_fhost}:${_fport}"
if [[ -z "${_fjip}" || "${_probe}" != *"vm-site=open"* ]]; then
    fail "the VM itself cannot reach ${_fj:-the Forgejo VM}:22, so the fence cannot be checked against it"
elif grep -qx 'site=closed' <<<"${_probe}"; then
    pass "a pipeline container is refused by the site's other addresses (${_fj}:22, which the VM reaches)"
else
    fail "a pipeline container reaches the site's network (${_probe//$'\n'/ })"
fi

# 6. Published: through the firewall's Caddy.
PUB="$(remote "jq -r 'select(.proxyPublished != false) | .proxyDomain // empty' /etc/nixos/woodpecker.json")"
FW4="$(getent ahostsv4 firewall.mgmt.internal | awk '{print $1; exit}')"
if [[ -n "${PUB}" && -n "${FW4}" ]]; then
    _c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 --resolve "${PUB}:443:${FW4}" "https://${PUB}/healthz")"
    [[ "${_c}" == "200" ]] && pass "https://${PUB}/healthz answers 200" || fail "https://${PUB}/healthz answers ${_c}"
else
    skipt "not published — checked on the VM only"
fi

echo ""
info "Results: ${PASSED} passed, ${FAILED} failed"
[[ ${FAILED} -eq 0 ]]
