#!/usr/bin/env bash
# validate.sh — environment-manager's `validate` verb (P10 contract). Delegates
# to the domain validator validate-environment.sh.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${here}/validate-environment.sh" "$@"
