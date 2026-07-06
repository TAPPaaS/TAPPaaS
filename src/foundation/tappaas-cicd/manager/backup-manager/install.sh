#!/usr/bin/env bash
# install.sh — build + link the backup-manager CLI into ~/bin (idempotent).
#
# backup-manager is a TypeScript component (ADR-007 verb-alignment #3). The
# legacy bash entry scripts (backup-manager.sh, backup-status.sh,
# backup-restore.sh, validate-backup.sh, lib-cascade.sh) were retired in the
# ADR-007 post-implementation refactor, Phase 7.4 — the TS `backup-manager`
# bin is the only entry point now.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
mkdir -p "${bin}"

# ── build + link the TypeScript CLI via Nix (ADR-007 #3) ──────────────
# The TS reconcile resolves the cascade and shells to backup-controller for PBS.
# Shared build+link helper (lib/ doctrine: scaffolding lives once, sourced).
. "${here}/../../lib/component-install-lib.sh"
build_and_link_nix_component "${here}" "backup-manager"
