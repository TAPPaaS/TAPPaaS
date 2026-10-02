#!/usr/bin/env bash
# restore-guest.sh — what kind of guest a backup holds, and what its restore
# cannot bring back. Sourced by scripts/restore.sh; pure, so
# lib/test-restore-guest.sh exercises it without a cluster.
#
# A backup's volid names its guest type: <storage>:backup/vm/<id>/<time> is a
# QEMU VM, …backup/ct/… an LXC container. restore.sh used to treat every backup
# as a VM, so a container (vllm-amd, 312) could not be restored at all (#729).

# restore_guest_type <volid> — "qemu" or "lxc"; rc 1 for anything else.
restore_guest_type() {
    case "$1" in
        *backup/vm/*) printf 'qemu\n' ;;
        *backup/ct/*) printf 'lxc\n' ;;
        *) return 1 ;;
    esac
}

# restore_guest_cli <qemu|lxc> — the node-side command for that type.
restore_guest_cli() {
    [[ "$1" == "lxc" ]] && printf 'pct\n' || printf 'qm\n'
}

# restore_bind_mounts — read `pct config` on stdin, print each mount point that
# is a HOST PATH (mpN: /path,mp=…), one per line. vzdump never includes these,
# so the restored container comes back with the entry but not the data
# (vllm-amd's models: mp0: /tanka1/vllm-models). Storage-backed mount points
# (mpN: tanka1:subvol-…) are in the backup and are not printed.
restore_bind_mounts() {
    awk '/^mp[0-9]+: \// { sub(/^mp[0-9]+: /, ""); sub(/,.*/, ""); print }'
}
