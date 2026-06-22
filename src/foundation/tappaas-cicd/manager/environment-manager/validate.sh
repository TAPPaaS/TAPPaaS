#!/usr/bin/env bash
# validate.sh — manager verb: validate this manager's domain (ADR-007 P3).
# Delegates to validate-environment.sh against the target config/environments.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${here}/validate-environment.sh" "$@"
