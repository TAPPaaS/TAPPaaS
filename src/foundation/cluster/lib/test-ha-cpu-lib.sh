#!/usr/bin/env bash
# Unit tests for ha-cpu-lib.sh (#827): which CPU model an HA guest runs.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ha-cpu-lib.sh
. "${HERE}/ha-cpu-lib.sh"
pass=0; fail=0
check() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $1 (got '$2', want '$3')"; fi; }

# hrossen's shape: two Zen 4/5 nodes at v4, a Zen 3 at v3.
INV='{"levels":{"x86-64-v2":5,"x86-64-v2-AES":6,"x86-64-v3":15,"x86-64-v4":20},
      "nodes":[{"node":"tappaas1","level":"x86-64-v4"},{"node":"tappaas3","level":"x86-64-v3"},
               {"node":"tappaas2","level":"x86-64-v4"},{"node":"odd","level":null}]}'

check "a node's level"                 "$(hacpu_level "${INV}" tappaas3)"            "x86-64-v3"
check "the pair 1+3 shares v3"          "$(hacpu_common "${INV}" tappaas1 tappaas3)"  "x86-64-v3"
check "the pair 1+2 keeps v4"           "$(hacpu_common "${INV}" tappaas1 tappaas2)"  "x86-64-v4"
check "order does not matter"           "$(hacpu_common "${INV}" tappaas3 tappaas1)"  "x86-64-v3"
check "an unknown node: no answer"      "$(hacpu_common "${INV}" tappaas1 nosuch)"    ""
check "a node without a level: none"    "$(hacpu_common "${INV}" tappaas1 odd)"       ""
check "no level ranks (an old inventory): no answer, never a guess" \
      "$(hacpu_common "$(jq 'del(.levels)' <<< "${INV}")" tappaas1 tappaas3)" ""
check "ranked by flags, not by name"    "$(hacpu_rank "${INV}" x86-64-v2-AES)"        "6"
check "nodes keeping v4, pair excluded" "$(hacpu_matching "${INV}" x86-64-v4 tappaas1 tappaas3)" "tappaas2"
check "nodes keeping v3"                "$(hacpu_matching "${INV}" x86-64-v3 tappaas1)" "tappaas3 tappaas2"

echo "Results: ${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]]
