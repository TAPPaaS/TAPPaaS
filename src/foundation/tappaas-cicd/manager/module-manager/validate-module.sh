#!/usr/bin/env bash
# validate-module.sh — back-compat project-wide name for the module validator.
#
# The real validator is now the TypeScript `module-manager validate` verb
# (native tier/source lint, ADR-007 #4 — no longer a stub). This thin wrapper
# delegates to it so the legacy `validate-module.sh [<module>]` name keeps
# working. (Full JSON-schema conformance against module-fields.json remains a
# follow-up, tracked in src/validate.ts.)
set -euo pipefail
exec module-manager validate "$@"
