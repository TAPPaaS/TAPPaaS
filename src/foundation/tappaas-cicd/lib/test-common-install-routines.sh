#!/usr/bin/env bash
#
# test-common-install-routines.sh — unit tests for the SSH identity helpers
# (lib/common-install-routines.sh: tappaas_operator_home, tappaas_ssh_identity).
#
# Offline — no ssh, no cluster, no node. Pure functions of the process env,
# same 5 cases as the TypeScript sibling this mirrors
# (manager/module-manager/test/unit/cluster.test.ts, testing cluster.ts's
# operatorHome()/sshIdentity()) — kept in lockstep on purpose: the two
# implementations of the same fix (#518/#519/#520/#521) should never drift
# apart silently.
#
# Usage: test-common-install-routines.sh   (prints "Results: N passed, M failed"; exit 1 on fail)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common-install-routines.sh
. "${HERE}/common-install-routines.sh" ""   # "" -> skip this file's own JSON auto-load

pass=0; fail=0
ok(){ pass=$((pass+1)); }
no(){ fail=$((fail+1)); echo "FAIL: $1"; }
check(){ if [ "$2" = "$3" ]; then ok; else no "$1 (got '$2', want '$3')"; fi; }

# Save/restore the env vars these functions read, so the suite is isolated
# and leaves the process env as it found it.
saved_TOH="${TAPPAAS_OPERATOR_HOME:-}"
saved_TSI="${TAPPAAS_SSH_IDENTITY:-}"
saved_SU="${SUDO_USER:-}"
setenv() {
    unset TAPPAAS_OPERATOR_HOME TAPPAAS_SSH_IDENTITY SUDO_USER
    for kv in "$@"; do
        k="${kv%%=*}"; v="${kv#*=}"
        export "${k}=${v}"
    done
}
restore_env() {
    unset TAPPAAS_OPERATOR_HOME TAPPAAS_SSH_IDENTITY SUDO_USER
    [[ -n "${saved_TOH}" ]] && export TAPPAAS_OPERATOR_HOME="${saved_TOH}"
    [[ -n "${saved_TSI}" ]] && export TAPPAAS_SSH_IDENTITY="${saved_TSI}"
    [[ -n "${saved_SU}"  ]] && export SUDO_USER="${saved_SU}"
}
trap restore_env EXIT

# ── tappaas_operator_home() — same 5 cases as operatorHome() ────────────

# 1. not under sudo → empty (inherited HOME already the operator's)
setenv
check "no SUDO_USER / no override -> empty" "$(tappaas_operator_home)" ""

# 2. sudo -n as the operator → their home is restored
setenv "SUDO_USER=tappaas"
check "SUDO_USER=tappaas -> /home/tappaas" "$(tappaas_operator_home)" "/home/tappaas"

# 3. SUDO_USER=root is a no-op (root has no operator identity to restore)
setenv "SUDO_USER=root"
check "SUDO_USER=root -> empty" "$(tappaas_operator_home)" ""

# 4. explicit override wins over SUDO_USER
setenv "SUDO_USER=tappaas" "TAPPAAS_OPERATOR_HOME=/srv/op"
check "TAPPAAS_OPERATOR_HOME overrides SUDO_USER" "$(tappaas_operator_home)" "/srv/op"

# 5. override alone (no sudo) is still honoured
setenv "TAPPAAS_OPERATOR_HOME=/srv/op"
check "TAPPAAS_OPERATOR_HOME honoured without sudo" "$(tappaas_operator_home)" "/srv/op"

# ── tappaas_ssh_identity() — layered on top of tappaas_operator_home() ──

setenv
check "no sudo, no override -> falls back to /home/tappaas" \
    "$(tappaas_ssh_identity)" "/home/tappaas/.ssh/id_ed25519"

setenv "SUDO_USER=erik"
check "different operator resolves dynamically, not hardcoded" \
    "$(tappaas_ssh_identity)" "/home/erik/.ssh/id_ed25519"

setenv "SUDO_USER=tappaas"
check "SUDO_USER=tappaas -> /home/tappaas/.ssh/id_ed25519" \
    "$(tappaas_ssh_identity)" "/home/tappaas/.ssh/id_ed25519"

