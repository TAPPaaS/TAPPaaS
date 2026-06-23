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
for f in "${here}"/*.sh; do
    b="$(basename "${f}")"
    case "${b}" in install.sh|update.sh|test.sh|validate.sh) continue ;; esac
    case "${b}" in lib-*.sh) continue ;; esac
    chmod +x "${f}"
    ln -sfn "${f}" "${bin}/${b}"
    echo "  linked ${bin}/${b}"
done
# Convenient no-suffix alias for the main entry (backup-manager -> .sh).
ln -sfn "${here}/backup-manager.sh" "${bin}/backup-manager"
echo "  linked ${bin}/backup-manager (alias)"
