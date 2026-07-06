#!/usr/bin/env bash
# validate.sh — environment-manager's `validate` verb (P10 contract). Delegates
# to the TS manager: `environment-manager validate` natively implements the
# schema + reference gate (validate-environment.sh is retired; the flags
# [FILE|DIR] --schema-dir --config-dir --zones --quiet are preserved).
set -euo pipefail
exec "${ENVIRONMENT_MANAGER_BIN:-environment-manager}" validate "$@"
