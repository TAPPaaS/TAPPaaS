# controller-lib.sh — how a manager finds and runs its controllers (ADR-035 D4, D5).
# Sourced, not run.
#
# A manager's controllers are the control plane's registry entries
# (config/control-plane.json) of kind controller that plug into it, each an
# executable answering the manager's contract (switch/1, ap/1). The built-in
# `manual` controller (controller-manual.sh, through controller-shim.sh) is the
# fallback: it prints what to set by hand.
#
#   ctl_list <manager>                  one controller id per line
#   ctl_describe <id>                   its describe (JSON)
#   ctl_for_vendor <manager> <vendor>   the id that drives <vendor>, or "manual"
#   ctl_vendors <manager>               the vendors its controllers drive
#   ctl_run <id> <verb> [options...]    run a verb (passes --config-dir)
#   ctl_label <id>                      a short name for messages
#
# An id is an executable's path, or "plugin:<file>" for a file of plugin_*
# functions run through the shim, or "manual". PLUGIN_DIR (tests) adds every
# *.sh there (but manual.sh) as a "plugin:" controller, before the registry's.

CTL_LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CTL_SHIM="${CTL_LIB_DIR}/controller-shim.sh"
CTL_MANUAL="${CTL_LIB_DIR}/controller-manual.sh"

ctl_registry() { printf '%s' "${CONTROL_PLANE_REGISTRY:-${CONFIG_DIR:-/home/tappaas/config}/control-plane.json}"; }

ctl_list() {
    local mgr="$1" f
    if [[ -n "${PLUGIN_DIR:-}" && -d "${PLUGIN_DIR}" ]]; then
        for f in "${PLUGIN_DIR}"/*.sh; do
            [[ -f "${f}" && "$(basename "${f}")" != manual.sh ]] && echo "plugin:${f}"
        done
    fi
    local reg; reg="$(ctl_registry)"
    [[ -r "${reg}" ]] || return 0
    jq -r --arg m "${mgr}" '.components[]? | select(.kind == "controller" and ((.plugsInto // []) | index($m)))
        | (.source + "/" + .name)' "${reg}" 2>/dev/null
}

ctl_run() {
    local id="$1"; shift
    local verb="$1"; shift
    local -a cfg=()
    [[ -n "${CONFIG_DIR:-}" ]] && cfg=(--config-dir "${CONFIG_DIR}")
    case "${id}" in
        manual)   bash "${CTL_SHIM}" --plugin "${CTL_MANUAL}" "${verb}" "${cfg[@]}" "$@" ;;
        plugin:*) bash "${CTL_SHIM}" --plugin "${id#plugin:}" "${verb}" "${cfg[@]}" "$@" ;;
        *)        "${id}" "${verb}" "${cfg[@]}" "$@" ;;
    esac
}

ctl_describe() { ctl_run "$1" describe 2>/dev/null || echo '{}'; }

ctl_for_vendor() {
    local mgr="$1" vendor="$2" id
    while IFS= read -r id; do
        [[ -n "${id}" ]] || continue
        if jq -e --arg v "${vendor}" '(.vendors // []) | index($v)' >/dev/null 2>&1 <<<"$(ctl_describe "${id}")" \
           || ctl_run "${id}" supports "${vendor}" >/dev/null 2>&1; then
            echo "${id}"; return 0
        fi
    done < <(ctl_list "${mgr}")
    echo manual
}

ctl_vendors() {
    local mgr="$1" id d
    while IFS= read -r id; do
        [[ -n "${id}" ]] || continue
        d="$(ctl_describe "${id}")"
        if [[ "$(jq -r '(.vendors // []) | length' <<<"${d}")" -gt 0 ]]; then
            jq -r '.vendors[]' <<<"${d}"
        elif [[ "${id}" == plugin:* ]]; then
            basename "${id#plugin:}" .sh
        fi
    done < <(ctl_list "${mgr}") | sort -u
}

ctl_label() {
    case "$1" in
        manual) echo manual ;;
        plugin:*) basename "${1#plugin:}" .sh ;;
        *) basename "$1" ;;
    esac
}
