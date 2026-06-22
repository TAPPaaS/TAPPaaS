#!/usr/bin/env bash
# TEMPLATE/install.sh — copy this directory to scaffold a new manager component.
# The parent dispatcher SKIPS TEMPLATE/, so this stub never runs in place.
set -euo pipefail

# --- Compiled-component pattern (uncomment + adapt for your language) --------
# install.sh must be IDEMPOTENT and must (re)build a compiled artifact, not
# just copy source. Bash components only need the symlink.
#
#   # Python / TypeScript: (re)build the package, then (re)link its bin entry
#   #   Python:
#   #     nix build .#my-manager        # or: pip install -e ./src
#   #   TypeScript:
#   #     npm ci && npm run build        # or: pnpm install && pnpm build
#   #   then refresh the bin/ entry-point symlink (idempotent: ln -sf):
#   ln -sf "$(pwd)/result/bin/my-manager" /home/tappaas/bin/my-manager
#
#   # Bash: nothing to compile — just link the entry script onto PATH:
#   ln -sf "$(pwd)/my-manager.sh" /home/tappaas/bin/my-manager
# -----------------------------------------------------------------------------

echo "[TEMPLATE] install: build artifact, place bin/ symlink, one-time setup (idempotent)"
