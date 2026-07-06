#!/usr/bin/env bash
# validate.sh — backup-manager's `validate` verb (P10 contract). Delegates to
# the TypeScript validator (the legacy validate-backup.sh domain script was
# retired in the ADR-007 post-implementation refactor, Phase 7.4).
set -euo pipefail
exec backup-manager validate "$@"
