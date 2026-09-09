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
    p="$(printf '%s' "${p}" | tr -c 'A-Za-z0-9._-' '-')"
    [[ -n "${p}" ]] || p="root"
    printf '%s\n' "${p}"
}

# One proxmox-backup-client archive argument: <name>.pxar:<path>
pbs_fs_archive_spec() { printf '%s.pxar:%s\n' "$(pbs_fs_archive_name "$1")" "$1"; }

# The guest OS types whose layout TAPPaaS knows well enough to select and
# restore named paths. rc 0 = supported.
pbs_fs_os_supported() {
    case "${1,,}" in
        nixos|nix) return 0 ;;
        *) return 1 ;;
    esac
}

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
    local f tmp
    f="$(pbs_fs_manifest_path "${module}")"
    tmp="$(mktemp)"
    printf '%s\n' "$@" | jq -R . | jq -s \
        --arg m "${module}" --arg r "${repo}" --arg n "${ns}" --arg s "${schedule}" --arg fp "${fp}" \
        '{module: $m, repository: $r, namespace: $n, schedule: $s, fingerprint: $fp, paths: .}' >"${tmp}" \
        && mv "${tmp}" "${f}" || { rm -f "${tmp}"; return 1; }
    chmod 644 "${f}"
    info "  ${GN}✓${CL} capture manifest → ${f}"
}

# The declared paths for <module>, one per line (empty when none).
pbs_fs_paths() {
    jq -r '.backup.filesystemPaths // [] | .[]' \
        "${PBS_FS_CONFIG_DIR}/$1.json" 2>/dev/null || true
}
