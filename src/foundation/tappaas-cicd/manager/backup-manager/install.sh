#!/usr/bin/env bash
# install.sh — link backup-manager's CLI entry scripts into ~/bin (idempotent).
#
# backup-manager (ADR-007 P9) is a bash component. It links every *.sh here
# except the dispatcher verb scripts (install/update/test/validate) and sourced
# libs (lib-*.sh). Entry points:
#   backup-manager.sh   -> ~/bin/backup-manager.sh   (+ backup-manager alias)
#   backup-status.sh    -> ~/bin/backup-status.sh
#   backup-restore.sh   -> ~/bin/backup-restore.sh
#   validate-backup.sh  -> ~/bin/validate-backup.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
mkdir -p "${bin}"

# ── build + link the TypeScript CLI via Nix (ADR-007 #3) ──────────────
# The TS `backup-manager` is the new verb-aligned front door (it OWNS the bare
# `backup-manager` name now — the legacy bash entry stays as backup-manager.sh).
# The TS reconcile resolves the cascade and shells to backup-controller for PBS.
echo "  building backup-manager (tsc via nix-build)..."
( cd "${here}" && nix-build -A default default.nix --no-out-link >/tmp/backup-manager-build.path )
out="$(cat /tmp/backup-manager-build.path)"
[[ -x "${out}/bin/backup-manager" ]] || { echo "  ERROR: build did not produce backup-manager" >&2; exit 1; }
ln -sfn "${out}/bin/backup-manager" "${bin}/backup-manager"
echo "  linked ${bin}/backup-manager -> ${out}/bin/backup-manager"

for f in "${here}"/*.sh; do
    b="$(basename "${f}")"
    case "${b}" in install.sh|update.sh|test.sh|validate.sh) continue ;; esac
    case "${b}" in lib-*.sh) continue ;; esac
    chmod +x "${f}"
    ln -sfn "${f}" "${bin}/${b}"
    echo "  linked ${bin}/${b}"
done
# NOTE: the bare `backup-manager` name is now the TS bin (linked above); the
# legacy entry remains available as `backup-manager.sh`.
