#!/usr/bin/env bash
#
# module-sizing.sh — a guest's size from its site or environment (ADR-044, #917).
#
# A site and each environment are small, medium or large. A module states its
# cores / memory / diskSize for medium, and optionally a pair beside each:
# coresMinMax, memoryMinMax, diskMinMax = [min, max]. Small takes the min, large
# the max, medium the plain value; a field without a pair is the same at every
# size. The disk is the exception at large: it starts at medium and auto-grow
# takes it further as it fills, so a large site reserves nothing up front.
#
# Provides (sourceable; no side effects on source):
#   module_size_for <module-json> [environment] [config-dir]
#       -> small | medium | large. TAPPAAS_SIZE wins; a site-scoped module
#          (stack foundation) takes site.json .size; any other its environment's
#          .size, else the site's; nothing set: medium.
#   apply_module_size <size>
#       jq filter, stdin -> stdout: sets each sized field from its pair. Works on
#       the flat form and on Pattern A (config{} blocks) alike.
#   size_module_json_file <file> <size>
#       apply_module_size in place.

if [[ -z "${_MODULE_SIZING_LOADED:-}" ]]; then
_MODULE_SIZING_LOADED=1

# The jq program that sizes one object (flat fields). $size is bound by caller.
_module_sizing_jq='
  def sized($o):
    reduce (["cores","coresMinMax",true], ["memory","memoryMinMax",true], ["diskSize","diskMinMax",false]) as $p
      ($o;
       if ($size == "small" or ($size == "large" and $p[2]))
          and (.[$p[1]] | type) == "array" and (.[$p[1]] | length) == 2
       then .[$p[0]] = (if $size == "small" then .[$p[1]][0] else .[$p[1]][1] end)
       else . end);
  sized(.)
  | if (.config | type) == "object" then
      .config |= with_entries(if (.value | type) == "object" then .value |= sized(.) else . end)
    else . end
'

_module_sizing_valid() {
    case "$1" in small|medium|large) return 0 ;; *) return 1 ;; esac
}

module_size_for() {
    local json="${1:-}" env="${2:-}" dir="${3:-${CONFIG_DIR:-/home/tappaas/config}}"
    local s=""
    if [[ -n "${TAPPAAS_SIZE:-}" ]]; then
        if _module_sizing_valid "${TAPPAAS_SIZE}"; then printf '%s\n' "${TAPPAAS_SIZE}"; return 0; fi
        echo "[Warning] TAPPAAS_SIZE='${TAPPAAS_SIZE}' is not small, medium or large; ignored" >&2
    fi
    local site="${dir}/site.json" scope="environment"
    if [[ -n "${json}" && -f "${json}" ]]; then
        scope="$(jq -r 'if (.stack // "") == "foundation" then "site"
                        elif (.stack // "") != "" then "environment"
                        elif (.tier // "") == "foundation" then "site"
                        else "environment" end' "${json}" 2>/dev/null || echo environment)"
        [[ -n "${env}" ]] || env="$(jq -r '.environment // ""' "${json}" 2>/dev/null || true)"
    fi
    if [[ "${scope}" != "site" ]]; then
        if [[ -z "${env}" && -f "${site}" ]]; then
            env="$(jq -r '.defaultEnvironment // .name // ""' "${site}" 2>/dev/null || true)"
        fi
        if [[ -n "${env}" && -f "${dir}/environments/${env}.json" ]]; then
            s="$(jq -r '.size // ""' "${dir}/environments/${env}.json" 2>/dev/null || true)"
        fi
    fi
    if [[ -z "${s}" && -f "${site}" ]]; then
        s="$(jq -r '.size // ""' "${site}" 2>/dev/null || true)"
    fi
    _module_sizing_valid "${s}" || s="medium"
    printf '%s\n' "${s}"
}

apply_module_size() {
    local size="${1:-medium}"
    _module_sizing_valid "${size}" || size="medium"
    jq --arg size "${size}" "${_module_sizing_jq}"
}

size_module_json_file() {
    local f="$1" size="$2" tmp
    [[ -f "${f}" ]] || return 1
    [[ "${size}" == "medium" ]] && return 0
    tmp="$(mktemp)"
    if apply_module_size "${size}" < "${f}" > "${tmp}" && jq empty "${tmp}" 2>/dev/null; then
        mv "${tmp}" "${f}"
    else
        rm -f "${tmp}"
        return 1
    fi
}

fi
