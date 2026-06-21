#!/usr/bin/env bash
# TEMPLATE/update.sh — copy this directory to scaffold a new controller component.
# The parent dispatcher SKIPS TEMPLATE/, so this stub never runs in place.
set -euo pipefail
echo "[TEMPLATE] update: rebuild, re-link, migrate on-disk state if schema changed (idempotent)"
