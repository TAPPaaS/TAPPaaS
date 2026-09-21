# shellcheck shell=bash
# pbs-fs.sh — file-level backup of a subset of a guest (ADR-012 §3.1, D17).
#
# `backup:filesystem` captures NAMED PATHS inside a guest rather than the whole
# guest. A module opts in with `dependsOn: ["backup:filesystem"]` (or
# integratesWith) and declares `backup.filesystemPaths`.
#
# Where it differs from backup:vm, and why:
#
#   backup:vm          Proxmox snapshots the guest from the OUTSIDE. Nothing is
#                      needed inside the guest.
#   backup:filesystem  only the guest can read its own files, so the capture
#                      runs INSIDE it: a proxmox-backup-client push into the
#                      namespace fs/<module>, on a timer, with a write-no-delete
#                      login and a client-side encryption key (§2.5).
#
# The credential shape is the one §2.5 already defines for every client — write,
# no delete, PBS owns prune — so a compromised guest can add snapshots of its
# own files but never erase its history. Nothing here is a new mechanism.
#
# GUEST OS GATE. Selecting and restoring named paths reliably needs TAPPaaS to
# know the guest's layout, so this is offered only where it does: NixOS guests.
# Any other ostype FAILS the service install with a clear message rather than
# capturing something half-right — a filesystem backup that quietly missed the
# paths that mattered is worse than no filesystem backup.
#
# Requires: common-install-routines.sh, lib/pbs-job.sh and lib/pbs-namespace.sh
# sourced first.

PBS_FS_CONFIG_DIR="${CONFIG_DIR:-/home/tappaas/config}"

# Where a module's capture manifest lives: what to capture, where to send it.
# Deliberately NOT a <module>.json — that namespace belongs to module configs.
pbs_fs_manifest_path() { printf '%s/%s.fsbackup.json\n' "${PBS_FS_CONFIG_DIR}" "$1"; }

# ── Pure helpers (no cluster access — unit-testable) ─────────────────

# The namespace a module's file backups live in. One per module, under a single
# `fs` parent, so file captures never mix with the VM snapshots in the root
# namespace or with the remote/external peer trees (#227).
pbs_fs_namespace() { printf 'fs/%s\n' "$1"; }

# A PBS archive name derived from a path: leading slash dropped, separators and
# anything exotic folded to '-', so /home/tappaas/config -> home-tappaas-config.
pbs_fs_archive_name() {
    local p="${1#/}"
    p="${p%/}"
    p="${p//\//-}"
    # No dot: PBS's backupspec is <name>.pxar:<path> and a dot in the NAME is
    # rejected at parameter verification — /var/lib/pve-cluster/config.db
    # derived one (#662). The runner applies the same rule; they must agree.
    p="$(printf '%s' "${p}" | tr -c 'A-Za-z0-9_-' '-')"
    [[ -n "${p}" ]] || p="root"
    printf '%s\n' "${p}"
}

# One proxmox-backup-client archive argument: <name>.pxar:<path>
pbs_fs_archive_spec() { printf '%s.pxar:%s\n' "$(pbs_fs_archive_name "$1")" "$1"; }

# The guest OS types whose layout TAPPaaS knows well enough to select and
# restore named paths. rc 0 = supported.
#
# The gate is about a GUEST, whose paths TAPPaaS chose on the module's behalf.
# A machine (ADR-026 D8) declares its own paths explicitly — a Proxmox host's
# /etc, its pmxcfs database, its /root (#662) — so the layout is the operator's
# statement, not an assumption about the distribution, and Debian passes.
pbs_fs_os_supported() {
    case "${1,,}" in
        nixos|nix) return 0 ;;
        debian|pve|proxmox) [[ "${2:-}" == machine ]] && return 0 || return 1 ;;
        *) [[ "${2:-}" == machine ]] && return 0 || return 1 ;;
    esac
}

# ── where a module's files are, and who we are when we get there ──────
#
# A guest is reached as tappaas@<vmname>.<zone>.internal and needs sudo for the
# privileged reads. A machine has no vmname, and a Proxmox host has no tappaas
# user at all (verified on the test cluster, #662), so it is reached as
# root@<address> — where sudo is neither present nor needed.
pbs_fs_kind() {
    jq -r '.kind // "vm"' "${PBS_FS_CONFIG_DIR}/$1.json" 2>/dev/null || printf 'vm'
}

