# simulate-gate.sh — TAPPAAS_SIMULATE=1 (docs/plans/console-gui-pipeline.md §6
# layer B). Sourced by common-install-routines.sh, and by every bash that starts
# under the managers or under a script that sourced it: it exports itself as
# BASH_ENV, and lib/ts/src/exec.ts does the same, so a script is gated whether or
# not it sources the lib. Without TAPPAAS_SIMULATE=1 sourcing it does nothing.
#
# The bash half of lib/ts/src/exec.ts's gate: the same list
# (lib/simulate-mutators.txt) and the same matching. A script calls qm, ssh, sudo
# directly, there is no run helper to hook, so each listed command (and the four
# that wrap one) becomes a function here: a mutator logs `[simulate] <argv>` on
# stderr and returns 0 with empty stdout; anything else runs as `command`.
# tappaas_ssh_guest and run_with_dots go through them too. Exported, so a bash
# child inherits the gate. The file tools get a function too: one that would
# change a file under the config root or an operator dot file is logged and skipped, which leaves only a
# redirect, and that is tappaas_config_write in common-install-routines.sh.

[[ "${TAPPAAS_SIMULATE:-}" == "1" ]] || return 0

_tappaas_sim_list() {
    local d f
    d="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")"
    for f in "${d}/simulate-mutators.txt" /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/lib/simulate-mutators.txt; do
        f="${TAPPAAS_SIMULATE_MUTATORS:-${f}}"
        [[ -r "${f}" ]] && { sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "${f}"; return 0; }
    done
    return 1
}

# Does this command's first word and verb stand on the list?
_tappaas_sim_rule() {
    local bin="${1##*/}" verb="" sub="" w o rule_bin rule_verbs
    local -a opts=()
    shift
    if [[ "${bin}" == git ]]; then
        while (( $# )) && [[ "$1" == -* ]]; do
            case "$1" in -C|-c|--git-dir|--work-tree|--namespace) shift 2 || return 1 ;; *) shift ;; esac
        done
    fi
    for w in "$@"; do
        if [[ "${w}" == -* ]]; then opts+=("${w%%=*}")
        elif [[ -z "${verb}" ]]; then verb="${w}"
        elif [[ -z "${sub}" ]]; then sub="${w}"
        fi
    done
    while read -r rule_bin rule_verbs; do
        [[ "${rule_bin}" == "${bin}" ]] || continue
        [[ " ${rule_verbs} " == *" * "* ]] && return 0
        [[ -n "${verb}" && " ${rule_verbs} " == *" ${verb} "* ]] && return 0
        [[ -n "${sub}" && " ${rule_verbs} " == *" ${verb}:${sub} "* ]] && return 0
        for o in ${opts[@]+"${opts[@]}"}; do [[ " ${rule_verbs} " == *" ${o} "* ]] && return 0; done
    done <<<"${TAPPAAS_SIM_RULES}"
    return 1
}

