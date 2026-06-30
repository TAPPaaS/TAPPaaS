#!/usr/bin/env bash
# validate.sh — validate every satellite-<name>.json in the config dir (idempotent,
# read-only). Delegates to `satellite-manager validate`.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mgr="${here}/satellite-manager.sh"
config_dir="${TAPPAAS_CONFIG_DIR:-${CONFIG_DIR:-/home/tappaas/config}}"

shopt -s nullglob
found=0
for cfg in "${config_dir}"/satellite-*.json; do
    found=1
    name="$(basename "${cfg}" .json)"; name="${name#satellite-}"
    "${mgr}" validate "${name}"
done
[[ "${found}" -eq 1 ]] || echo "  no satellite-*.json in ${config_dir} (nothing to validate)"
