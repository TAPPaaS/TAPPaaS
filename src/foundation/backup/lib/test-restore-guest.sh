#!/usr/bin/env bash
#
# test-restore-guest.sh — restore.sh restores containers as well as VMs (#729).
#
# vllm-amd (312) is an LXC; its backup is …backup/ct/312/…. restore.sh created
# every backup as a QEMU VM, so the one container on the reference site could
# not be restored. The helpers are pure and tested directly; the wiring in
# restore.sh is checked by shape, since running it needs a cluster.
#
# Usage: ./test-restore-guest.sh   (exit 0 = all passed)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESTORE_SH="${SCRIPT_DIR}/../scripts/restore.sh"
# shellcheck source=restore-guest.sh disable=SC1091
. "${SCRIPT_DIR}/restore-guest.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }
has() { grep -qE -- "$1" "${RESTORE_SH}" && echo yes || echo no; }

echo "── the volid says which kind of guest ──"
ck "a VM backup"                  qemu "$(restore_guest_type tappaas_backup:backup/vm/311/2026-10-01T19:01:08Z)"
ck "a container backup"           lxc  "$(restore_guest_type tappaas_backup:backup/ct/312/2026-10-01T19:02:33Z)"
ck "a storage-relative path"      lxc  "$(restore_guest_type backup/ct/312/2026-10-01T19:02:33Z)"
restore_guest_type "vm/311/2026-10-01T19:01:08Z" >/dev/null; rc=$?
ck "anything else is refused, not guessed" 1 "${rc}"
ck "a VM is driven with qm"       qm  "$(restore_guest_cli qemu)"
ck "a container with pct"         pct "$(restore_guest_cli lxc)"

echo "── host bind mounts are named, storage mount points are not ──"
cfg='arch: amd64
mp0: /tanka1/vllm-models,mp=/opt/vllm/models
mp1: tanka1:subvol-312-disk-1,mp=/data,size=8G
mp2: /srv/shared,mp=/shared,ro=1
rootfs: tanka1:subvol-312-disk-0,size=32G'
ck "only the host paths"          "/tanka1/vllm-models /srv/shared" "$(restore_bind_mounts <<<"${cfg}" | tr '\n' ' ' | sed 's/ $//')"
ck "a config without any"         "" "$(printf 'rootfs: tanka1:subvol-1-disk-0,size=8G\n' | restore_bind_mounts)"

echo "── restore.sh is wired to it ──"
ck "it sources the helpers"                       yes "$(has 'lib/restore-guest\.sh')"
ck "a container is created from the backup"       yes "$(has 'nodes/\$\{TARGET_NODE\}/lxc --vmid \$\{RESTORE_VMID\} --ostemplate \$\{VOLID\} --restore 1')"
ck "a container restore needs a storage"          yes "$(has 'is a container: give its storage with --storage')"
ck "a taken VMID is checked as VM and container"  yes "$(has 'pct status \$\{RESTORE_VMID\}')"
ck "one kind is never replaced by the other"      yes "$(has 'refusing to replace one kind with the other')"
ck "HA stops a container as lxc"                  yes "$(has 'echo lxc \|\| echo vm')"
ck "destroy, verify and start use the guest's CLI" "yes yes yes" \
   "$(has '\$\{CLI\} destroy \$\{RESTORE_VMID\} --purge') $(has '\$\{CLI\} config \$\{RESTORE_VMID\}') $(has '\$\{CLI\} start \$\{RESTORE_VMID\}')"
ck "no step still assumes a VM"                   "" \
   "$(grep -nE '"qm (stop|destroy|config|start|unlock) ' "${RESTORE_SH}" | grep -v '^\s*#')"
ck "bind mounts are reported after a container restore" yes "$(has 'restore_bind_mounts')"
ck "a copy beside its original never starts on boot" yes "$(has '\$\{CLI\} set \$\{RESTORE_VMID\} --onboot 0')"

echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
