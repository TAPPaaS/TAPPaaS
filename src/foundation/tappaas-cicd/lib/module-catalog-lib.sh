#!/usr/bin/env bash
#
# module-catalog-lib.sh — where a repository's module catalog lives (ADR-004).
#
# This file should be sourced (.) into other scripts. It deliberately defines
# NOTHING but the functions below: no logging, no colors, no CONFIG_DIR, no
# JSON auto-load. That is what makes it safe to source into standalone scripts
# such as repository.sh and resolve-module.sh, which carry their own logging
# and must not have it replaced.
#
# Why it exists (issue #459): `repository add` validated a repository's catalog,
# fell back to the legacy name, and recorded the path it actually found into
# site.json .repositories[].catalog — while resolve-module.sh built the path
# from a hardcoded convention and never read that field. A repository whose
# catalog was legitimately at src/modules.json was registered successfully and
# then resolved nothing. Both sides now call repo_catalog_file().
#
# Provides:
#   repo_catalog_file <repo-path> [declared-catalog]  -> catalog file path
#   repo_catalog_entry <catalog-file> <module>        -> "<moduleJson>\t<tier>"

# Guard against double-sourcing.
if [[ -z "${_MODULE_CATALOG_LIB_LOADED:-}" ]]; then
_MODULE_CATALOG_LIB_LOADED=1

# Resolve a repository's module-catalog file path.
#
# Precedence:
#   1. the catalog path DECLARED on the site.json repositories[] entry
#   2. the current convention, src/module-catalog.json
#   3. the legacy name, src/modules.json (issue #305) — external module repos
#      that have not migrated keep working
#
# Echoes whichever exists, else the conventional path so callers can emit a
# clear "not found" message against a sensible name.
#
# Arguments: <repo-path> [declared-catalog-relative-path]
repo_catalog_file() {
    local repo_path="${1%/}"
    local declared="${2:-}"

    if [[ -n "${declared}" && -f "${repo_path}/${declared}" ]]; then
        echo "${repo_path}/${declared}"
    elif [[ -f "${repo_path}/src/module-catalog.json" ]]; then
        echo "${repo_path}/src/module-catalog.json"
    elif [[ -f "${repo_path}/src/modules.json" ]]; then
        echo "${repo_path}/src/modules.json"
    else
        echo "${repo_path}/src/module-catalog.json"
    fi
}

# Look a module up in one catalog file, by moduleName OR legacyName.
# Echoes "<moduleJson>\t<tier>" (tier defaulting to "app") and returns 0 on a
# hit; returns 1 with no output when the module is not in this catalog or the
# catalog is unreadable.
#
# Arguments: <catalog-file> <module-name>
repo_catalog_entry() {
    local catalog="$1" module="$2" entry

    [[ -f "${catalog}" ]] || return 1
    entry="$(jq -r --arg m "${module}" '
        (((.foundationModules // []) + (.applicationModules // []))
         | map(select(.moduleName == $m or .legacyName == $m))
         | .[0]) as $e
        | if $e == null then empty else "\($e.moduleJson)\t\($e.tier // "app")" end
      ' "${catalog}" 2>/dev/null || true)"
    [[ -n "${entry}" ]] || return 1
    printf '%s\n' "${entry}"
}

fi
