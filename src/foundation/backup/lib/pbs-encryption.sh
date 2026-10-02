#!/usr/bin/env bash
# pbs-encryption.sh — the encryption key of a Proxmox `pbs` storage (#760).
#
# ADR-012 §1.5/§2.5: every backup is client-side encrypted; a PBS holding a copy
# stores ciphertext only. For VM and container backups the client is vzdump, and
# vzdump encrypts only when the STORAGE ENTRY carries a key —
# /etc/pve/priv/storage/<storage>.enc, cluster-wide. The storage was registered
# without one from the start, so every VM/container backup was plaintext; only
# backup:filesystem (its own --keyfile) was encrypted.
#
# pbs_storage_key_ensure gives the storage a key and keeps a copy in the central
# escrow (/etc/secrets/backup-fs, ADR-012 §2.5.1) as pve-storage-<storage>.key,
# so `backup-manager key export` carries it to the out-of-band media with the
# others, and a rebuilt cluster gets the SAME key back (key import, then the
# next update) instead of a new one that cannot read a single old backup.
#
# Sourced by install.sh and update.sh after common-install-routines.sh.

PBS_ENC_ESCROW_DIR="${PBS_ENC_ESCROW_DIR:-/etc/secrets/backup-fs}"

# The escrowed copy of <storage>'s key.
pbs_storage_key_escrow_path() { printf '%s/pve-storage-%s.key\n' "${PBS_ENC_ESCROW_DIR}" "$1"; }

# _pbs_key_action <cluster: key|none> <escrow: none|same|differs> — pure.
#   none     both agree: nothing to do
#   escrow   the cluster has a key the escrow lacks: copy it in
#   rotate   the cluster's key is not the escrowed one: keep the old copy (older
#            backups need it), escrow the new one, and say so
#   restore  no key on the cluster but one in escrow — a rebuilt cluster: put
#            the escrowed key back, never a new one
#   create   neither has one: generate it, escrow it, ask for the out-of-band copy
_pbs_key_action() {
    case "$1/$2" in
        key/same)     echo none ;;
        key/none)     echo escrow ;;
        key/differs)  echo rotate ;;
        none/same|none/differs) echo restore ;;
        none/none)    echo create ;;
        *) return 1 ;;
    esac
}

# Run on the cluster's first mgmt node, as root (where /etc/pve/priv lives).
_pbs_enc_ssh() {
    local zone="$1"; shift
    ssh -n -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@$(get_node_hostname 0).${zone}.internal" "$@"
}

# Write <content> to the escrow file <path>, 0600. The escrow belongs to tappaas
# (tappaas-cicd.nix tmpfiles) and update-tappaas.service writes it WITHOUT sudo
# (NoNewPrivileges) — sudo only for an escrow this user cannot write (an older
# mothership, run by hand). Same rule as pbs_fs_ensure_key.
_pbs_enc_escrow_write() {
    local path="$1" content="$2" s="sudo "
    [[ -d "${PBS_ENC_ESCROW_DIR}" && -w "${PBS_ENC_ESCROW_DIR}" ]] && s=""
    [[ -d "${PBS_ENC_ESCROW_DIR}" ]] || ${s}mkdir -p "${PBS_ENC_ESCROW_DIR}"
    ( umask 077; printf '%s' "${content}" | ${s}tee "${path}" >/dev/null ) && ${s}chmod 600 "${path}"
}
_pbs_enc_escrow_read() {
    local s="sudo "
    [[ -r "$1" ]] && s=""
    ${s}cat "$1" 2>/dev/null
}

# pbs_storage_key_ensure <storage> [zone] — see the header. rc 0 when the storage
# ends with a key that is also escrowed; rc 1 (and nothing half-done that loses a
# key) otherwise.
pbs_storage_key_ensure() {
    local store="$1" zone="${2:-mgmt}" enc esc have escrow action key old
    enc="/etc/pve/priv/storage/${store}.enc"
    esc="$(pbs_storage_key_escrow_path "${store}")"
    _pbs_enc_ssh "${zone}" "pvesm status --storage ${store}" >/dev/null 2>&1 \
        || { warn "  storage ${store} is not registered — no encryption key to ensure"; return 1; }

    key="$(_pbs_enc_ssh "${zone}" "cat ${enc} 2>/dev/null" 2>/dev/null)" || key=""
    old="$(_pbs_enc_escrow_read "${esc}")" || old=""
    have=none; [[ -n "${key}" ]] && have=key
    escrow=none
    if [[ -n "${old}" ]]; then
        escrow=differs
        [[ -n "${key}" && "${key}" == "${old}" ]] && escrow=same
    fi
    action="$(_pbs_key_action "${have}" "${escrow}")"

    case "${action}" in
        none)
            info "  ${GN}✓${CL} backups to ${store} are encrypted; the key is escrowed" ;;
        escrow)
            _pbs_enc_escrow_write "${esc}" "${key}" \
                || { warn "  could not escrow ${store}'s encryption key"; return 1; }
            info "  ${GN}✓${CL} ${store}'s encryption key escrowed → ${esc}"
            warn "  Take the OUT-OF-BAND copy now (ADR-012 §2.5.1): backup-manager key export <dest>" ;;
        rotate)
            # Never overwrite an escrowed key: backups made with it need it.
            _pbs_enc_escrow_write "${esc%.key}.superseded-$(date +%Y%m%d-%H%M%S).key" "${old}" \
                || { warn "  could not keep the superseded key of ${store} — leaving the escrow as it is"; return 1; }
            _pbs_enc_escrow_write "${esc}" "${key}" \
                || { warn "  could not escrow ${store}'s new encryption key"; return 1; }
            warn "  ${store}'s encryption key is NOT the escrowed one — the cluster's key was replaced."
            warn "  Escrowed the new one; the old is kept beside it: backups made before need it."
            warn "  Take a new OUT-OF-BAND copy: backup-manager key export <dest>" ;;
        restore)
            # A rebuilt cluster: the key the existing backups were made with.
            _pbs_enc_ssh "${zone}" "pvesm set ${store} --encryption-key '${old}' >/dev/null" \
                || { warn "  could not put the escrowed key back on ${store}"; return 1; }
            info "  ${GN}✓${CL} ${store}: the escrowed encryption key is back on the cluster — existing backups stay readable" ;;
        create)
            _pbs_enc_ssh "${zone}" "pvesm set ${store} --encryption-key autogen >/dev/null" \
                || { warn "  could not give ${store} an encryption key — backups to it stay UNENCRYPTED"; return 1; }
            key="$(_pbs_enc_ssh "${zone}" "cat ${enc}" 2>/dev/null)" \
                && [[ -n "${key}" ]] \
                || { warn "  ${store} has a new encryption key that could not be read back to escrow it"; return 1; }
            _pbs_enc_escrow_write "${esc}" "${key}" \
                || { warn "  ${store} encrypts now, but its key could not be escrowed — export it by hand: ${enc}"; return 1; }
            info "  ${GN}✓${CL} backups to ${store} are encrypted from now on; key escrowed → ${esc}"
            warn "  Snapshots taken before stay UNENCRYPTED until retention removes them (#760)."
            warn "  The next backup of each guest is a full upload (no dedup against plaintext chunks)."
            warn "  Take the OUT-OF-BAND copy now (ADR-012 §2.5.1): backup-manager key export <dest>" ;;
    esac
    return 0
}
