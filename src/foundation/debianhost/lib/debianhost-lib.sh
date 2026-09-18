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
