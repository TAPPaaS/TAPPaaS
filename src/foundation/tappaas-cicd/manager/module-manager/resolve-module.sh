#!/usr/bin/env bash
#
# resolve-module.sh — locate a module via the repository module catalogs (ADR-004).
#
# Removes the install-module.sh CWD dependency: given a bare <module> name, it
# searches every repository declared in site.json (.repositories[]) for that
# module's entry in the repo's module catalog (by moduleName OR legacyName),
# and resolves the module's source path from the entry's `moduleJson`. WARNS on
# a name clash (the same module name in more than one repo) and selects the
# first repository in site.json order.
#
# The catalog path comes from the entry's `catalog` field when set, else
# src/module-catalog.json, else the legacy src/modules.json — the same
# repo_catalog_file() `repository add` used to validate and record it (#459).
#
# NOTE: the catalog is only ONE of the ways a module is located (#460).
# install-module.sh takes the current directory first and records it as
# .moduleSource in the deployed config, so a module installed from an unregistered
# path resolves through .moduleSource alone and is legitimately absent here.
# `module-manager list --resolution` reports which path each module uses.
#
# Usage:
#   resolve-module.sh <module> [--config-dir DIR] [--field dir|json|scope|repo]
#
# --field (default: dir):
#   dir   absolute source DIRECTORY of the module (dirname of its <module>.json)
#   json  absolute path to the module's <module>.json
#   scope the module's scope (site | environment), derived from its stack (ADR-022e)
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
    -h|--help)    sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           echo "resolve-module.sh: unknown option '$1'" >&2; exit 2 ;;
    *)            [[ -z "$MODULE" ]] || { echo "resolve-module.sh: unexpected argument '$1'" >&2; exit 2; }; MODULE="$1"; shift ;;
  esac
done
[[ -n "$MODULE" ]] || { echo "resolve-module.sh: <module> is required" >&2; exit 2; }

case "$FIELD" in
  dir|json|scope|repo) ;;
  *) echo "resolve-module.sh: unknown --field '${FIELD}' (dir|json|scope|repo)" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "resolve-module.sh: jq is required" >&2; exit 2; }

# Catalog-location helpers (#459). Side-effect-free lib: no logging, no colors,
# so it cannot disturb this script's own output contract.
# TAPPAAS_CATALOG_LIB first, for a test running THIS tree's library: the
# installed copy is deliberately preferred otherwise (it is what a site runs),
# which would otherwise make a test of new catalog handling exercise the old one.
for _mcl in ${TAPPAAS_CATALOG_LIB:-} /home/tappaas/bin/module-catalog-lib.sh \
            "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../lib/module-catalog-lib.sh"; do
  # shellcheck source=/dev/null
  if [[ -r "${_mcl}" ]]; then . "${_mcl}"; break; fi
done
unset _mcl
declare -F repo_catalog_file >/dev/null 2>&1 \
  || { echo "resolve-module.sh: module-catalog-lib.sh not found (expected /home/tappaas/bin/module-catalog-lib.sh)" >&2; exit 2; }

SITE="${CONFIG_DIR%/}/site.json"
[[ -f "$SITE" ]] || { echo "resolve-module.sh: site.json not found: ${SITE}" >&2; exit 1; }

# --field scope: the module's OWN deployed config is authoritative and is the
# only source that works for a module resolved via .moduleSource rather than a
# catalog (#460). Scope is derived from the config's `stack` (module_scope_of,
# ADR-022e v1.1), falling back to a retired `tier` for one release (#676).
#
# A deployed module (it has a `vmname`) that says neither resolves to the
# default, `environment`, but only AFTER the catalog lookup below fails, so a
# catalogued stack still wins. Without that default each caller invented its own
# reading of the silence, and one migration's reading was wrong for 22 of 47
# deployed modules on a real site (#561). A config without a vmname (site.json,
# zones.json, a field schema) stays unresolved, or this resolver would start
# claiming they are modules.
SCOPE_DEFAULTABLE=0
if [[ "$FIELD" == "scope" ]]; then
  _mjson="${CONFIG_DIR%/}/${MODULE}.json"
  if [[ -f "$_mjson" ]] && jq -e '(.stack // .tier // "") != ""' "$_mjson" >/dev/null 2>&1; then
    module_scope_of "$_mjson"
    exit 0
  fi
  if [[ -f "$_mjson" ]] && jq -e '.vmname' "$_mjson" >/dev/null 2>&1; then
    SCOPE_DEFAULTABLE=1
  fi
fi

# Resolved matches, one per line: "<repo>\t<abs-json>\t<scope>".
#
# The repository feed is \001-separated, NOT tab: `read` treats runs of IFS
# WHITESPACE as one delimiter, so an entry with an empty .path and .catalog
# would silently shift .managed into $rpath. \001 is not whitespace, so empty
# fields are preserved.
matches=()
while IFS=$'\001' read -r rname rpath rcatalog rmanaged; do
  if [[ -z "$rpath" || "$rpath" == "null" ]]; then
    # A repository with no .path contributes nothing to name resolution. That
    # used to be a silent skip; say so, since it is a misconfiguration (#459).
    [[ "$rmanaged" == "tracked" ]] \
      || echo "resolve-module.sh: WARNING — repository '${rname:-?}' has no .path in site.json; skipped" >&2
    continue
  fi
  [[ "$rcatalog" == "null" ]] && rcatalog=""
  catalog="$(repo_catalog_file "$rpath" "$rcatalog")"
  if [[ ! -f "$catalog" ]]; then
    # `managed: tracked` repos are registered WITHOUT catalog requirements
    # (ADR-004) — no catalog is their normal state. For a `full` repo it is not.
    [[ "$rmanaged" == "tracked" ]] \
      || echo "resolve-module.sh: WARNING — repository '${rname}' declares no readable module catalog (looked for ${catalog}); skipped" >&2
    continue
  fi
  entry="$(repo_catalog_entry "$catalog" "$MODULE" || true)"
  [[ -n "$entry" ]] || continue
  mjson="${entry%%$'\t'*}"; scope="${entry##*$'\t'}"
  matches+=("${rname}"$'\t'"${rpath%/}/${mjson}"$'\t'"${scope}")
done < <(jq -r '.repositories[]?
                | [(.name // ""), (.path // ""), (.catalog // ""), (.managed // "")]
                | join("\u0001")' "$SITE" 2>/dev/null)

if [[ ${#matches[@]} -eq 0 ]]; then
  # A deployed module with no stack and no catalog entry resolves to the
  # default rather than to nothing (#561). Reported on stderr so the default is
  # visible, never silent: a caller that discards stderr still gets a usable
  # value instead of an empty string it has to interpret.
  if [[ "$FIELD" == "scope" && "$SCOPE_DEFAULTABLE" -eq 1 ]]; then
    echo "resolve-module.sh: '${MODULE}' has no stack and is in no catalog — using the default scope 'environment' (ADR-022e)" >&2
    printf 'environment\n'
    exit 0
  fi
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
r_repo="$(cut -f1 <<<"$sel")"; r_json="$(cut -f2 <<<"$sel")"; r_scope="$(cut -f3 <<<"$sel")"
case "$FIELD" in
  dir)  dirname "$r_json" ;;
  json) printf '%s\n' "$r_json" ;;
  scope) printf '%s\n' "$r_scope" ;;
  repo) printf '%s\n' "$r_repo" ;;
esac
