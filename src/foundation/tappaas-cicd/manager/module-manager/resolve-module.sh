#!/usr/bin/env bash
#
# resolve-module.sh — locate a module via the repository module catalogs (ADR-004).
#
# Removes the install-module.sh CWD dependency: given a bare <module> name, it
# searches every repository declared in site.json (.repositories[]) for that
# module's entry in the repo's src/module-catalog.json (by moduleName OR
# legacyName), and resolves the module's source path from the entry's
# `moduleJson`. WARNS on a name clash (the same module name in more than one
# repo) and selects the first repository in site.json order.
#
# Usage:
#   resolve-module.sh <module> [--config-dir DIR] [--field dir|json|tier|repo]
#
# --field (default: dir):
#   dir   absolute source DIRECTORY of the module (dirname of its <module>.json)
#   json  absolute path to the module's <module>.json
#   tier  the module's tier (foundation | official | app)
#   repo  the repository name it was resolved from
#
# Exit: 0 found; 1 not found / no site.json; 2 usage error.
#
set -euo pipefail

CONFIG_DIR="${TAPPAAS_CONFIG:-/home/tappaas/config}"
FIELD="dir"
MODULE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-dir) [[ -n "${2:-}" ]] || { echo "resolve-module.sh: --config-dir requires a value" >&2; exit 2; }; CONFIG_DIR="$2"; shift 2 ;;
    --field)      [[ -n "${2:-}" ]] || { echo "resolve-module.sh: --field requires a value" >&2; exit 2; }; FIELD="$2"; shift 2 ;;
    -h|--help)    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           echo "resolve-module.sh: unknown option '$1'" >&2; exit 2 ;;
    *)            [[ -z "$MODULE" ]] || { echo "resolve-module.sh: unexpected argument '$1'" >&2; exit 2; }; MODULE="$1"; shift ;;
  esac
done
[[ -n "$MODULE" ]] || { echo "resolve-module.sh: <module> is required" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "resolve-module.sh: jq is required" >&2; exit 2; }

SITE="${CONFIG_DIR%/}/site.json"
[[ -f "$SITE" ]] || { echo "resolve-module.sh: site.json not found: ${SITE}" >&2; exit 1; }

# Resolved matches, one per line: "<repo>\t<abs-json>\t<tier>".
matches=()
while IFS=$'\t' read -r rname rpath; do
  [[ -n "$rpath" ]] || continue
  catalog="${rpath%/}/src/module-catalog.json"
  [[ -f "$catalog" ]] || continue
  # Find the module by moduleName OR legacyName; emit "<moduleJson>\t<tier>".
  entry="$(jq -r --arg m "$MODULE" '
      (((.foundationModules // []) + (.applicationModules // []))
       | map(select(.moduleName == $m or .legacyName == $m))
       | .[0]) as $e
      | if $e == null then empty else "\($e.moduleJson)\t\($e.tier // "app")" end
    ' "$catalog" 2>/dev/null || true)"
  [[ -n "$entry" ]] || continue
  mjson="${entry%%$'\t'*}"; tier="${entry##*$'\t'}"
  matches+=("${rname}"$'\t'"${rpath%/}/${mjson}"$'\t'"${tier}")
done < <(jq -r '.repositories[]? | [.name, .path] | @tsv' "$SITE" 2>/dev/null)

if [[ ${#matches[@]} -eq 0 ]]; then
  echo "resolve-module.sh: module '${MODULE}' not found in any repository catalog (site: ${SITE})" >&2
  exit 1
fi
if [[ ${#matches[@]} -gt 1 ]]; then
  {
    echo "resolve-module.sh: WARNING — module '${MODULE}' is defined in multiple repositories:"
    for m in "${matches[@]}"; do echo "    - repo '$(cut -f1 <<<"$m")': $(cut -f2 <<<"$m")"; done
    echo "  selecting the first in site.json order: repo '$(cut -f1 <<<"${matches[0]}")'."
  } >&2
fi

sel="${matches[0]}"
r_repo="$(cut -f1 <<<"$sel")"; r_json="$(cut -f2 <<<"$sel")"; r_tier="$(cut -f3 <<<"$sel")"
case "$FIELD" in
  dir)  dirname "$r_json" ;;
  json) printf '%s\n' "$r_json" ;;
  tier) printf '%s\n' "$r_tier" ;;
  repo) printf '%s\n' "$r_repo" ;;
  *)    echo "resolve-module.sh: unknown --field '${FIELD}' (dir|json|tier|repo)" >&2; exit 2 ;;
esac
