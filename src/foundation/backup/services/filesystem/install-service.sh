#!/usr/bin/env bash
#
# backup:filesystem — install-service (ADR-012 §3.1, D17).
#
# Provisions the PBS side of a module's FILE-level backup and deploys the
# guest-side runner:
#
#   1. gate on the guest OS (only where TAPPaaS knows the layout — NixOS today)
#   2. namespace fs/<module> + a login scoped to it that can write, not delete
#   3. a client-side encryption key, held by the guest and ESCROWED centrally
#      (§2.5.1 — a key that only exists on the guest is useless in the restore
#      that matters, the one where the guest is gone)
#   4. the capture manifest + the runner, on the guest
#
# Idempotent: re-running re-asserts every step and changes nothing that is
# already right.
#
# Usage: install-service.sh <module-name>
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../../lib/pbs-job.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-job.sh"
# shellcheck source=../../lib/pbs-namespace.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-namespace.sh"
# shellcheck source=../../lib/pbs-placement.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-placement.sh"
# shellcheck source=../../lib/pbs-fs.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/pbs-fs.sh"

MODULE="${1:-}"
[[ -n "${MODULE}" ]] || { echo "Usage: $0 <module-name>"; exit 1; }

CONFIG="${CONFIG_DIR:-/home/tappaas/config}/${MODULE}.json"
check_json "${CONFIG}" || exit 1

# A shim realizes no datastore, so there is nowhere to capture TO. Degrade
# exactly as backup:vm does: the dependent installs, and the capture starts
# working once backup is promoted.
if pbs_is_shim; then
    warn "backup:filesystem: backup is a shim (no PBS datastore) — skipping file capture for ${MODULE}."
    warn "  It will be captured once backup is promoted: update-module.sh backup"
    exit 0
fi

KIND="$(pbs_fs_kind "${MODULE}")"
VMNAME="$(jq -r '.vmname // empty' "${CONFIG}")"
ZONE="$(jq -r '.zone0 // "mgmt"' "${CONFIG}")"
OSTYPE_DECLARED="$(jq -r '.os // .ostype // "nixos"' "${CONFIG}")"
# Where the files are, and who we are when we get there: a guest by vmname, a
# machine by address as root (#662). Both resolve through one helper so the
# three service scripts cannot disagree about it.
TARGET="$(pbs_fs_target "${MODULE}")" \
    || { warn "backup:filesystem: ${MODULE} says neither a vmname nor an address — nothing to capture"; exit 0; }
SUDO="$(pbs_fs_sudo "${MODULE}")"
OWNER="tappaas:users"; [[ "${KIND}" == "machine" ]] && OWNER="root:root"

# 1. Guest OS gate — fail loudly rather than capture something half-right.
if ! pbs_fs_os_supported "${OSTYPE_DECLARED}" "${KIND}"; then
    die "backup:filesystem is only supported on guest OS types TAPPaaS knows the layout of (NixOS); '${MODULE}' declares '${OSTYPE_DECLARED}'. Use backup:vm for a whole-guest snapshot instead."
fi

mapfile -t FS_PATHS < <(pbs_fs_paths "${MODULE}")
if [[ "${#FS_PATHS[@]}" -eq 0 ]]; then
    die "backup:filesystem: ${MODULE} declares the capability but no backup.filesystemPaths — nothing would be captured"
fi

GUEST="${TARGET#*@}"
NS="$(pbs_fs_namespace "${MODULE}")"
AUTHID="$(pbs_fs_authid "${MODULE}")"
REPO="${AUTHID}@$(pbs_pbs_url):$(pbs_storage_name)"

debug "backup:filesystem: provisioning file capture for ${MODULE} (${#FS_PATHS[@]} path(s))"

# 2. Namespace + write-no-delete login. The password is generated, handed to the
#    guest and escrowed centrally — never echoed, never stored in config.
# The escrow directory is PBS_FS_ESCROW_DIR in pbs-fs.sh (shared with update).
# Bounded input, then slice — do NOT pipe /dev/urandom into `head`: head exits
# after 32 bytes, tr dies of SIGPIPE, and under `pipefail` the substitution
# returns non-zero, so `set -e` kills the script one line after generating a
# perfectly good password.
FS_PW="$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
FS_PW="${FS_PW:0:32}"
[[ "${#FS_PW}" -ge 8 ]] || die "could not generate a PBS password"
pbs_fs_ensure_target "${MODULE}" "${FS_PW}" || die "could not provision the PBS side for ${MODULE}"

