#!/usr/bin/env bash
# lib/cli-gate.sh — the argument gate for TAPPaaS bash CLIs (#644).
#
# A CLI calls cli_gate before it dispatches, and before anything that needs a
# live system (zones.json, state files):
#
#   cli_gate usage "${CLI_SPEC}" "$@"
#
# - -h/--help in ANY position prints that verb's usage and exits 0. After a
#   verb, a help request used to fall into the verb's own parsing and the verb
#   ran: `switch-controller remove-switch s1 --help` removed s1.
# - An option the verb does not take exits 1 before anything runs.
# - An unknown verb returns 0; the CLI reports it as before.
#
# CLI_SPEC lists what each verb accepts, one verb per line:
#
#   <verb words>: <option> <option>= ...
#
# An option ending in '=' takes a value. '*' in the verb words matches any one
# positional (`ssid * add` matches `ssid ap1 add`); the longest match wins. A
# line whose verb is '*' lists options every verb accepts.
#
# Per-verb help is cut from the CLI's own usage text: the lines whose first
# word (after an optional program name) is the verb's first word, with their
# deeper-indented continuation lines. Words that match no usage line print the
# whole usage. The usage function is called with the verb's leading words, so
# a CLI with a sub-help (`admin <sub>`) can print that instead.

_cli_is_option() {
    [[ "$1" == -?* && ! "$1" =~ ^-[0-9] ]]
}

_cli_verb_usage() {
    local usage_fn="$1" a part
    shift
    local -a words=()
    for a in "$@"; do
        [[ "${a}" == "-h" || "${a}" == "--help" ]] && continue
        _cli_is_option "${a}" && break
        words+=("${a}")
    done
    local verb="${words[0]:-}" text
    text="$("${usage_fn}" "${words[@]}")"
    part=""
    if [[ -n "${verb}" ]]; then
        part="$(awk -v v="${verb}" -v p="${0##*/}" '
            BEGIN { keep = -1 }
            { match($0, /^ */); ind = RLENGTH; n = split($0, f, " "); w = (n > 1 && f[1] == p) ? f[2] : f[1] }
            n > 0 && w == v { keep = ind; print; next }
            keep >= 0 && n > 0 && ind > keep { print; next }
            { keep = -1 }
        ' <<<"${text}")"
    fi
    if [[ -n "${part}" ]]; then
        printf '%s %s — usage:\n%s\n' "${0##*/}" "${verb}" "${part}"
    else
        printf '%s\n' "${text}"
    fi
}

cli_gate() {
    local usage_fn="$1" spec="$2"
    shift 2
    local -a args=("$@")
    local a line words opts global="" best_opts="" best_len=0 i ok
    local -a w

    for a in "${args[@]}"; do
        if [[ "${a}" == "-h" || "${a}" == "--help" ]]; then
            _cli_verb_usage "${usage_fn}" "${args[@]}"
            exit 0
        fi
    done

    while IFS= read -r line; do
        [[ "${line}" == *:* ]] || continue
        words="${line%%:*}"
        opts="${line#*:}"
        read -ra w <<<"${words}"
        [[ ${#w[@]} -gt 0 ]] || continue
        if [[ "${w[*]}" == "*" ]]; then
            global="${opts}"
            continue
        fi
        [[ ${#w[@]} -le ${#args[@]} ]] || continue
        ok=1
        for ((i = 0; i < ${#w[@]}; i++)); do
            if _cli_is_option "${args[i]}" || [[ "${w[i]}" != "*" && "${w[i]}" != "${args[i]}" ]]; then
                ok=0
                break
            fi
        done
        if [[ ${ok} -eq 1 && ${#w[@]} -gt ${best_len} ]]; then
            best_len=${#w[@]}
            best_opts="${opts}"
        fi
    done <<<"${spec}"
    [[ ${best_len} -gt 0 ]] || return 0

    local accepted=" ${best_opts} ${global} "
    for ((i = best_len; i < ${#args[@]}; i++)); do
        a="${args[i]}"
        _cli_is_option "${a}" || continue
        if [[ "${accepted}" == *" ${a}= "* ]]; then
            i=$((i + 1))
        elif [[ "${accepted}" != *" ${a} "* ]]; then
            printf '[Error] %s %s: unknown option %s (see %s %s --help)\n' \
                "${0##*/}" "${args[*]:0:best_len}" "${a}" "${0##*/}" "${args[*]:0:best_len}" >&2
            exit 1
        fi
    done
    return 0
}
