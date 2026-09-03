#!/usr/bin/env bash
#
# provision-backup.sh — the ADR-010 backup role for a Debian satellite (P6).
#
# Runs ON the Debian satellite AFTER provision-debian.sh (the base). Installs the
# OFFICIAL proxmox-backup-server (Proxmox Debian repo — the whole point of D19:
# Debian gives supported PBS + OS diversity for the vault, §7.3), creates a local
# datastore, and wires the PULL model (D8): the satellite pulls from HOME PBS and
# owns prune/GC, so a compromised home cannot delete the off-site copies.
#
#   home PBS  ──(read-only token, over the wg tunnel)──▶  satellite pulls
#   Immutability = pull direction + destination-owned prune, NOT S3 Object Lock
#   (PBS has no Object Lock; enabling it corrupts the datastore — Bugzilla #6780,
#   see implementation-doc D16/Q8).
#
# Reads (rendered by satellite-manager `sat_gen_backup_config`, shipped alongside):
#   backup.env            non-secret config (datastore, home PBS host/store, authid, schedule)
#   pbs-remote-token      the home PBS read-only token SECRET, 0600 (out-of-band;
#                         NEVER committed). If absent, PBS + datastore are set up but
#                         the remote/sync-job are skipped with an operator runbook.
#
# The client-side ENCRYPTION KEY stays at HOME (§3.2) — the satellite stores only
# ciphertext and never holds the key. Nothing here touches it.
#
# Usage: ./provision-backup.sh          (run as root, from the deploy dir)
set -euo pipefail

