#!/usr/bin/env bash
# Unit tests for disk-grow-lib.sh (#100): when a disk grows, by how much, and
# whether its pool has room. Pure — no cluster, no guest.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=disk-grow-lib.sh
. "${HERE}/disk-grow-lib.sh"

pass=0; fail=0
check() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $1 (got '$2', want '$3')"; fi; }
decide() { local out rc=0; out="$(dg_decide "$@")" || rc=$?; echo "${out}/${rc}"; }
room() { local out rc=0; out="$(dg_pool_room "$@")" || rc=$?; echo "${out}/${rc}"; }

check "24G is 24"            "$(dg_size_gb 24G)"  24
check "2T is 2048"           "$(dg_size_gb 2T)"   2048
check "512M rounds up to 1"  "$(dg_size_gb 512M)" 1
check "a bare number is GB"  "$(dg_size_gb 30)"   30
check "garbage is refused"   "$(dg_size_gb abc || echo no)" no

check "under the threshold: no grow"       "$(decide 79 24 80 50 5 0)"  "/1"
check "at the threshold: +50%"             "$(decide 80 24 80 50 5 0)"  "36/0"
check "small disk: at least min"           "$(decide 90 8 80 50 5 0)"   "13/0"
check "odd size rounds the step up"        "$(decide 95 25 80 50 5 0)"  "38/0"
check "capped at diskSizeMax"              "$(decide 95 100 80 50 5 120)" "120/0"
check "already at the cap: rc 2"           "$(decide 95 120 80 50 5 120)" "120/2"
check "over the cap already: rc 2"         "$(decide 95 150 80 50 5 120)" "150/2"

K=1048576   # KiB per GiB
check "room: 10G into a 100G pool at 50%"  "$(room $((100*K)) $((50*K)) $((50*K)) 10 80)" "60/0"
check "ceiling: would end at 85%"          "$(room $((100*K)) $((75*K)) $((25*K)) 10 80)" "85/1"
check "exactly at the ceiling is allowed"  "$(room $((100*K)) $((70*K)) $((30*K)) 10 80)" "80/0"
check "free space, not the ceiling, binds" "$(room $((100*K)) $((10*K)) $((5*K))  10 80)" "20/1"
check "an empty report has no room"        "$(room 0 0 0 10 80)" "100/1"

echo "Results: ${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]]
