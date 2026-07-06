#!/usr/bin/env bash
# validate.sh — module-manager's `validate` verb (P10 contract). Delegates to
# the domain validator validate-module.sh.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${here}/validate-module.sh" "$@"
