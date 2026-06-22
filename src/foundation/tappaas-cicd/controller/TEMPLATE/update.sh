#!/usr/bin/env bash
# TEMPLATE/update.sh — copy this directory to scaffold a new controller component.
# The parent dispatcher SKIPS TEMPLATE/, so this stub never runs in place.
set -euo pipefail

# --- Compiled-component pattern (uncomment + adapt for your language) --------
# update.sh must be IDEMPOTENT. For a compiled component it REBUILDS the package
# so code changes are picked up, then re-links its bin entry point. A no-op when
# inputs are unchanged. Bash components only re-link.
#
#   # Python / TypeScript: rebuild, then re-link the bin entry point
#   #   Python:
#   #     nix build .#my-controller     # or: pip install -e ./src
#   #   TypeScript:
#   #     npm ci && npm run build        # or: pnpm install && pnpm build
#   ln -sf "$(pwd)/result/bin/my-controller" /home/tappaas/bin/my-controller
#
#   # Bash: nothing to rebuild — just re-link:
#   ln -sf "$(pwd)/my-controller.sh" /home/tappaas/bin/my-controller
# -----------------------------------------------------------------------------

echo "[TEMPLATE] update: rebuild, re-link, migrate on-disk state if schema changed (idempotent)"
