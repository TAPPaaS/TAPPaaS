#!/usr/bin/env bash
#
# ssh-key-only.sh — key-only SSH on a Debian machine (#19, #756).
#
# Runs ON the machine, as root. The mothership feeds it over a key login, so
# nothing has to be copied there first:
#
#     ssh root@<machine> 'bash -s -- apply' < ssh-key-only.sh
#
# One sshd drop-in, the same everywhere TAPPaaS hardens SSH: the cluster nodes
# (cluster/update.sh Step 5, always) and machine modules whose `sshKeyOnly` is
# true — debianhost and the satellite (ADR-026 D8.1):
#
#   PermitRootLogin prohibit-password   root may log in, but only with a key
#   PasswordAuthentication no           no password logins over SSH, any user
#   KbdInteractiveAuthentication no     ...including the keyboard-interactive form
#
# Root login stays enabled (prohibit-password, never "no"): the mothership manages
# these machines as root, and Proxmox nodes log in to each other as root, all of
# it by key. What does not go through sshd keeps its password: the console, and
# on a Proxmox node its web GUI and node Shell.
#
#   apply   write the drop-in when it differs, `sshd -t`, reload, read back
#   remove  delete the drop-in TAPPaaS wrote, `sshd -t`, reload — the machine's own
#           sshd_config decides again. A drop-in TAPPaaS did not write is left alone.
#   check   exit 0 when sshd effectively enforces all three settings, 1 when not
#
# Safety, in order: a configuration `sshd -t` rejects is rolled back before
# anything reloads; a reload never drops open sessions; and the EFFECTIVE values
# are read back with `sshd -T`, so a setting earlier in sshd_config that overrides
# the drop-in (sshd keeps the first value it reads) is reported, not assumed.
# Every caller connects with BatchMode and PasswordAuthentication=no, so this only
# ever runs over a connection that has just authenticated by key.
#
# Exit: 0 done, or already so · 1 refused, failed, or not enforced · 2 usage
#
# Tests: SSH_KEY_ONLY_DROPIN names the drop-in instead of the real path, and
# lifts the root check (scripts/test/test-ssh-key-only.sh).

set -euo pipefail

MODE="${1:-apply}"
DROPIN="${SSH_KEY_ONLY_DROPIN:-/etc/ssh/sshd_config.d/10-tappaas-hardening.conf}"
MARK="# Managed by TAPPaaS"
WANT="${MARK} (tappaas-cicd/scripts/ssh-key-only.sh, #19 #756) — do not edit.
# Key-only SSH: no password logins over SSH for any user. The console keeps the
# root password. To return this machine to its own sshd_config:
#   module-manager module modify <instance> --set sshKeyOnly=false
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no"

case "${MODE}" in apply|remove|check) ;; *) echo "usage: ssh-key-only.sh apply|remove|check" >&2; exit 2 ;; esac
if [[ ${EUID} -ne 0 && -z "${SSH_KEY_ONLY_DROPIN:-}" ]]; then
    echo "ssh-key-only.sh must run as root" >&2
    exit 1
fi

reload_sshd() { systemctl reload ssh 2>/dev/null || systemctl reload sshd; }

# effective <key> — what sshd will enforce. sshd -T prints prohibit-password
# under its older name, without-password.
EFF=""
effective() { awk -v k="$1" '$1 == k { print $2; exit }' <<< "${EFF}"; }

# enforced — 0 when all three are in force; names each one that is not.
enforced() {
    EFF="$(sshd -T 2>/dev/null)" || { echo "sshd -T failed — cannot read what sshd enforces" >&2; return 1; }
    local bad=0 key want got
    for pair in permitrootlogin:without-password passwordauthentication:no kbdinteractiveauthentication:no; do
        key="${pair%%:*}"; want="${pair#*:}"; got="$(effective "${key}")"
        if [[ "${got}" != "${want}" ]]; then
            echo "sshd effective ${key} is '${got:-unset}', expected '${want}'" >&2
            bad=1
        fi
    done
    return "${bad}"
}

# swap_in <new-content|""> — put the drop-in in its new state ("" = absent),
# validate, and roll back on rejection. Prints nothing on success.
swap_in() {
    local new="$1" backup=""
    if [[ -f "${DROPIN}" ]]; then backup="$(mktemp)"; cp -p "${DROPIN}" "${backup}"; fi
    if [[ -n "${new}" ]]; then
        mkdir -p "$(dirname "${DROPIN}")"
        printf '%s\n' "${new}" > "${DROPIN}.tmp"
        chmod 644 "${DROPIN}.tmp"
        mv "${DROPIN}.tmp" "${DROPIN}"
    else
        rm -f "${DROPIN}"
    fi
    local why
    if ! why="$(sshd -t 2>&1)"; then
        echo "sshd -t rejected the configuration — restoring the previous state:" >&2
        printf '%s\n' "${why}" >&2
        if [[ -n "${backup}" ]]; then mv "${backup}" "${DROPIN}"; else rm -f "${DROPIN}"; fi
        return 1
    fi
    rm -f "${backup:-/nonexistent}"
}

case "${MODE}" in
    apply)
        if [[ -f "${DROPIN}" ]] && [[ "$(cat "${DROPIN}")" == "${WANT}" ]]; then
            changed=0
        else
            swap_in "${WANT}" || exit 1
            reload_sshd
            changed=1
        fi
        if ! enforced; then
            echo "something in the sshd configuration overrides ${DROPIN}" >&2
            exit 1
        fi
        [[ "${changed}" -eq 1 ]] && echo "sshd: key-only drop-in written and sshd reloaded" || echo "sshd: already key-only"
        ;;
    remove)
        if [[ ! -f "${DROPIN}" ]]; then
            echo "sshd: no TAPPaaS drop-in — the machine's own sshd_config decides"
            exit 0
        fi
        if [[ "$(head -1 "${DROPIN}")" != "${MARK}"* ]]; then
            echo "sshd: ${DROPIN} was not written by TAPPaaS — leaving it alone" >&2
            exit 1
        fi
        swap_in "" || exit 1
        reload_sshd
        EFF="$(sshd -T 2>/dev/null || true)"
        echo "sshd: TAPPaaS drop-in removed; password authentication is now '$(effective passwordauthentication)' (the machine's own setting)"
        ;;
    check)
        if enforced; then echo "sshd: key-only"; else exit 1; fi
        ;;
esac
exit 0
