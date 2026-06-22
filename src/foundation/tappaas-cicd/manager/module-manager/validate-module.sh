#!/usr/bin/env bash
# validate-module.sh — module-manager's "validate" verb (script-manager naming
# convention: <verb>-<manager>.sh). Schema/reference validation of installed
# module configs. Currently a STUB — the real validator (lint every module
# config via validate-module-tier-source.sh + schema check) is pending; the
# per-module tier/source lint already exists as validate-module-tier-source.sh.
set -euo pipefail
echo "validate-module: ok (stub — real validator pending)"
