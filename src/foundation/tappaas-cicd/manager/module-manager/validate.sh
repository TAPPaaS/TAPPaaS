#!/usr/bin/env bash
# validate.sh — module-manager's `validate` verb (P10 contract). Delegates to
# the TypeScript validator (the legacy validate-module.sh wrapper name was
# retired in the ADR-007 post-implementation refactor, Phase 7.1).
set -euo pipefail
exec module-manager validate "$@"
