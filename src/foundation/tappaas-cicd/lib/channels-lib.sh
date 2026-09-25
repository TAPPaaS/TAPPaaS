#!/usr/bin/env bash
# channels-lib.sh — which of a repository's branches realize which channel
# (ADR-028 D11).
#
# The mapping used to live in tappaas-train.sh as `unstable→main,
# staging→staging, production→stable`, which was only ever true of the TAPPaaS
# source. A site tracks several repositories; each names its own branches. So
# each repository declares the mapping itself, in `channels.json` at its root:
#
#     { "production": ["stable"], "staging": ["staging"], "unstable": ["main"] }
#
# Lists, because a repository may realize one channel from more than one branch;
# usually one entry each.
#
# TWO RULES, and both matter in the same direction:
#   - a branch listed in no channel is UNSTABLE, so an unrecognised branch is
#     never mistaken for production;
#   - a repository with no channels.json is not broken, it is undeclared —
#     every branch in it is unstable, and callers WARN rather than refuse,
#     because repositories older than this decision must keep working.
#
# Sourced, not executed. Needs jq.

# channels_file <repo_path> — the declaration, or empty when there is none.
channels_file() {
    local f="${1}/channels.json"
    [[ -r "${f}" ]] && printf '%s\n' "${f}"
}

# channels_declared <repo_path> — 0 when the repository declares its channels.
channels_declared() { [[ -n "$(channels_file "${1}")" ]]; }

# channel_branches <repo_path> <channel> — the branches that realize <channel>,
# one per line. Empty when undeclared, or when this repository has no branch for
# that channel at all (a module repo with no `stable`, say).
channel_branches() {
    local f; f="$(channels_file "${1}")" || return 0
    [[ -n "${f}" ]] || return 0
    jq -r --arg c "${2}" '(.[$c] // []) | .[]' "${f}" 2>/dev/null
}

# branch_channel <repo_path> <branch> — the channel a branch realizes.
# Prints `unstable` for anything not listed, which is the rule, not a guess.
# Prints nothing at all when the repository is undeclared, so a caller can tell
# "this branch is unstable" from "nobody said".
branch_channel() {
    local f; f="$(channels_file "${1}")" || return 0
    [[ -n "${f}" ]] || return 0
    jq -r --arg b "${2}" '
        [ to_entries[] | select(.key | startswith("_") | not)
          | select(.value | type == "array")
          | select(.value | index($b))
          | .key ] as $hit
        | if ($hit | length) > 0 then $hit[0] else "unstable" end' "${f}" 2>/dev/null
}

# channel_matches <repo_path> <branch> <channel> — 0 when the branch realizes
# the channel. An undeclared repository never matches: it cannot promise
# anything, which is what the warning is for.
channel_matches() {
    local got; got="$(branch_channel "${1}" "${2}")"
    [[ -n "${got}" && "${got}" == "${3}" ]]
}

# site_repos <site_json> — `name<TAB>branch<TAB>path` for each registered
# repository. Every caller iterates ALL of them: a site's channel is a claim
# about everything it tracks, not just the TAPPaaS source.
site_repos() {
    jq -r '(.repositories // [])[] | [.name, (.branch // ""), (.path // "")] | @tsv' \
        "${1}" 2>/dev/null
}