setenv "TAPPAAS_SSH_IDENTITY=/custom/path/id_rsa"
check "TAPPAAS_SSH_IDENTITY overrides everything" \
    "$(tappaas_ssh_identity)" "/custom/path/id_rsa"

setenv "SUDO_USER=tappaas" "TAPPAAS_SSH_IDENTITY=/custom/path/id_rsa"
check "explicit identity override wins even under sudo" \
    "$(tappaas_ssh_identity)" "/custom/path/id_rsa"

# ── tappaas_ssh() builds the expected flag set ───────────────────────────
# Not a real connection — capture argv via a stub `ssh` earlier on PATH.
setenv "SUDO_USER=tappaas"
STUBDIR="$(mktemp -d "${TMPDIR:-/tmp}/tappaas-ssh-test.XXXXXX")"
trap 'restore_env; rm -rf "${STUBDIR}"' EXIT
cat > "${STUBDIR}/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@"
STUB
chmod +x "${STUBDIR}/ssh"
argv="$(PATH="${STUBDIR}:${PATH}" tappaas_ssh root@node1.mgmt.internal "true")"
check "passes explicit -i" "$(echo "${argv}" | grep -c '^-i$')" "1"
check "passes IdentitiesOnly=yes" "$(echo "${argv}" | grep -c 'IdentitiesOnly=yes')" "1"
check "passes StrictHostKeyChecking=accept-new (never =no)" \
    "$(echo "${argv}" | grep -c 'StrictHostKeyChecking=accept-new')" "1"
check "never passes the weak StrictHostKeyChecking=no" \
    "$(echo "${argv}" | grep -c 'StrictHostKeyChecking=no$')" "0"
check "identity value resolves the operator's key" \
    "$(echo "${argv}" | grep -A1 '^-i$' | tail -1)" "/home/tappaas/.ssh/id_ed25519"
rm -rf "${STUBDIR}"

# ── tappaas_fw_ssh_identity() — prefer tappaas-fw, fall back to operator key ──
FWHOME="$(mktemp -d "${TMPDIR:-/tmp}/tappaas-fw-test.XXXXXX")"
trap 'restore_env; rm -rf "${STUBDIR}" "${FWHOME}"' EXIT
mkdir -p "${FWHOME}/.ssh"

setenv "TAPPAAS_OPERATOR_HOME=${FWHOME}"
check "no tappaas-fw file -> falls back to the operator's own key" \
    "$(tappaas_fw_ssh_identity)" "${FWHOME}/.ssh/id_ed25519"

: > "${FWHOME}/.ssh/tappaas-fw"
check "tappaas-fw present -> preferred over the operator's own key" \
    "$(tappaas_fw_ssh_identity)" "${FWHOME}/.ssh/tappaas-fw"
rm -rf "${FWHOME}"

setenv "TAPPAAS_SSH_IDENTITY=/custom/path/id_rsa"
check "TAPPAAS_SSH_IDENTITY override reaches the fallback path too" \
    "$(tappaas_fw_ssh_identity)" "/custom/path/id_rsa"

# ── tappaas_fw_ssh() builds the same flag set, firewall identity ─────────
setenv "SUDO_USER=tappaas"
STUBDIR="$(mktemp -d "${TMPDIR:-/tmp}/tappaas-fw-ssh-test.XXXXXX")"
trap 'restore_env; rm -rf "${STUBDIR}"' EXIT
cat > "${STUBDIR}/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@"
STUB
chmod +x "${STUBDIR}/ssh"
argv="$(PATH="${STUBDIR}:${PATH}" tappaas_fw_ssh root@firewall.mgmt.internal "true")"
check "fw: passes explicit -i" "$(echo "${argv}" | grep -c '^-i$')" "1"
check "fw: passes IdentitiesOnly=yes" "$(echo "${argv}" | grep -c 'IdentitiesOnly=yes')" "1"
check "fw: no tappaas-fw file -> resolves the operator's key" \
    "$(echo "${argv}" | grep -A1 '^-i$' | tail -1)" "/home/tappaas/.ssh/id_ed25519"
rm -rf "${STUBDIR}"

echo "Results: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
