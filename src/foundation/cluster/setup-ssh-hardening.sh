#!/usr/bin/env bash
#
# TAPPaaS: key-only SSH on a Proxmox node (issue #19)
#
# Runs on a Proxmox node. Idempotent. Writes one sshd drop-in:
#
#   PermitRootLogin prohibit-password   root may log in, but only with a key
#   PasswordAuthentication no           no password logins over SSH, any user
#   KbdInteractiveAuthentication no     ...including the keyboard-interactive form
#
# Why root login stays ENABLED (prohibit-password, never "no"): Proxmox itself
# logs in as root over SSH between nodes — the GUI Shell for another node and
# migrations go through PVE::SSHInfo::ssh_info_to_command — and the mothership
# manages the nodes as root. All of that uses keys.
#
# What still works without a password over SSH, because none of it is sshd:
# the PVE web GUI login (root@pam, PAM), its node Shell (/bin/login -f root),
# the physical/IPMI console (getty → login), and every VM console in the GUI.
#
# Safety, in order:
#   1. the new drop-in is validated with `sshd -t` BEFORE sshd is reloaded;
#      an invalid result restores the previous state and exits non-zero;
#   2. a reload never drops open sessions;
#   3. the EFFECTIVE values are then read back with `sshd -T`, so a
#      sshd_config whose own settings override the drop-in (sshd keeps the
#      first value it reads) is reported rather than assumed.
#
# Only ever run over a key-authenticated connection: cluster/update.sh checks
# that before calling this. Not called by the node installer, which runs
# before the mothership's key is on the node.
#
# Usage: ./setup-ssh-hardening.sh
#

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "setup-ssh-hardening.sh must run as root" >&2
    exit 1
fi

DROPIN="/etc/ssh/sshd_config.d/10-tappaas-hardening.conf"
WANT="# Managed by TAPPaaS (cluster/setup-ssh-hardening.sh, issue #19) — do not edit.
# Key-only SSH. The PVE web GUI, its node Shell and the physical console do not
# use sshd and keep working with the root password.
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no"

mkdir -p "$(dirname "${DROPIN}")"

if [[ -f "${DROPIN}" ]] && [[ "$(cat "${DROPIN}")" == "${WANT}" ]]; then
    changed=0
else
    backup=""
    if [[ -f "${DROPIN}" ]]; then
        backup="$(mktemp)"
        cp -p "${DROPIN}" "${backup}"
    fi
    printf '%s\n' "${WANT}" > "${DROPIN}.tmp"
    chmod 644 "${DROPIN}.tmp"
    mv "${DROPIN}.tmp" "${DROPIN}"
    if ! sshd -t 2>/tmp/sshd-t.$$; then
        echo "sshd -t rejected the configuration — restoring the previous state:" >&2
        cat /tmp/sshd-t.$$ >&2
        if [[ -n "${backup}" ]]; then mv "${backup}" "${DROPIN}"; else rm -f "${DROPIN}"; fi
        rm -f /tmp/sshd-t.$$
        exit 1
    fi
    rm -f /tmp/sshd-t.$$ "${backup:-/nonexistent}"
    changed=1
fi

if [[ "${changed}" -eq 1 ]]; then
    systemctl reload ssh
    echo "sshd: key-only drop-in written and sshd reloaded"
fi

# Read back what sshd will actually enforce. sshd -T prints prohibit-password
# under its older name, without-password.
eff="$(sshd -T 2>/dev/null)"
bad=0
check() {
    local key="$1" want="$2" got
    got="$(awk -v k="${key}" '$1 == k { print $2; exit }' <<< "${eff}")"
    if [[ "${got}" != "${want}" ]]; then
        echo "sshd effective ${key} is '${got:-unset}', expected '${want}' — something in /etc/ssh/sshd_config overrides ${DROPIN}" >&2
        bad=1
    fi
}
check permitrootlogin without-password
check passwordauthentication no
check kbdinteractiveauthentication no
[[ "${bad}" -eq 0 ]] || exit 1

[[ "${changed}" -eq 0 ]] && echo "sshd: already key-only"
exit 0
