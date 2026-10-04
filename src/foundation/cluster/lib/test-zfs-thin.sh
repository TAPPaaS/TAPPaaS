#!/usr/bin/env bash
#
# Unit tests for zfs-thin.sh — the node-side volume loop behind cluster:vm
# thinDisk (#773). Runs the node script locally against stub qm/pvesm/zfs, so
# it needs no Proxmox: which disks count (zvols, not ISOs or the cloud-init
# drive), what `report` says, and what `thin`/`thick` set.
#
# Usage: ./test-zfs-thin.sh
# Exit: 0 all passed, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=zfs-thin.sh disable=SC1091
. "${SCRIPT_DIR}/zfs-thin.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; PASS=$((PASS + 1)); else echo "  ✗ $1 (expected '$2', got '$3')"; FAIL=$((FAIL + 1)); fi; }

T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin" "${T}/refres"

# qm config: an OS zvol, an EFI zvol, the cloud-init zvol, an ISO, and a disk on
# a directory storage. Only the first two are thin-provisioning candidates.
cat > "${T}/qm.conf" <<'EOF'
boot: order=scsi0
efidisk0: tanka1:vm-361-disk-0,efitype=4m,size=1M
ide2: local:iso/nixos.iso,media=cdrom,size=1G
scsi0: tanka1:vm-361-disk-1,size=500G
scsi1: tanka1:vm-361-cloudinit,media=cdrom,size=4M
scsi3: localdir:361/vm-361-disk-2.qcow2,size=8G
EOF
cat > "${T}/bin/qm" <<EOF
#!/usr/bin/env bash
cat "${T}/qm.conf"
EOF
cat > "${T}/bin/pvesm" <<'EOF'
#!/usr/bin/env bash
case "$2" in
    tanka1:*) echo "/dev/zvol/tanka1/${2#tanka1:}" ;;
    local:*)  echo "/var/lib/vz/template/${2#local:}" ;;
    *)        echo "/var/lib/vz/images/${2#*:}" ;;
esac
EOF
# zfs: refreservation per volume kept as a file, so set/get round-trip.
cat > "${T}/bin/zfs" <<EOF
#!/usr/bin/env bash
f="${T}/refres/\$(echo "\${@: -1}" | tr / _)"
case "\$1" in
    get) cat "\${f}" 2>/dev/null || echo 513G ;;
    set) echo "\${2#refreservation=}" > "\${f}" ;;
esac
EOF
chmod +x "${T}/bin/"*
run() { zfs_thin_node_script | PATH="${T}/bin:${PATH}" bash -s -- 361 "$1"; }
refres() { cat "${T}/refres/$(echo "$1" | tr / _)" 2>/dev/null || echo unset; }

echo "zfs-thin (#773)"
ck "a thick guest reports false"                     "false" "$(run report)"
ck "thin touches the zvols only, not the ISO, the cloud-init drive or a non-ZFS disk" \
    "tanka1/vm-361-disk-0 tanka1/vm-361-disk-1" "$(run thin | tr '\n' ' ' | sed 's/ $//')"
ck "…and sets refreservation=none on them"           "none none unset" \
    "$(refres tanka1/vm-361-disk-0) $(refres tanka1/vm-361-disk-1) $(refres tanka1/vm-361-cloudinit)"
ck "a thin guest reports true"                       "true" "$(run report)"
echo auto > "${T}/refres/tanka1_vm-361-disk-0"
ck "one thick zvol makes the guest report false"     "false" "$(run report)"
run thick >/dev/null
ck "thick sets refreservation=auto"                  "auto auto" \
    "$(refres tanka1/vm-361-disk-0) $(refres tanka1/vm-361-disk-1)"
printf 'scsi0: localdir:361/vm-361-disk-2.qcow2,size=8G\n' > "${T}/qm.conf"
ck "a guest with no zvol reports nothing (not observable)" "" "$(run report)"
ck "…and thin changes nothing"                       "" "$(run thin)"
rc=0; run bogus >/dev/null 2>&1 || rc=$?
ck "with no zvol the action is never reached (exit 0)" "0" "${rc}"

printf 'scsi0: tanka1:vm-361-disk-1,size=500G\n' > "${T}/qm.conf"
rc=0; run bogus >/dev/null 2>&1 || rc=$?
ck "an unknown action fails when there is a zvol"    "2" "${rc}"

echo "── summary: ${PASS} pass, ${FAIL} fail ──"
[[ "${FAIL}" -eq 0 ]]
