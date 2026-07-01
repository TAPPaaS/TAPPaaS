#!/usr/bin/env bash
# TEMPLATE/install.sh — copy this directory to scaffold a new manager component.
# The parent dispatcher SKIPS TEMPLATE/, so this stub never runs in place.
set -euo pipefail

# --- Compiled-component pattern (uncomment + adapt for your language) --------
# install.sh must be IDEMPOTENT and must (re)build a compiled artifact, not
# just copy source. Bash components only need the symlink.
#
#   # TypeScript / Python (nix-built): build WITH a GC ROOT, then link the bin.
#   # IMPORTANT: never `nix-build --no-out-link` and symlink straight into
#   # /nix/store — nix-collect-garbage will delete the un-rooted build output and
#   # the ~/bin symlink dangles. Use --out-link (a GC root):
#   gcroots="${TAPPAAS_GCROOTS:-${HOME}/.tappaas-gcroots}"; mkdir -p "${gcroots}"
#   out="$( cd "${here}" && nix-build -A default default.nix --out-link "${gcroots}/my-manager" )"
#   ln -sfn "${out}/bin/my-manager" "/home/tappaas/bin/my-manager"
#
#   # Bash: nothing to compile — just link the entry script onto PATH:
#   ln -sf "$(pwd)/my-manager.sh" /home/tappaas/bin/my-manager
# -----------------------------------------------------------------------------

echo "[TEMPLATE] install: build artifact, place bin/ symlink, one-time setup (idempotent)"
