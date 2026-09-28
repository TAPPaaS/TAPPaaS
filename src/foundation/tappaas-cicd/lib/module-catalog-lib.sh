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
#   repo_catalog_entry <catalog-file> <module>        -> "<moduleJson>\t<scope>"
#   module_scope_filter                               -> the jq filter for a module's scope
#   module_scope_of <module-json>                     -> site | environment

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

# A module's scope (ADR-022e v1.1): `site` — it belongs to the Site, serves
# every Environment and installs in mgmt — or `environment`. It is DERIVED, not
# stored: a module is site-scoped exactly when its stack is `foundation`, and
# becomes so by moving into that stack. Nothing else says it, so nothing else
# can disagree (#676 retired module.tier, which said the same thing twice).
#
# During the release that retires `tier`, a JSON with no `stack` falls back to
# it — a deployed config the merge has not yet given a stack, or a module from a
# repository whose module JSONs carry none. The fallback goes with the release
# after. `zone.tier` (ADR-014) is a different field and is untouched.
module_scope_filter() {
    printf '%s' 'if (.stack // "") == "foundation" then "site"
                 elif (.stack // "") != "" then "environment"
                 elif (.tier // "") == "foundation" then "site"
                 else "environment" end'
}

# Arguments: <module-json>. An unreadable file is environment-scoped: the
# narrower scope, which grants nothing a site-scoped module is allowed.
module_scope_of() {
    local s
    s="$(jq -r "$(module_scope_filter)" "$1" 2>/dev/null || true)"
    [[ "${s}" == "site" ]] && printf 'site\n' || printf 'environment\n'
}

# Look a module up in one catalog file, by moduleName OR legacyName.
# Echoes "<moduleJson>\t<scope>" and returns 0 on a hit; returns 1 with no output
# when the module is not in this catalog or the catalog is unreadable.
#
# Two catalog shapes are read (#463). The current one is a single `modules` list
# whose entries carry no tier: what a module IS comes from its `stack` —
# `foundation` is a foundation module, `template` and `test` are not modules to
# install at all (a template to copy, a fixture), anything else or nothing is an
# application module. The shape before it split the same entries across
# `foundationModules` / `applicationModules` (searched) and `proxmoxTemplates` /
# `testModules` (not), with `tier` repeated on each entry; catalogs in other
# repositories still have it. Its scope comes from the entry's `stack` like any
# other (being listed under foundationModules does not make a module site-scoped
# — moving into the foundation stack does), and from `tier` only when the entry
# has no stack, for the release that retires it (#676).
#
# Arguments: <catalog-file> <module-name>
repo_catalog_entry() {
    local catalog="$1" module="$2" entry

    [[ -f "${catalog}" ]] || return 1
    entry="$(jq -r --arg m "${module}" '
        if (.modules | type) == "array" then
            (.modules
             | map(select((.moduleName == $m or .legacyName == $m)
                          and ((.stack // "") as $s | $s != "template" and $s != "test")))
             | .[0]) as $e
            | if $e == null then empty
              else "\($e.moduleJson)\t\($e | '"$(module_scope_filter)"')" end
        else
            (((.foundationModules // []) + (.applicationModules // []))
             | map(select(.moduleName == $m or .legacyName == $m))
             | .[0]) as $e
            | if $e == null then empty else "\($e.moduleJson)\t\($e | '"$(module_scope_filter)"')" end
        end
      ' "${catalog}" 2>/dev/null || true)"
    [[ -n "${entry}" ]] || return 1
    printf '%s\n' "${entry}"
}

fi