# A shell string: every command in it, split at its separators, quotes gone.
_tappaas_sim_shell() {
    local s="$1" seg nl=$'\n' i
    local -a words
    s="${s//&&/${nl}}"; s="${s//||/${nl}}"; s="${s//\$(/${nl}}"
    for i in ';' '|' '&' '(' ')' '`'; do s="${s//"${i}"/${nl}}"; done
    s="${s//\'/ }"; s="${s//\"/ }"; s="${s//\\/ }"
    while IFS= read -r seg; do
        read -r -a words <<<"${seg}"
        (( ${#words[@]} )) || continue
        _tappaas_sim_words "${words[@]}" && return 0
    done <<<"${s}"
    return 1
}

# A script file on the other machine: the list cannot see into it, so it counts
# as a write, unless the command asks for the script's own dry run.
_tappaas_sim_remote_script() {
    local re1='(^|[[:space:];&|(])[^[:space:];&|()"'"'"']*\.sh([[:space:];&|)"'"'"']|$)' re2='[[:space:]]--(dry-run|check)([[:space:]"'"'"']|$)'
    [[ "$1" =~ ${re1} ]] && ! [[ "$1" =~ ${re2} ]]
}

# The command in an argv, behind what only wraps it (exec.ts wordsMatch).
_tappaas_sim_words() {
    local bin
    while (( $# )); do
        bin="${1##*/}"
        case "${1}" in
            [A-Za-z_]*=*) if [[ "${1%%=*}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then shift; continue; fi ;;
        esac
        case "${bin}" in
            then|do|if|elif|else|while|until|'!'|'{'|exec|nohup|command|time) shift ;;
            sudo|env)
                shift
                while (( $# )) && [[ "$1" == -* || ( "${bin}" == env && "$1" == *=* ) ]]; do
                    case "$1" in -u|-g) shift 2 || return 1 ;; *) shift ;; esac
                done
                [[ "${bin}" == sudo ]] && (( $# )) && _tappaas_sim_rule sudo "${1##*/}" && return 0 ;;
            timeout)
                shift
                while (( $# )) && [[ "$1" == -* ]]; do shift; done
                (( $# )) && shift ;;
            ssh)
                shift
                while (( $# )) && [[ "$1" == -* ]]; do
                    case "$1" in
                        -[bcDEeFIiJLlmOopQRSWw]) shift 2 || return 1 ;;
                        *) shift ;;
                    esac
                done
                (( $# )) || return 1
                shift
                _tappaas_sim_shell "$*" || _tappaas_sim_remote_script "$*"
                return ;;
            bash|sh)
                if [[ "${2:-}" =~ ^-[a-z]*c$ ]]; then shift 2; _tappaas_sim_shell "$*"; return; fi
                _tappaas_sim_rule "$@"
                return ;;
            *)
                _tappaas_sim_rule "$@"
                return ;;
        esac
    done
    return 1
}

# Log and skip a mutator; else run it. `ssh … bash -s` takes its script on stdin
# (a heredoc), so the script is read and judged as well, and handed on.
_tappaas_sim_run() {
    local body="" fed=0 re='(^|[[:space:]])(bash|sh)([[:space:]]+-[a-z]+)*[[:space:]]+-[a-z]*s([[:space:]]|$)'
    if [[ "$1" == ssh && "$*" =~ ${re} ]]; then body="$(cat)"; fed=1; fi
    if _tappaas_sim_words "$@" || { (( fed )) && _tappaas_sim_shell "${body}"; }; then
        echo "[simulate] $*" >&2
        return 0
    fi
    [[ "$1" == ssh ]] && _tappaas_sim_carry "$@" && set -- "${_TAPPAAS_SIM_ARGV[@]}"
    if (( fed )); then command "$@" <<<"${body}"; else command "$@"; fi
}

# The ssh that does run carries TAPPAAS_SIMULATE, for a script or manager at the
# other end. The remote shell still runs the command, as `ssh` would have: it may
# be dash, or csh on the firewall, and `env` could not start a `cd`.
_tappaas_sim_carry() {
    local -a head=("$1")
    shift
    while (( $# )) && [[ "$1" == -* ]]; do
        case "$1" in
            -[bcDEeFIiJLlmOopQRSWw]) head+=("$1" "${2:-}"); shift 2 || return 1 ;;
            *) head+=("$1"); shift ;;
        esac
    done
    (( $# >= 2 )) || return 1
    head+=("$1")
    shift
    local cmd="$*" q="'\\''"
    cmd="${cmd//\'/${q}}"
    # shellcheck disable=SC2016 # expanded at the other end
    _TAPPAAS_SIM_ARGV=("${head[@]}" "env TAPPAAS_SIMULATE=1 sh -c 'exec \"\${SHELL:-sh}\" -c \"\$0\"' '${cmd}'")
}

# mktemp next to a config file: the rename that would follow is held, so the
# scratch goes to the temp dir, and config/ stays as it was.
_tappaas_sim_mktemp() {
    local root="${TAPPAAS_CONFIG:-${CONFIG_DIR:-/home/tappaas/config}}" w
    root="${root%/}"
    for w in "$@"; do
        [[ "${w}" == "${root}/"* || "${w}" == /home/tappaas/config/* || "${w}" == /home/tappaas/.* ]] && { command mktemp; return; }
    done
    command mktemp "$@"
}

# A file tool: skipped, whole, when it would change something under the config
# root. cp, ln and install only write their last argument; sed only with -i; tee
# still passes its input on.
_tappaas_sim_file() {
    local bin="$1" root="${TAPPAAS_CONFIG:-${CONFIG_DIR:-/home/tappaas/config}}" w hit=""
    local -a targets
    shift
    root="${root%/}"
    case "${bin}" in
        cp|ln|install) targets=("${@: -1}") ;;
        *) targets=("$@") ;;
    esac
    if [[ "${bin}" != sed || " $* " == *" -i"* ]]; then
        for w in "${targets[@]}"; do
            [[ "${w}" == /* ]] || w="${PWD}/${w}"
            # A script may name the standard path outright, whatever the root is;
            # the operator's dot files are site state too (secrets, spools).
            if [[ "${w}" == "${root}" || "${w}" == "${root}/"* || "${w}" == /home/tappaas/config/* || "${w}" == /home/tappaas/.* ]]; then hit="${w}"; break; fi
        done
    fi
    if [[ -n "${hit}" ]]; then
        echo "[simulate] ${bin} $*" >&2
        [[ "${bin}" == tee ]] && cat
        return 0
    fi
    command "${bin}" "$@"
}

if [[ "$(type -t _tappaas_sim_run_active)" != "function" ]]; then
    export TAPPAAS_SIM_RULES
    # No list, no gate to trust: the script stops rather than runs unguarded.
    TAPPAAS_SIM_RULES="$(_tappaas_sim_list)" || { echo "[simulate] simulate-mutators.txt not found: refusing to run" >&2; exit 1; }
    export TAPPAAS_CMDB=off # lib/cmdb-report.sh sends nothing
    _tappaas_sim_run_active() { :; }
    for _sim_bin in $(awk '{print $1}' <<<"${TAPPAAS_SIM_RULES}" | sort -u) ssh sudo env timeout; do
        eval "${_sim_bin}() { _tappaas_sim_run ${_sim_bin} \"\$@\"; }"
        export -f "${_sim_bin}"
    done
    unset _sim_bin
    for _sim_bin in mv cp rm ln install touch tee truncate chmod chown mkdir sed; do
        eval "${_sim_bin}() { _tappaas_sim_file ${_sim_bin} \"\$@\"; }"
        export -f "${_sim_bin}"
    done
    unset _sim_bin
    export -f _tappaas_sim_list _tappaas_sim_rule _tappaas_sim_shell _tappaas_sim_words _tappaas_sim_run _tappaas_sim_run_active
    export -f _tappaas_sim_remote_script _tappaas_sim_carry _tappaas_sim_file
    mktemp() { _tappaas_sim_mktemp "$@"; }
    export -f mktemp _tappaas_sim_mktemp
    # Every bash from here on starts through this file, sourcing the lib or not.
    export BASH_ENV
    BASH_ENV="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
fi