# user@host for <module>, or rc 1 when the config does not say where it is.
pbs_fs_target() {
    local module="$1" cfg="${PBS_FS_CONFIG_DIR}/$1.json" addr vmname zone
    if [[ "$(pbs_fs_kind "${module}")" == "machine" ]]; then
        addr="$(jq -r '.address // empty' "${cfg}" 2>/dev/null)"
        [[ -n "${addr}" ]] || return 1
        printf 'root@%s\n' "${addr}"
    else
        vmname="$(jq -r '.vmname // empty' "${cfg}" 2>/dev/null)"
        [[ -n "${vmname}" ]] || return 1
        zone="$(jq -r '.zone0 // "mgmt"' "${cfg}" 2>/dev/null)"
        printf 'tappaas@%s.%s.internal\n' "${vmname}" "${zone}"
    fi
}

# The privilege prefix for a command on <module>'s host: none as root.
pbs_fs_sudo() {
    [[ "$(pbs_fs_kind "$1")" == "machine" ]] && printf '' || printf 'sudo '
}

# Where the runner and its manifest live ON the target. A machine has no
# /home/tappaas, so both go where root's PATH already looks.
pbs_fs_runner_for()   { [[ "$(pbs_fs_kind "$1")" == "machine" ]] && printf '/usr/local/sbin/tappaas-fs-backup.sh' || printf '%s' "${PBS_FS_RUNNER_PATH}"; }
pbs_fs_manifest_dir_for() { [[ "$(pbs_fs_kind "$1")" == "machine" ]] && printf '/etc/tappaas' || printf '/home/tappaas/config'; }

# The backup login a module's guest uses to push its file captures. Distinct
# from the VM-backup login: it is scoped to this module's namespace only, so a
# compromised guest cannot even write into another module's file backups.
pbs_fs_authid() { printf '%s-fs@pbs\n' "$1"; }

# ── PBS-side provisioning ────────────────────────────────────────────

# Ensure the module's namespace exists and its login can WRITE BUT NOT DELETE
# there (§2.5: DatastoreBackup scoped to one namespace; PBS owns prune).
# Args: <module> [password]
pbs_fs_ensure_target() {
    local module="$1" pw="${2:-}" store ns authid
    store="$(pbs_storage_name)"
    ns="$(pbs_fs_namespace "${module}")"
    authid="$(pbs_fs_authid "${module}")"

    pbs_ns_ensure "${ns}" || { error "  could not create namespace ${ns}"; return 1; }

    if _pbs_node_run proxmox-backup-manager user list --output-format json 2>/dev/null \
        | jq -e --arg u "${authid}" '.[] | select(.userid==$u)' >/dev/null 2>&1; then
        info "  PBS login ${BL}${authid}${CL} already exists"
    else
        [[ -n "${pw}" ]] || { error "  pbs_fs_ensure_target: a password is required to create ${authid}"; return 1; }
        _pbs_node_run proxmox-backup-manager user create "${authid}" --password "${pw}" \
            || { error "  could not create PBS login ${authid}"; return 1; }
        info "  ${GN}✓${CL} created PBS login ${BL}${authid}${CL}"
    fi

    # DatastoreBackup on this namespace only: create + read its own snapshots,
    # no delete, no prune, nothing outside fs/<module>.
    _pbs_node_run proxmox-backup-manager acl update \
        "/datastore/${store}/${ns}" DatastoreBackup --auth-id "${authid}" \
        || { error "  could not grant DatastoreBackup on ${ns} to ${authid}"; return 1; }
    info "  ${GN}✓${CL} ${authid} may write (not delete) in ${BL}${ns}${CL}"
}

# The PBS server certificate fingerprint. NOT a secret — it is the public half
# of the TLS identity, and the client needs it because a TAPPaaS PBS serves a
# self-signed certificate. Without it the capture fails at connect with
# "Certificate fingerprint was not confirmed".
pbs_fs_fingerprint() {
    _pbs_node_run proxmox-backup-manager cert info 2>/dev/null \
        | sed -n 's/^Fingerprint (sha256): //p' | head -1
}

