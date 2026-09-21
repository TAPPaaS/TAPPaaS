#!/usr/bin/env bash
#
# A Proxmox lock is a wait, then a defer — never a failure (#686).
#
# A backup holds `lock: backup` on a guest for as long as it runs, and every qm
# write is refused while it is there. On 2026-09-20 that cost two modules their
# update: the snapshot failed, the update proceeded WITHOUT a rollback point,
# and a post-rebuild `qm reboot` hitting the same lock reported both modules as
# FAILED — while both had in fact rebuilt correctly.
#
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LIB="${HERE}/../../lib/common-install-routines.sh"
pass=0; fail=0
ok()  { echo "  ✓ $*"; pass=$((pass+1)); }
bad() { echo "  ✗ $*"; fail=$((fail+1)); }

W="$(mktemp -d)"; trap 'rm -rf "${W}"' EXIT
mkdir -p "${W}/bin"
# `ssh` answers as the node would: the lock file says what qm config reports.
cat > "${W}/bin/ssh" <<'STUB'
#!/usr/bin/env bash
# The helper runs `qm config | sed -n 's/^lock: //p'` ON the node, so what comes
# back over ssh is the bare lock name.
if [[ -s "${LOCKFILE}" ]]; then cat "${LOCKFILE}"; echo; fi
# each call consumes one "tick" so a test can let the lock clear
if [[ -n "${TICKFILE:-}" ]]; then
    n=$(( $(cat "${TICKFILE}" 2>/dev/null || echo 0) + 1 )); echo "$n" > "${TICKFILE}"
    [[ "$n" -ge "${CLEAR_AFTER:-999}" ]] && : > "${LOCKFILE}"
fi
exit 0
STUB
chmod +x "${W}/bin/ssh"
export PATH="${W}/bin:${PATH}" LOCKFILE="${W}/lock" MGMT=mgmt
info(){ :; }; warn(){ :; }; error(){ :; }; debug(){ :; }; GN=""; CL=""
# shellcheck disable=SC1090
. "${LIB}" 2>/dev/null || { echo "could not source ${LIB}"; exit 2; }

: > "${LOCKFILE}"
[[ -z "$(vm_lock_holder 101 tappaas1)" ]] && ok "an unlocked guest reports no holder" || bad "phantom lock"

printf 'backup' > "${LOCKFILE}"
[[ "$(vm_lock_holder 101 tappaas1)" == "backup" ]] && ok "the holder is named (backup)" || bad "holder not read"

# It waits, and succeeds when the lock clears.
printf 'backup' > "${LOCKFILE}"; export TICKFILE="${W}/ticks" CLEAR_AFTER=2; : > "${TICKFILE}"
if wait_for_vm_unlock 101 tappaas1 60; then ok "waits, and returns 0 once the backup finishes"
else bad "gave up while the lock was clearing"; fi

# It gives up within the timeout rather than blocking the sweep for ever.
printf 'backup' > "${LOCKFILE}"; unset TICKFILE
_t0=$(date +%s)
wait_for_vm_unlock 101 tappaas1 20 && bad "claimed the guest was free while locked" \
    || ok "a lock that never clears returns 1 (the caller defers)"
_el=$(( $(date +%s) - _t0 ))
[[ "${_el}" -le 40 ]] && ok "…and does so within the timeout (${_el}s)" || bad "overran the timeout (${_el}s)"

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
