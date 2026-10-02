#!/usr/bin/env bash
# debianhost-lib.sh — what every debianhost script needs: the instance's config,
# and a root shell on the machine by the mothership's key (ADR-026 D8.1).
# Sourced after common-install-routines.sh. dh_load sets INSTANCE and ADDRESS.

# dh_load <instance> — load config/<instance>.json; the machine is reached by
# its `address`, never by a name derived from the instance.
dh_load() {
    INSTANCE="${1:?usage: <instance>}"
    check_json "${CONFIG_DIR:-/home/tappaas/config}/${INSTANCE}.json" || exit 1
    ADDRESS="$(get_config_value 'address' '')"
    [[ -n "${ADDRESS}" ]] || {
        error "${INSTANCE}: no 'address' in its config — a machine is reached by its address (ADR-026 D8.1)"
        exit 1
    }
}

# dh_ssh <command...> — run as root on the machine: key only, never a password,
# never a prompt. The one way every debianhost script touches the machine.
dh_ssh() {
    ssh -n -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
        -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o LogLevel=ERROR \
        "root@${ADDRESS}" "$@"
}

# dh_reachable — rc 0 when a root login by key works right now.
dh_reachable() { dh_ssh true >/dev/null 2>&1; }

# dh_os_id — the machine's /etc/os-release ID (debian, ubuntu, …).
dh_os_id() { dh_ssh '. /etc/os-release && printf "%s" "${ID:-}"' 2>/dev/null; }

# ── key-only SSH (#756, ADR-026 D8.1 as amended 2026-10-02) ──────────────────
# `sshKeyOnly` is true unless the config says false: a machine TAPPaaS manages
# refuses password logins over SSH, as the cluster nodes do (#19). The console
# keeps the root password. `--set sshKeyOnly=false` returns the machine to its
# own sshd_config. The same script hardens the nodes (cluster/update.sh).
DH_KEY_ONLY_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../tappaas-cicd/scripts" 2>/dev/null && pwd)/ssh-key-only.sh"

# dh_key_only_wanted — rc 0 when the config asks for key-only SSH.
dh_key_only_wanted() { [[ "$(get_config_value 'sshKeyOnly' 'true')" != "false" ]]; }

# dh_key_only <apply|remove|check> — run ssh-key-only.sh on the machine, over the
# key login dh_ssh uses (so only ever over a connection that just authenticated
# by key). Its output is passed through; rc is the script's.
dh_key_only() {
    [[ -f "${DH_KEY_ONLY_SCRIPT}" ]] || { error "ssh-key-only.sh not found at ${DH_KEY_ONLY_SCRIPT}"; return 1; }
    ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
        -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o LogLevel=ERROR \
        "root@${ADDRESS}" "bash -s -- $1" < "${DH_KEY_ONLY_SCRIPT}"
}

# dh_key_only_converge — make sshd match the field: apply when wanted, remove
# the TAPPaaS drop-in when not. Fails loudly: a declared state that cannot be
# reached is a failed update, not a warning.
dh_key_only_converge() {
    local out
    if dh_key_only_wanted; then
        out="$(dh_key_only apply 2>&1)" || { printf '%s\n' "${out}" >&2; error "${INSTANCE}: key-only SSH could not be enforced (sshKeyOnly is true)"; return 1; }
        info "  ${GN}✓${CL} key-only SSH (${out##*$'\n'})"
    else
        out="$(dh_key_only remove 2>&1)" || { printf '%s\n' "${out}" >&2; error "${INSTANCE}: the TAPPaaS sshd drop-in could not be removed (sshKeyOnly is false)"; return 1; }
        info "  sshKeyOnly is false — ${out##*$'\n'}"
    fi
}