# Write the capture manifest the guest-side runner reads. Carries no secret:
# the login's password and the encryption key live in the guest's /etc/secrets
# and are escrowed centrally (§2.5.1), never in config. The fingerprint is
# public and belongs here — it is configuration, not a credential.
# Args: <module> <repository> <namespace> <schedule> <fingerprint> <path>...
pbs_fs_write_manifest() {
    local module="$1" repo="$2" ns="$3" schedule="$4" fp="$5"; shift 5
    local f tmp excl
    f="$(pbs_fs_manifest_path "${module}")"
    tmp="$(mktemp)"
    # The module's declared exclusions travel with the paths: a host capture
    # that took /root whole would carry 3.2 GB of rebuildable netboot ISOs
    # (#662), and the runner cannot know which of a path's contents are worth
    # storing — the module says so.
    excl="$(pbs_fs_exclude "${module}" | jq -R . | jq -sc .)"
    printf '%s\n' "$@" | jq -R . | jq -s \
        --arg m "${module}" --arg r "${repo}" --arg n "${ns}" --arg s "${schedule}" --arg fp "${fp}" \
        --argjson x "${excl:-[]}" \
        '{module: $m, repository: $r, namespace: $n, schedule: $s, fingerprint: $fp, paths: ., exclude: $x}' >"${tmp}" \
        && mv "${tmp}" "${f}" || { rm -f "${tmp}"; return 1; }
    chmod 644 "${f}"
    info "  ${GN}✓${CL} capture manifest → ${f}"
}

# The module's own release JSON, via .moduleSource (ADR-026 D6.2), or empty.
_pbs_fs_release_json() {
    local src
    src="$(jq -r '.moduleSource // empty' "${PBS_FS_CONFIG_DIR}/$1.json" 2>/dev/null)"
    [[ -n "${src}" && -f "${src}/$(basename "${src}").json" ]] || return 1
    printf '%s/%s.json' "${src}" "$(basename "${src}")"
}

# Read one field of the `backup` policy: the DEPLOYED config first, then the
# module's own release JSON.
#
# The fallback is not belt-and-braces, it is the only way a release can
# introduce this capability to a module that already exists. `backup` is
# service-owned (usedBy backup:filesystem), and the Pattern A grouper drops a
# service-owned field when the deployed `dependsOn` does not name that service
# — while `dependsOn` is header-pinned, so a release cannot add itself there
# either. The merge duly reports "added (new in release): backup.filesystemPaths"
# and writes a config without it (#662). Same shape as kind.ts reading an
# authored `kind` the deployed config has not adopted yet (#669).
_pbs_fs_backup_field() {
    local module="$1" field="$2" out rel
    out="$(jq -r --arg f "${field}" '.backup[$f] // [] | .[]' \
        "${PBS_FS_CONFIG_DIR}/${module}.json" 2>/dev/null || true)"
    if [[ -z "${out}" ]] && rel="$(_pbs_fs_release_json "${module}")"; then
        out="$(jq -r --arg f "${field}" '.backup[$f] // [] | .[]' "${rel}" 2>/dev/null || true)"
    fi
    printf '%s' "${out}"
    [[ -n "${out}" ]] && printf '\n'
    return 0
}

# The declared exclusions for <module>, one per line (empty when none). Read
# from the same `backup` policy object as the paths (backup/fields.json).
pbs_fs_exclude() { _pbs_fs_backup_field "$1" exclude; }

# The declared paths for <module>, one per line (empty when none).
pbs_fs_paths() { _pbs_fs_backup_field "$1" filesystemPaths; }

# Where the guest-side runner lives once delivered, and where it ships from.
# Resolved from this library's own location so every caller agrees on it.
PBS_FS_RUNNER_PATH="/home/tappaas/bin/tappaas-fs-backup.sh"
PBS_FS_SERVICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../services/filesystem" && pwd)"
pbs_fs_runner_path() { printf '%s\n' "${PBS_FS_RUNNER_PATH}"; }