_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
info()  { printf '[%s] [info]  %s\n'  "$(_ts)" "$*"; }
warn()  { printf '[%s] [warn]  %s\n'  "$(_ts)" "$*" >&2; }
error() { printf '[%s] [error] %s\n'  "$(_ts)" "$*" >&2; }
die()   { error "$*"; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "${HERE}"
[[ "$(id -u)" -eq 0 ]] || die "must run as root"
command -v apt-get >/dev/null 2>&1 || die "apt-get not found — targets Debian 12/13"
[[ -f backup.env ]] || die "backup.env not found — did satellite-manager render the backup config?"
# shellcheck source=/dev/null
. ./backup.env

export DEBIAN_FRONTEND=noninteractive

# ── 1. official proxmox-backup-server (Proxmox 'pbs-no-subscription' repo) ────
# Same source home uses (backup/install.sh) — an OFFICIAL, supported package.
if ! command -v proxmox-backup-manager >/dev/null 2>&1; then
    info "Installing proxmox-backup-server from the Proxmox Debian repo"
    codename="$(. /etc/os-release; echo "${VERSION_CODENAME:-bookworm}")"
    curl -fsSL "https://enterprise.proxmox.com/debian/proxmox-release-${codename}.gpg" \
        -o /usr/share/keyrings/proxmox-archive-keyring.gpg 2>/dev/null \
        || curl -fsSL "http://download.proxmox.com/debian/proxmox-release-${codename}.gpg" \
             -o /usr/share/keyrings/proxmox-archive-keyring.gpg
    cat > /etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pbs
Suites: ${codename}
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    rm -f /etc/apt/sources.list.d/pbs-enterprise.sources
    apt-get update -qq
    apt-get install -y -qq proxmox-backup-server proxmox-backup-client >/dev/null
    info "  proxmox-backup-server installed: $(proxmox-backup-manager version 2>/dev/null | head -1)"
else
    info "proxmox-backup-server already present: $(proxmox-backup-manager version 2>/dev/null | head -1)"
fi

# ── 2. local datastore (destination of the pull) ─────────────────────────────
# DATASTORE_PATH should live on a ZFS dataset for a real vault (create the pool on
# the host first); a plain directory works for smaller/volume backends.
_ds_exists() { proxmox-backup-manager datastore list --output-format json 2>/dev/null \
    | jq -e --arg n "${DATASTORE_NAME}" 'any(.[]; .name==$n)' >/dev/null 2>&1; }
install -d -m 0755 "${DATASTORE_PATH}"
if _ds_exists; then
    info "  datastore '${DATASTORE_NAME}' already exists"
else
    info "  creating datastore '${DATASTORE_NAME}' at ${DATASTORE_PATH}"
    proxmox-backup-manager datastore create "${DATASTORE_NAME}" "${DATASTORE_PATH}"
fi

# ── 3. the PULL wiring (remote + sync-job) — needs the home read-only token ──
if [[ -z "${HOME_PBS_HOST:-}" ]]; then
    warn "backup.env has no HOME_PBS_HOST — PBS + datastore ready, but no pull source configured."
    warn "Set backup.pull.homePbsHost in the satellite config and re-run."
    info "Backup role: datastore-only (no pull) — done."
    exit 0
fi
if [[ ! -s pbs-remote-token ]]; then
    warn "No home PBS read-only token provided (pbs-remote-token missing)."
    cat >&2 <<RUNBOOK
  To finish the pull wiring, on the HOME PBS create a read-only token and re-run:
    proxmox-backup-manager user create ${REMOTE_AUTHID%!*} --password '<pw>'   # if the user is new
    proxmox-backup-manager user generate-token ${REMOTE_AUTHID%!*} ${REMOTE_AUTHID#*!}
    proxmox-backup-manager acl update /datastore/${HOME_PBS_DATASTORE} DatastoreReader \\
        --auth-id '${REMOTE_AUTHID}'
  Then provide the printed token secret to satellite-manager (it ships it as the
  0600 pbs-remote-token) and re-run the backup provisioning.
RUNBOOK
    info "Backup role: datastore-only (pull pending home token) — done."
    exit 0
fi
token="$(< pbs-remote-token)"

# remote = home PBS (read-only pull source), over the wg tunnel.
_remote_exists() { proxmox-backup-manager remote list --output-format json 2>/dev/null \
    | jq -e --arg n "${REMOTE_NAME}" 'any(.[]; .name==$n)' >/dev/null 2>&1; }
_verb=create; _remote_exists && _verb=update
_ra=(proxmox-backup-manager remote "${_verb}" "${REMOTE_NAME}"
     --host "${HOME_PBS_HOST}" --auth-id "${REMOTE_AUTHID}" --password "${token}")
[[ -n "${HOME_PBS_PORT:-}" ]]        && _ra+=(--port "${HOME_PBS_PORT}")
[[ -n "${REMOTE_FINGERPRINT:-}" ]]   && _ra+=(--fingerprint "${REMOTE_FINGERPRINT}")
"${_ra[@]}"
info "  remote '${REMOTE_NAME}' -> ${HOME_PBS_HOST}:${HOME_PBS_PORT:-8007} (${_verb}, read-only)"

# sync-job = pull home datastore into our local namespace; destination owns retention.
# --remove-vanished false: home deleting a snapshot must NOT delete our off-site copy.
_sj_exists() { proxmox-backup-manager sync-job list --output-format json 2>/dev/null \
    | jq -e --arg i "${SYNC_JOB_ID}" 'any(.[]; .id==$i)' >/dev/null 2>&1; }
if _sj_exists; then
    proxmox-backup-manager sync-job update "${SYNC_JOB_ID}" \
        --remove-vanished "${REMOVE_VANISHED:-false}" --schedule "${SYNC_SCHEDULE:-daily}"
else
    _sj=(proxmox-backup-manager sync-job create "${SYNC_JOB_ID}"
         --store "${DATASTORE_NAME}" --ns "${SYNC_NS}"
         --remote "${REMOTE_NAME}" --remote-store "${HOME_PBS_DATASTORE}"
         --remove-vanished "${REMOVE_VANISHED:-false}" --schedule "${SYNC_SCHEDULE:-daily}")
    [[ -n "${HOME_PBS_NS:-}" ]] && _sj+=(--remote-ns "${HOME_PBS_NS}")
    "${_sj[@]}"
fi
info "  sync-job '${SYNC_JOB_ID}': pull ${REMOTE_NAME}:${HOME_PBS_DATASTORE} -> ${DATASTORE_NAME}/${SYNC_NS} (remove-vanished=${REMOVE_VANISHED:-false}, ${SYNC_SCHEDULE:-daily})"

# destination-owned prune (immutability = we control retention, not home).
if [[ -n "${PRUNE_SCHEDULE:-}" ]]; then
    _pj_exists() { proxmox-backup-manager prune-job list --output-format json 2>/dev/null \
        | jq -e --arg i "${SYNC_JOB_ID}-prune" 'any(.[]; .id==$i)' >/dev/null 2>&1; }
    _pv=create; _pj_exists && _pv=update
    # shellcheck disable=SC2086  # PRUNE_KEEP is an intentional word-split flag list
    proxmox-backup-manager prune-job "${_pv}" "${SYNC_JOB_ID}-prune" \
        --store "${DATASTORE_NAME}" --ns "${SYNC_NS}" --schedule "${PRUNE_SCHEDULE}" ${PRUNE_KEEP:-}
    info "  prune-job '${SYNC_JOB_ID}-prune' (${PRUNE_SCHEDULE}) — destination owns retention"
fi

info "Backup role provisioned. The satellite now PULLS from home; the encryption key"
info "stays at home (§3.2) so this vault holds only ciphertext."
