#!/usr/bin/env bash
# install.sh — link this component's CLI entry scripts into ~/bin (idempotent).
#
# site-manager (ADR-007 P2) is a bash component. It links every *.sh here
# except the dispatcher verb scripts (install/update/test/validate.sh). That
# covers the P2 entry points:
#   migrate-configuration.sh         -> ~/bin/migrate-configuration.sh
#   migrate-configuration-to-site.sh -> ~/bin/migrate-configuration-to-site.sh (alias)
#   validate-site.sh                 -> ~/bin/validate-site.sh
# plus the still-resident legacy site scripts (create-configuration.sh, ...).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
mkdir -p "${bin}"
for f in "${here}"/*.sh; do
    b="$(basename "${f}")"
    case "${b}" in install.sh|update.sh|test.sh|validate.sh) continue ;; esac
    # chmod the resolved source (chmod follows symlinks; the alias points at a
    # repo file, the target may be read-only /etc/static on NixOS).
    chmod +x "$(readlink -f "${f}")"
    ln -sfn "${f}" "${bin}/${b}"
    echo "  linked ${bin}/${b}"
done
