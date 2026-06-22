#!/usr/bin/env bash
# identity-controller/install.sh — P10 compiled-component installer.
# Idempotently (re)builds the identity-controller Python package via nix and
# relinks its CLI entry points (authentik-manager, identity-controller) into
# ~/bin so they track the repo build (no nixos-rebuild required).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"

# Optional shared logging helpers (info/warn/error). Fall back to echo if absent.
if [ -f "${bin}/common-install-routines.sh" ]; then
    # shellcheck source=/dev/null
    . "${bin}/common-install-routines.sh"
else
    info() { echo "[Info] $*"; }
    warn() { echo "[Warning] $*" >&2; }
fi

info "Building identity-controller (nix)..."
( cd "${here}" && nix-build -A default default.nix >/dev/null )

for tool in authentik-manager identity-controller; do
    src="${here}/result/bin/${tool}"
    if [ -e "${src}" ]; then
        ln -sfn "${src}" "${bin}/${tool}"
        info "  linked ${bin}/${tool}"
    else
        warn "  expected ${src} not found after build"
    fi
done
