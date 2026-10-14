#!/usr/bin/env bash
# app-tile.sh — how a module looks on the identity start page (My applications).
#
#   app_tile_name <module> <json>   the module's displayName, else its name
#   app_tile_icon <module> <json>   what `--icon` gets: the site's own file
#                                   (config `icon`, relative to the config dir),
#                                   else icon.svg / icon.png in the module's
#                                   directory, else "auto" (a generated tile)
#
# <json> is the module's config, normalized flat. Needs common-install-routines
# (module_source_dir, warn).

app_tile_name() {
    jq -r --arg m "$1" '(.displayName // "") | if . == "" then $m else . end' <<< "$2"
}

app_tile_icon() {
    local module="$1" json="$2" f dir
    f="$(jq -r '.icon // empty' <<< "${json}")"
    if [[ -n "${f}" ]]; then
        [[ "${f}" == /* ]] || f="${CONFIG_DIR:-/home/tappaas/config}/${f}"
        if [[ -r "${f}" ]]; then printf '%s\n' "${f}"; return 0; fi
        warn "  icon ${f} not found — using the module's own" >&2
    fi
    dir="$(module_source_dir "${module}" 2>/dev/null)" || dir=""
    if [[ -n "${dir}" ]]; then
        for f in "${dir}/icon.svg" "${dir}/icon.png"; do
            if [[ -r "${f}" ]]; then printf '%s\n' "${f}"; return 0; fi
        done
    fi
    echo auto
}