# Deliver the runner + manifest to a guest and PROVE they arrived (#626).
#
# Both install-service.sh and update-service.sh call exactly this, so the two
# cannot drift: the install path used to `die` on a failed transfer while the
# update path only warned and then printed its success line, so a capture that
# had never been delivered reported as re-applied.
#
# Two rules this encodes:
#   * the transfer goes through tappaas_scp_guest / tappaas_ssh_guest, so a
#     guest that legitimately changed its SSH host key (recreate, reinstall,
#     cloud-init re-instantiation — #473) is re-pinned and retried rather than
#     failing the delivery. These were the last raw scp call sites left after
#     the helpers landed in 12b5fcf.
#   * success is a PROPERTY OF THE GUEST, not an exit code. The runner must be
#     executable at its target path and the manifest readable, checked on the
#     guest after the copy, before any caller may claim the capture is wired.
#
# A machine has no NixOS baseline to declare the trigger, so the units are
# installed here — the same two halves tappaas-common.nix gives a guest, with
# the same schedule (20:30, ahead of the 21:00 VM job, persistent so a night
# missed while the host was down is caught up) and the same reason for running
# as root: a capture set names paths its owner cannot read, and an unprivileged
# run skips them while proxmox-backup-client still exits 0 (#626).
# Args: <module> <target user@host>
pbs_fs_install_timer() {
    local module="$1" target="$2" runner host
    runner="$(pbs_fs_runner_for "${module}")"
    host="${target#*@}"
    tappaas_ssh_guest -o BatchMode=yes "${target}" "bash -s" <<EOF || { error "  could not install the capture timer on ${host}"; return 1; }
set -euo pipefail
cat > /etc/systemd/system/tappaas-fs-backup.service <<'UNIT'
[Unit]
Description=TAPPaaS file-level backup of this host's declared paths (ADR-012 §3.1, #662)
ConditionPathExists=${runner}

[Service]
Type=oneshot
ExecStart=${runner}
NoNewPrivileges=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
UNIT
cat > /etc/systemd/system/tappaas-fs-backup.timer <<'UNIT'
[Unit]
Description=Daily trigger for this host's file-level backup

[Timer]
OnCalendar=20:30
RandomizedDelaySec=5min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now tappaas-fs-backup.timer
EOF
    info "  ${GN}✓${CL} capture timer installed and armed on ${BL}${host}${CL}"
}

# Args: <module> <target user@host> <manifest-path>
pbs_fs_deploy_runner() {
    local module="$1" target="$2" manifest="$3"
    local runner mdir host
    runner="$(pbs_fs_runner_for "${module}")"
    mdir="$(pbs_fs_manifest_dir_for "${module}")"
    host="${target#*@}"
    local src="${PBS_FS_SERVICE_DIR}/tappaas-fs-backup.sh"
    [[ -f "${src}" ]] || { error "  backup:filesystem: runner source missing at ${src}"; return 1; }

    # A machine's directories are root's to make; a guest's already exist.
    tappaas_ssh_guest -o BatchMode=yes "${target}" "$(pbs_fs_sudo "${module}")mkdir -p '${mdir}' '$(dirname "${runner}")'" \
        || { error "  could not prepare ${mdir} on ${host}"; return 1; }

    # No -q: scp's progress meter is off for a non-tty anyway, so it bought
    # nothing here and cost the operator the reason a transfer failed (#630).
    tappaas_scp_guest -o BatchMode=yes "${src}" "${target}:${runner}" \
        || { error "  could not deploy the capture runner to ${host}"; return 1; }
    tappaas_scp_guest -o BatchMode=yes "${manifest}" "${target}:${mdir}/" \
        || { error "  could not deploy the capture manifest to ${host}"; return 1; }
    tappaas_ssh_guest -o BatchMode=yes "${target}" "chmod +x '${runner}'" \
        || { error "  could not make the capture runner executable on ${host}"; return 1; }

    # The verification the success line was missing. `test -x` on the target is
    # the only thing that distinguishes "delivered" from "reported delivered".
    tappaas_ssh_guest -o BatchMode=yes "${target}" \
        "test -x '${runner}' && test -r '${mdir}/$(basename "${manifest}")'" \
        || { error "  ${runner} is not present/executable on ${host} after delivery"; return 1; }

    info "  ${GN}✓${CL} runner + manifest deployed and verified on ${BL}${host}${CL}"
}
