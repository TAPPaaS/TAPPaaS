#!/usr/bin/env bash
# test-migration-0013-key-only.sh — the fixture test for migration 0013 (#756).
#
# A debianhost adopted before #756 is given sshKeyOnly=false; one that states the
# field, a satellite, a pvehost and a VM module are left alone; --check writes
# nothing; applying twice is a no-op; the backup holds the pre-image; a
# non-boolean sshKeyOnly stops it with every file untouched. Test 9z sweeps this
# directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
M="${CICD}/migrations/0013-adopted-machines-keep-password-ssh.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

[[ -f "${M}" ]] || { echo "  ✗ ${M} not found"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mig0013.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
CFG="${TMP}/config"

fixtures() {
    rm -rf "${CFG}"; mkdir -p "${CFG}"
    echo '{"kind":"machine","moduleSource":"/home/tappaas/TAPPaaS/src/foundation/debianhost","address":"10.0.0.50","rebootOk":false}' > "${CFG}/dh-old.json"
    echo '{"kind":"machine","location":"/home/tappaas/TAPPaaS/src/foundation/debianhost/","address":"10.0.0.51"}' > "${CFG}/dh-legacy.json"
    echo '{"kind":"machine","moduleSource":"/home/tappaas/TAPPaaS/src/foundation/debianhost","sshKeyOnly":true}' > "${CFG}/dh-new.json"
    echo '{"kind":"machine","moduleSource":"/home/tappaas/TAPPaaS/src/foundation/satellite","name":"vault"}' > "${CFG}/satellite-vault.json"
    echo '{"kind":"machine","moduleSource":"/home/tappaas/TAPPaaS/src/foundation/pvehost"}' > "${CFG}/tappaas1.json"
    echo '{"kind":"vm","moduleSource":"/home/tappaas/TAPPaaS/src/apps/debianhost-tools","vmid":300}' > "${CFG}/lookalike.json"
    echo '["not", "a", "module"]' > "${CFG}/zones-like.json"
}
run() { CONFIG_DIR="${CFG}" TAPPAAS_MIGRATION_BACKUP_DIR="${CFG}/.migrations/backup/0013" bash "${M}" "$@" 2>&1; }
key() { jq -c 'if has("sshKeyOnly") then .sshKeyOnly else "absent" end' "${CFG}/$1.json"; }

fixtures
out="$(run --check)"; rc=$?
ck "--check succeeds"                                 0 "${rc}"
ck "--check writes nothing"                           '"absent"' "$(key dh-old)"
ck "…and names what it would change"                  yes "$([[ "${out}" == *"would set sshKeyOnly=false on dh-old"* ]] && echo yes || echo no)"

out="$(run)"; rc=$?
ck "the run succeeds"                                 0 "${rc}"
ck "a debianhost without the field → false"           false "$(key dh-old)"
ck "…found by the pre-0006 location too"              false "$(key dh-legacy)"
ck "…and says how to opt in"                          yes "$([[ "${out}" == *"--set sshKeyOnly=true"* ]] && echo yes || echo no)"
ck "a debianhost that states it is left alone"        true "$(key dh-new)"
ck "a satellite takes the new default (untouched)"    '"absent"' "$(key satellite-vault)"
ck "a pvehost is untouched"                           '"absent"' "$(key tappaas1)"
ck "a module merely named like it is untouched"       '"absent"' "$(key lookalike)"
ck "other fields are kept"                            '{"kind":"machine","moduleSource":"/home/tappaas/TAPPaaS/src/foundation/debianhost","address":"10.0.0.50","rebootOk":false,"sshKeyOnly":false}' "$(jq -c . "${CFG}/dh-old.json")"
ck "the pre-image is backed up"                       '"absent"' "$(jq -c 'if has("sshKeyOnly") then .sshKeyOnly else "absent" end' "${CFG}/.migrations/backup/0013/dh-old.json")"
ck "a file it did not change is not backed up"        no "$([[ -f "${CFG}/.migrations/backup/0013/dh-new.json" ]] && echo yes || echo no)"
before="$(cat "${CFG}"/*.json)"; out="$(run)"
ck "a second run changes nothing"                     "${before}" "$(cat "${CFG}"/*.json)"
ck "…and says there is nothing to do"                 yes "$([[ "${out}" == *"nothing to migrate"* ]] && echo yes || echo no)"

fixtures
echo '{"kind":"machine","moduleSource":"/x/debianhost","sshKeyOnly":"false"}' > "${CFG}/dh-odd.json"
out="$(run)"; rc=$?
ck "a non-boolean sshKeyOnly stops the run"           1 "${rc}"
ck "…naming the file"                                 yes "$([[ "${out}" == *"dh-odd.json"* ]] && echo yes || echo no)"
ck "…and nothing was written"                         '"absent"' "$(key dh-old)"

fixtures
echo '{"moduleSource": "/x/debianhost", ' > "${CFG}/dh-broken.json"
out="$(run)"; rc=$?
ck "a debianhost file that is not JSON stops the run" 1 "${rc}"
ck "…and nothing was written"                         '"absent"' "$(key dh-old)"

rm -rf "${CFG}"; mkdir -p "${CFG}"
out="$(run)"; rc=$?
ck "no debianhost at all: nothing to do"              0 "${rc}"

echo
echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
