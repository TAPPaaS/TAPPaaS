#!/usr/bin/env bash
#
# tappaas-fs-backup.sh — run a module's file-level backup FROM INSIDE the guest
# (ADR-012 §3.1, D17). Deployed to the guest by backup:filesystem's
# install-service.sh and driven by a systemd timer there.
#
# Only the guest can read its own files, so this is the one piece of the backup
# system that runs inside a workload. It is deliberately tiny and dependency-free
# beyond proxmox-backup-client + jq: it reads a manifest, reads two secrets, and
# pushes. No cluster access, no TAPPaaS libraries, nothing that assumes the
# mothership is reachable — a backup that only works while the rest of the
# platform is healthy is not much of a backup.
#
# Secrets (never in the manifest, §2.5):
#   /etc/secrets/backup-fs.pw    the write-no-delete login's password
#   /etc/secrets/backup-fs.key   the client-side encryption key
#
# Usage: tappaas-fs-backup.sh [--manifest <file>] [--dry-run]
#
set -euo pipefail

MANIFEST="/home/tappaas/config/$(hostname).fsbackup.json"
DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --manifest) MANIFEST="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=1; shift ;;
        -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "tappaas-fs-backup: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

log() { printf '%s tappaas-fs-backup: %s\n' "$(date -Is)" "$*"; }
die() { printf '%s tappaas-fs-backup: ERROR %s\n' "$(date -Is)" "$*" >&2; exit 1; }

[[ -r "${MANIFEST}" ]] || die "no capture manifest at ${MANIFEST}"
command -v proxmox-backup-client >/dev/null 2>&1 \
    || die "proxmox-backup-client is not installed in this guest"

MODULE="$(jq -r '.module // empty'     "${MANIFEST}")"
REPO="$(jq -r '.repository // empty'   "${MANIFEST}")"
NS="$(jq -r '.namespace // empty'      "${MANIFEST}")"
mapfile -t PATHS < <(jq -r '.paths // [] | .[]' "${MANIFEST}")
[[ -n "${MODULE}" && -n "${REPO}" && -n "${NS}" ]] || die "manifest ${MANIFEST} is incomplete"
[[ "${#PATHS[@]}" -gt 0 ]] || die "manifest ${MANIFEST} declares no paths"

PW_FILE="/etc/secrets/backup-fs.pw"
KEY_FILE="/etc/secrets/backup-fs.key"
[[ -r "${PW_FILE}" ]]  || die "cannot read ${PW_FILE} (the write-no-delete login's password)"
[[ -r "${KEY_FILE}" ]] || die "cannot read ${KEY_FILE} — backups are encrypted client-side (ADR-012 §2.5) and will not run without the key"

# Build one <name>.pxar:<path> archive argument per declared path. A path that
# does not exist is FATAL, not skipped: it means the module's declared capture
# set and the guest have drifted apart, and a backup that silently stopped
# covering something is the failure mode this whole ADR exists to prevent.
args=()
for p in "${PATHS[@]}"; do
    [[ -e "${p}" ]] || die "declared path '${p}' does not exist in this guest"
    name="${p#/}"; name="${name%/}"; name="${name//\//-}"
    name="$(printf '%s' "${name}" | tr -c 'A-Za-z0-9._-' '-')"
    args+=("${name}.pxar:${p}")
done

log "capturing ${#args[@]} path(s) for ${MODULE} → ${REPO} ns ${NS}"
if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "dry run: proxmox-backup-client backup ${args[*]} --repository ${REPO} --ns ${NS} --backup-id ${MODULE}"
    exit 0
fi

PBS_PASSWORD="$(cat "${PW_FILE}")" \
PBS_ENCRYPTION_PASSWORD="" \
proxmox-backup-client backup "${args[@]}" \
    --repository "${REPO}" \
    --ns "${NS}" \
    --backup-id "${MODULE}" \
    --backup-type host \
    --keyfile "${KEY_FILE}" \
    || die "capture failed"

log "capture complete"
