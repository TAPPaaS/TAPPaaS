#!/usr/bin/env bash
#
# test-update-os-agent.sh — update-os never waits on the operator's agent, and
# its cloud-init wait is bounded.
#
# The deep test of 2026-11-08 stopped for 16 minutes in the zone-node variant's
# OS update: it ran in a session that forwarded a vault-backed agent, and a
# guest login sat asking that agent for its keys until the session closed.
#   1. the real update-os.sh, against a stubbed ssh: no call sees SSH_AUTH_SOCK
#   2. cloud_init_wait against a guest whose `cloud-init status --wait` never
#      returns: back at its ceiling with 124 and a warning, not forever
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
UOS="${CICD}/manager/health-manager/update-os.sh"
PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
[[ -f "${UOS}" ]] || { echo "update-os.sh not found — cannot run here."; exit 77; }
command -v timeout >/dev/null 2>&1 || { echo "no timeout(1) here — cannot run."; exit 77; }

T="$(mktemp -d "${TMPDIR:-/tmp}/uos-agent.XXXXXX")"; trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin" "${T}/config"

# ── 1. the whole script, as a forwarded-agent session runs it ──────────
# ssh records what it was handed and fails, so update-os gives up looking for
# the guest's address (sleep stubbed: its 30 tries take no time) and exits.
cat > "${T}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
echo "${SSH_AUTH_SOCK-unset}" >> "${STUB_LOG}"
exit 255
EOF
printf '#!/bin/sh\nexit 0\n' > "${T}/bin/sleep"
chmod +x "${T}/bin/ssh" "${T}/bin/sleep"
: > "${T}/ssh.log"
PATH="${T}/bin:${PATH}" STUB_LOG="${T}/ssh.log" SSH_AUTH_SOCK="${T}/agent.sock" \
    TAPPAAS_BIN="${CICD}/lib" CONFIG_DIR="${T}/config" HOME="${T}" \
    bash "${UOS}" tvbase-zcnode 8950 tappaas3 >/dev/null 2>&1
ck "update-os ran into the stubbed ssh" "yes" "$([[ -s "${T}/ssh.log" ]] && echo yes || echo no)"
ck "no guest or node login is handed the operator's agent" "" \
   "$(grep -vx unset "${T}/ssh.log" | sort -u)"

# ── 2. a cloud-init that never finishes ─────────────────────────────────
WAIT="$(sed -n '/^cloud_init_wait() {/,/^}/p' "${UOS}")"
ck "cloud_init_wait extracts" "yes" "$([[ -n "${WAIT}" ]] && echo yes || echo no)"
REAL_SLEEP="$(command -v sleep)"   # not /bin/sleep: NixOS has none
cat > "${T}/bin/ssh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${STUB_LOG}"
exec "${REAL_SLEEP}" 60
EOF
: > "${T}/ssh.log"
_t0=$(date +%s)
out="$(PATH="${T}/bin:${PATH}" STUB_LOG="${T}/ssh.log" bash -c '
    warn() { echo "WARN $*"; }
    CLOUD_INIT_MAX_SECONDS=1
    SSH_WAIT_OPTS=(-n -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)
    '"${WAIT}"'
    cloud_init_wait 10.2.98.242; echo "rc=$?"' 2>&1)"
_dt=$(( $(date +%s) - _t0 ))
ck "a cloud-init that never finishes: back with 124" "rc=124" "$(grep -o 'rc=[0-9]*' <<<"${out}")"
ck "  within the ceiling, not forever" "yes" "$([[ ${_dt} -lt 10 ]] && echo yes || echo "no (${_dt}s)")"
ck "  and says so" "1" "$(grep -c 'WARN cloud-init on 10.2.98.242 still not finished' <<<"${out}")"
ck "  the wait's ssh cannot prompt or read the caller's stdin" "1" \
   "$(grep -c -- '^-n -o BatchMode=yes -o ConnectTimeout=10' "${T}/ssh.log")"
ck "both cloud-init waits go through the bounded helper" "2" "$(grep -c 'cloud_init_wait "${ip}"' "${UOS}")"
ck "no unbounded cloud-init wait is left" "0" "$(grep -v '^ *#' "${UOS}" | grep 'ssh [^|]*cloud-init status --wait' | grep -vc 'SSH_WAIT_OPTS')"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
