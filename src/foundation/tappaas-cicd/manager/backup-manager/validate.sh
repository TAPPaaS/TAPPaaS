#!/usr/bin/env bash
# validate.sh — backup-manager's `validate` verb (P10 contract). Delegates to
# the domain validator validate-backup.sh against the live config dir.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${here}/validate-backup.sh" "$@"