# A password that PBS did not store is worse than no password: the capture
# fails with "permission check failed", which reads like a missing privilege
# and is not one (#662). So the generated password is only deployed when this
# run created the login. If the login already existed, the target keeps the
# password it has — unless it has none, in which case the login is recreated
# so that both sides hold the same secret again.
if [[ "${PBS_FS_LOGIN_EXISTED:-0}" -eq 1 ]]; then
    if tappaas_ssh_guest -o BatchMode=yes "${TARGET}" \
            "${SUDO}test -s /etc/secrets/backup-fs.pw" >/dev/null 2>&1; then
        debug "  ${MODULE} already holds its backup credential — left as it is"
        DEPLOY_PW=0
    else
        warn "  ${MODULE} has no backup credential but the PBS login exists — re-creating the login"
        pbs_fs_recreate_login "${MODULE}" "${FS_PW}" || die "could not re-provision the PBS login for ${MODULE}"
        DEPLOY_PW=1
    fi
else
    DEPLOY_PW=1
fi

# 3. Encryption key + escrow (§2.5.1). Generated on the guest so the plaintext
#    key never transits the mothership's shell history; escrowed centrally so a
#    restore is possible when the guest is gone. The out-of-band copy the
#    operator must ALSO hold is `backup-manager key export`.
# The password goes over the pipe, NOT through the remote shell: an
# interpolated heredoc would put it in the remote's parsed script text, and an
# argument would put it in the remote's process list.
if [[ "${DEPLOY_PW}" -eq 1 ]]; then
printf '%s' "${FS_PW}" | ssh -o ConnectTimeout=15 -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new "${TARGET}" \
    "${SUDO}bash -c 'mkdir -p /etc/secrets; chmod 755 /etc/secrets; umask 077; cat > /etc/secrets/backup-fs.pw; chown ${OWNER} /etc/secrets/backup-fs.pw'" \
    || die "could not write the backup login password on ${GUEST}"
fi

pbs_fs_ensure_key "${MODULE}" "${TARGET}" "${OWNER}" "${SUDO}" \
    || die "could not put ${MODULE}'s encryption key in place on ${GUEST}"
debug "  guest secrets in place on ${GUEST}"

# 4. Manifest + runner on the guest.
SCHEDULE="$(pbs_schedule_resolve "${MODULE}")"
pbs_fs_write_manifest "${MODULE}" "${REPO}" "${NS}" "${SCHEDULE}" "$(pbs_fs_fingerprint)" "${FS_PATHS[@]}" \
    || die "could not write the capture manifest"

MANIFEST="$(pbs_fs_manifest_path "${MODULE}")"
# When this module captures, from the schedule cascade (#691) — written as
# systemd units on a machine, and as a generated nix fragment for a guest,
# which cannot take units imperatively.
if [[ "${KIND}" == "machine" ]]; then
    pbs_fs_install_timer "${MODULE}" "${TARGET}" \
        || die "could not arm the capture timer on ${GUEST} — backup:filesystem is NOT wired for ${MODULE}"
else
    pbs_fs_install_timer_nix "${MODULE}" "${TARGET}" \
        || die "could not write the capture timer for ${GUEST} — backup:filesystem is NOT wired for ${MODULE}"
fi

pbs_fs_deploy_runner "${MODULE}" "${TARGET}" "${MANIFEST}" \
    || die "could not deliver the capture runner to ${GUEST} — backup:filesystem is NOT wired for ${MODULE}"

info "  ${GN}✓${CL} backup:filesystem wired for ${MODULE}: ${#FS_PATHS[@]} path(s) to namespace ${NS}, encrypted, captured ${SCHEDULE}"
if [[ "${KIND}" == "machine" ]]; then
    debug "     The capture TIMER was installed by this script: a machine has no NixOS"
    debug "     baseline to declare one. It is enabled and armed for 20:30."
else
    debug "     The capture TIMER is declared in the guest's own NixOS config, not by this"
    debug "     script: /etc/systemd/system is a read-only store symlink on NixOS, so the"
    debug "     trigger cannot be delivered imperatively. Every guest built from the TAPPaaS"
    debug "     baseline (templates/tappaas-common.nix) carries an inert tappaas-fs-backup"
    debug "     timer that arms itself once this runner lands; test-service.sh verifies it."
fi
install_note "     Run a capture now with: ssh ${TARGET} $(pbs_fs_runner_for "${MODULE}")"
