#!/usr/bin/env bash
#
# ha-cpu-lib.sh — the CPU model an HA guest runs (haCpu, #827). Pure: every
# function reads the cluster's CPU inventory (config/cluster-cpu.json, written
# by `proxmox-controller cpu-inventory`) as an argument and prints an answer.
#
#   hacpu_level <inventory> <node>              the node's x86-64 level
#   hacpu_common <inventory> <node>...          the richest level all of them offer
#   hacpu_rank <inventory> <level>              how many flags the level requires
#   hacpu_matching <inventory> <level> <node>...  nodes offering at least <level>,
#                                               the named ones excluded
#   hacpu_alike <inventory> <a> <b>             rc 0 when a live move is safe BOTH
#                                               ways: then `host` is what they share
#
# Levels are Proxmox's x86-64-v* models, each a superset of the one below, so
# the common level of a set of nodes is the lowest of their levels — ranked by
# the number of flags each requires, never by name.

hacpu_level() {
    jq -r --arg n "$2" '.nodes[] | select(.node == $n) | .level // empty' <<< "$1"
}

hacpu_rank() {
    jq -r --arg l "$2" '.levels[$l] // empty' <<< "$1"
}

hacpu_common() {
    local inv="$1"; shift
    jq -r --args '
        . as $i
        | [ $ARGS.positional[] as $n | $i.nodes[] | select(.node == $n) | .level ] as $ls
        | if ($ls | length) != ($ARGS.positional | length)
             or any($ls[]; . == null or ($i.levels // {})[.] == null) then empty
          else $ls | min_by($i.levels[.]) end' "$@" <<< "${inv}"
}

hacpu_matching() {
    local inv="$1" level="$2"; shift 2
    jq -r --arg l "${level}" --args '
        . as $i | ($i.levels[$l] // 0) as $want
        | [ $i.nodes[] | select(.level != null and ($i.levels[.level] // 0) >= $want)
                       | .node | select(. as $x | $ARGS.positional | index($x) | not) ]
        | join(" ")' "$@" <<< "${inv}"
}

hacpu_alike() {
    jq -e --arg a "$2" --arg b "$3" '
        [ .matrix[]? | select((.from == $a and .to == $b) or (.from == $b and .to == $a)) | .liveSafe ]
        | length == 2 and all' <<< "$1" >/dev/null
}
