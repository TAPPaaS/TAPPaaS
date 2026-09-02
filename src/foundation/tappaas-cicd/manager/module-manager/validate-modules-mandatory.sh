#!/usr/bin/env bash
#
# validate-modules-mandatory.sh — estate-wide mandatory-field lint.
#
# validate-module-tier-source.sh lints ONE module JSON at install time. Nothing
# reported the aggregate, so a field documented as mandatory could be absent on
# half the estate without anyone seeing a number (#561).
#
# SEVERITY follows the sanctioned convention set by validate-module-tier-source.sh
# — the question is "can the tool proceed correctly?", not "is this tidy":
#
#   ERROR   (exit 1)  the module declares a config block whose schema marks a
#                     field `requiredBy` that block, and the field is absent.
#                     No default exists; a VM cannot be built without a vmid.
#                     The tool CANNOT proceed.
#   WARNING (exit 0)  a field the schema marks `requiredOnModule` is absent but
#                     carries a documented `default`. The tool proceeds on that
#                     default — the same call validate-module-tier-source.sh
#                     already makes for `tier` ("defaulting to 'app'").
#
# Every finding names the remedy, not only the fault: a log line an operator
# cannot act on is a count, not a finding.
#
# Usage: validate-modules-mandatory.sh [OPTIONS]
#   --config-dir DIR   config dir (default: ${TAPPAAS_CONFIG:-/home/tappaas/config})
#   --schema PATH      module-fields.json (default: the deployed copy in --config-dir)
#   --json             machine-readable findings
#   -h, --help         show this help
#
# Exit: 0 clean or warnings only · 1 at least one error · 2 bad arguments
set -uo pipefail

CONFIG_DIR="${TAPPAAS_CONFIG:-/home/tappaas/config}"
SCHEMA=""
JSON=0
usage() { grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//'; exit 0; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-dir) [[ -n "${2:-}" ]] || { echo "--config-dir requires a value" >&2; exit 2; }; CONFIG_DIR="$2"; shift 2 ;;
    --schema)     [[ -n "${2:-}" ]] || { echo "--schema requires a value" >&2; exit 2; }; SCHEMA="$2"; shift 2 ;;
    --json)       JSON=1; shift ;;
    -h|--help)    usage ;;
    *)            echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done
[[ -n "$SCHEMA" ]] || SCHEMA="${CONFIG_DIR%/}/module-fields.json"
command -v jq >/dev/null 2>&1 || { echo "jq is required." >&2; exit 2; }
[[ -f "$SCHEMA" ]] || { echo "schema not found: ${SCHEMA}" >&2; exit 2; }
[[ -d "$CONFIG_DIR" ]] || { echo "config dir not found: ${CONFIG_DIR}" >&2; exit 2; }

# The two rule kinds, read from the schema so the lint has no list of its own.
#   on_module:  field<TAB>default      -> WARNING when absent
#   by_block:   field<TAB>block        -> ERROR when the block is declared
mapfile -t ON_MODULE < <(jq -r '.fields | to_entries[]
  | select(.value.requiredOnModule == true)
  | "\(.key)\t\(.value.default // "")"' "$SCHEMA" 2>/dev/null)
mapfile -t BY_BLOCK < <(jq -r '.fields | to_entries[]
  | . as $f | (.value.requiredBy // [])[]
  | "\($f.key)\t\(.)"' "$SCHEMA" 2>/dev/null)

MODULES=0; OKC=0; WARNINGS=0; ERRORS=0
FINDINGS=()
report() { [[ "$JSON" -eq 1 ]] || echo "$1"; }

for f in "${CONFIG_DIR%/}"/*.json; do
  [[ -e "$f" ]] || continue
  # A DEPLOYED module is the discriminator, not catalog membership: a config
  # carrying `vmname` is deployed whether or not any catalog lists it (#561).
  jq -e '.vmname' "$f" >/dev/null 2>&1 || continue
  m="$(basename "$f" .json)"; MODULES=$((MODULES + 1)); clean=1

  for row in "${ON_MODULE[@]}"; do
    [[ -n "$row" ]] || continue
    fld="${row%%$'\t'*}"; dfl="${row##*$'\t'}"
    jq -e --arg k "$fld" 'has($k)' "$f" >/dev/null 2>&1 && continue
    clean=0; WARNINGS=$((WARNINGS + 1))
    report "  WARNING  ${m}: no '${fld}' field — proceeding on the documented default '${dfl:-<none>}'; set ${fld} explicitly in ${f}"
    FINDINGS+=("{\"module\":\"${m}\",\"field\":\"${fld}\",\"severity\":\"warning\",\"remedy\":\"set ${fld} explicitly\"}")
  done

  for row in "${BY_BLOCK[@]}"; do
    [[ -n "$row" ]] || continue
    fld="${row%%$'\t'*}"; blk="${row##*$'\t'}"
    jq -e --arg b "$blk" '(.config // {}) | has($b)' "$f" >/dev/null 2>&1 || continue
    jq -e --arg b "$blk" --arg k "$fld" '((.config[$b] // {}) | has($k)) or has($k)' "$f" >/dev/null 2>&1 && continue
    clean=0; ERRORS=$((ERRORS + 1))
    report "  ERROR    ${m}: declares config block '${blk}' but no '${fld}' — the block cannot be applied; add ${fld} to ${f}"
    FINDINGS+=("{\"module\":\"${m}\",\"field\":\"${fld}\",\"block\":\"${blk}\",\"severity\":\"error\",\"remedy\":\"add ${fld}\"}")
  done

  [[ "$clean" -eq 1 ]] && OKC=$((OKC + 1))
done

if [[ "$JSON" -eq 1 ]]; then
  printf '{"modules":%d,"ok":%d,"warnings":%d,"errors":%d,"findings":[%s]}\n' \
    "$MODULES" "$OKC" "$WARNINGS" "$ERRORS" "$(IFS=,; echo "${FINDINGS[*]:-}")"
else
  # A line on every branch: "nothing to report" must be visible, never silence.
  echo "modules-mandatory: ${OKC} ok, ${WARNINGS} warning(s), ${ERRORS} error(s) over ${MODULES} deployed module(s)"
fi
[[ "$ERRORS" -eq 0 ]] || exit 1
exit 0
