#!/usr/bin/env bash
# 0013-adopted-machines-keep-password-ssh.sh — a debianhost adopted before #756 gets sshKeyOnly: false
#
# Introduced: 2.2.  Required by: #756 (ADR-026 D8.1, amended 2026-10-02).
# Touches: config/<instance>.json of every debianhost instance (only).
# Reversible: yes — restore config/.migrations/backup/0013/<file>.
#
# WHY. From #756 a machine TAPPaaS manages is key-only over SSH unless its
# config says `sshKeyOnly: false`, and a field that is absent means true. A
# debianhost adopted before that was promised the opposite — "adopt changes
# nothing about how the machine is reached" (ADR-026 D8.1 as it then stood) —
# and someone may reach it by password today. Without this migration its next
# nightly update would make it key-only. So every debianhost config that does
# not state the field yet gets `sshKeyOnly: false`: it keeps what it was
# promised, and the operator opts in with
#     module-manager module modify <instance> --set sshKeyOnly=true
#
# A debianhost is a config whose module source (`moduleSource`, or `location`
# before 0006) is the debianhost module's directory. The satellite is not one —
# TAPPaaS built it from keys, so it takes the new default (#756) — nor is a
# pvehost, whose SSH the cluster has always made key-only (#19).
#
# WHAT IT REFUSES, rather than guessing (ADR-025 D3): a debianhost config whose
# sshKeyOnly is there but not a boolean, and a config file that is not JSON.
#
# Usage: 0013-adopted-machines-keep-password-ssh.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a shape it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0013}"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

# The update sweep's log levels (common-install-routines.sh), inlined: a
# migration is self-contained. `note` is detail, shown under TAPPAAS_DEBUG=1.
say()  { echo -e "\033[32m[Info]\033[m   0013: $*"; }
note() { [[ "${TAPPAAS_DEBUG:-0}" == "1" ]] || return 0; echo -e "\033[36m[Debug]\033[m   0013: $*"; }
stop() { echo -e "\033[01;31m[Error]\033[m 0013: $*" >&2; exit 1; }

# A debianhost config: an object whose module source is .../debianhost.
IS_DH='type == "object" and ((.moduleSource // .location) | type == "string")
       and ((.moduleSource // .location) | sub("/+$"; "") | test("(^|/)debianhost$"))'

todo=()
for f in "${CONFIG_DIR}"/*.json; do
    [[ -f "${f}" ]] || continue
    if ! jq empty "${f}" 2>/dev/null; then
        # Only a debianhost's own file is ours to judge; say which one is unreadable.
        grep -q 'debianhost' "${f}" 2>/dev/null && stop "${f} is not valid JSON — refusing to guess whether it is a debianhost"
        continue
    fi
    jq -e "${IS_DH}" "${f}" >/dev/null 2>&1 || continue
    case "$(jq -r 'if has("sshKeyOnly") then (.sshKeyOnly | type) else "absent" end' "${f}")" in
        absent)  todo+=("${f}") ;;
        boolean) note "$(basename "${f}" .json) already states sshKeyOnly=$(jq -r .sshKeyOnly "${f}")" ;;
        *)       stop "$(basename "${f}"): sshKeyOnly is $(jq -c .sshKeyOnly "${f}"), not true or false — a person should look at this" ;;
    esac
done

if [[ ${#todo[@]} -eq 0 ]]; then
    say "no debianhost without sshKeyOnly — nothing to migrate"
    exit 0
fi

if [[ "${CHECK}" -eq 1 ]]; then
    for f in "${todo[@]}"; do say "would set sshKeyOnly=false on $(basename "${f}" .json) (adopted before #756: password SSH stays as it is)"; done
    exit 0
fi

# Back up before the first write — that copy IS the rollback (ADR-025 D8).
mkdir -p "${BACKUP_DIR}" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
for f in "${todo[@]}"; do
    cp -p "${f}" "${BACKUP_DIR}/$(basename "${f}")" || stop "cannot back up ${f} — refusing to write"
done

for f in "${todo[@]}"; do
    tmp="${f}.0013.tmp"
    jq '.sshKeyOnly = false' "${f}" > "${tmp}" || { rm -f "${tmp}"; stop "rewrite failed — $(basename "${f}") is unchanged"; }
    jq empty "${tmp}" 2>/dev/null || { rm -f "${tmp}"; stop "the rewritten $(basename "${f}") is not valid JSON — it is unchanged"; }
    chmod --reference="${BACKUP_DIR}/$(basename "${f}")" "${tmp}" 2>/dev/null || true
    mv -f "${tmp}" "${f}"
    say "$(basename "${f}" .json): sshKeyOnly=false — adopted before #756, it keeps password SSH; to harden it: module-manager module modify $(basename "${f}" .json) --set sshKeyOnly=true"
done
note "backup: ${BACKUP_DIR}"
