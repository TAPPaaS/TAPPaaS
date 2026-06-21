#!/usr/bin/env bash
#
# audit-jq-readers.sh — find direct `jq … "${CONFIG_DIR}/<m>.json"` reads (#207)
#
# Installed module configs may be written in Pattern A (config block) form. Any
# script that reads them directly with jq, instead of going through
# `read_module_config` / `get_config_value`, will silently return null for fields
# that have moved under a config block.
#
# This script greps the foundation + apps tree for such direct reads. Used both
# during the #207 reader-funnel migration and as a CI regression net.
#
# Usage:
#   audit-jq-readers.sh                          # report all direct readers
#   audit-jq-readers.sh --quiet                  # only print count + exit 1 if any
#   audit-jq-readers.sh --strict                 # exit non-zero if any are found
#
# Exit codes:
#   0  no direct readers found (or --strict not set)
#   1  --strict and direct readers exist
#   2  bad arguments

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [--quiet|--strict]

Audit the TAPPaaS tree for direct jq reads on installed module configs.

Scans:
  src/foundation/**/*.sh
  src/apps/**/*.sh

Excludes (allowlisted):
  - apply-json-merge.sh, convert-json-to-config.sh, copy-update-json.sh — the
    plumbing that's allowed to touch the file directly
  - tappaas-cicd/lib/common-install-routines.sh — defines the helpers
  - .bak, .orig, /Attic/, third-party Community/

Options:
  --quiet    Print only the count
  --strict   Exit non-zero if any direct readers are found
  -h, --help Show this help
EOF
}

OPT_QUIET=0
OPT_STRICT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --quiet)   OPT_QUIET=1; shift ;;
        --strict)  OPT_STRICT=1; shift ;;
        *)         echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

ROOT="/home/tappaas/TAPPaaS/src"

# Patterns that indicate a direct read of an installed module config:
#   jq … "${CONFIG_DIR}/<anything>.json"
#   jq … "$JSON_CONFIG"
#   jq … "${MODULE_JSON}"
#   jq … "${module_json}"
#   jq … "/home/tappaas/config/<…>.json"
#
# Excludes configuration.json (cluster-wide config, not a module config).

# Match `jq …` lines (allowing pipes inside the filter) that reference one of
# the known module-config path variables as a positional argument. The path
# must appear on the same line — line-spanning quotes are out of scope.
PATTERN='\bjq\b.*("\$\{?CONFIG_DIR\}?/[^"]*\.json"|"\$\{?JSON_CONFIG\}?"|"\$\{?MODULE_JSON\}?"|"\$\{?module_json\}?"|"/home/tappaas/config/[^"]*\.json")'

declare -a HITS=()
while IFS= read -r line; do
    HITS+=("$line")
done < <(
    grep -rEn --include='*.sh' "$PATTERN" "$ROOT" 2>/dev/null \
      | grep -vE '/(Attic|Community)/' \
      | grep -vE '\.(bak|orig)$' \
      | grep -vE 'configuration\.json' \
      | grep -vE '/(apply-json-merge|convert-json-to-config|copy-update-json|common-install-routines|audit-jq-readers)\.sh:'
)

COUNT=${#HITS[@]}

if [[ "${OPT_QUIET}" -eq 1 ]]; then
    echo "${COUNT}"
else
    if [[ "${COUNT}" -gt 0 ]]; then
        printf '%s\n' "${HITS[@]}"
        echo
    fi
    echo "Direct jq readers found: ${COUNT}"
    if [[ "${COUNT}" -gt 0 ]]; then
        echo "Migrate each to: \`read_module_config <m> | jq …\` (external module) or \`get_config_value <field>\` (current module)."
    fi
fi

if [[ "${OPT_STRICT}" -eq 1 && "${COUNT}" -gt 0 ]]; then
    exit 1
fi
exit 0
