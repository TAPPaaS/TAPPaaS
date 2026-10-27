#!/usr/bin/env bash
# Unit tests for ha-bridge-lib.sh (#836): can a node carry an HA guest's network.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ha-bridge-lib.sh
. "${HERE}/ha-bridge-lib.sh"
pass=0; fail=0
check() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $1 (got '$2', want '$3')"; fi; }

# A site whose tappaas2 was added with --no-wan, and a tappaas4 that is down.
fake_bridges() {
    case "$1" in
        tappaas1|tappaas3) printf 'wan\nlan\n' ;;
        tappaas2) printf 'lan\n' ;;
        *) return 1 ;;
    esac
}
# shellcheck disable=SC2034  # read by the sourced lib
HABR_NODE_BRIDGES_CMD=fake_bridges
get_all_node_hostnames() { printf 'tappaas1\ntappaas2\ntappaas3\ntappaas4\n'; }

declare -A CFG=()
get_config_value() { local v="${CFG[$1]:-}"; printf '%s' "${v:-$2}"; }

CFG=([bridge0]=lan [bridge1]=wan)
check "the firewall's bridges"         "$(habr_guest_bridges | paste -sd, -)"   "lan,wan"
CFG=([bridge0]=lan [bridge1]=NONE)
check "one NIC: one bridge"            "$(habr_guest_bridges | paste -sd, -)"   "lan"
CFG=()
check "nothing declared: lan"          "$(habr_guest_bridges | paste -sd, -)"   "lan"

check "a --no-wan node lacks wan"      "$(habr_missing tappaas2 lan wan)"       "wan"
check "a full node lacks nothing"      "$(habr_missing tappaas3 lan wan)"       ""
habr_missing tappaas4 lan >/dev/null && r=answered || r=unknown
check "a node that does not answer is unknown, never 'lacks nothing'" "${r}" "unknown"

check "the first capable failover skips the --no-wan node" "$(habr_first_capable tappaas1 lan wan)" "tappaas3"
check "a lan-only guest takes the first other node"        "$(habr_first_capable tappaas1 lan)"     "tappaas2"
check "nobody else has it: none"       "$(habr_first_capable tappaas1 lan wan dmzbr)" ""

# The guest's storage (ADR-037 D1): a one-disk node has local-zfs only, and
# replication needs the same storage on the failover node.
fake_storages() {
    case "$1" in
        tappaas2) printf 'local\nlocal-zfs\n' ;;
        tappaas1|tappaas3) printf 'local\ntanka1\ntankb1\n' ;;
        *) return 1 ;;
    esac
}
# shellcheck disable=SC2034  # read by the sourced lib
HABR_NODE_STORAGE_CMD=fake_storages
habr_has_storage tappaas3 tanka1; check "a node with the storage has it" "$?" "0"
habr_has_storage tappaas2 tanka1; check "a one-disk node has no tanka1" "$?" "1"
HABR_STORAGE=tanka1
check "a tanka1 guest skips the one-disk node" "$(habr_first_capable tappaas1 lan)" "tappaas3"
HABR_STORAGE=local-zfs
check "a local-zfs guest fails over only to a node with local-zfs" "$(habr_first_capable tappaas3 lan)" "tappaas2"
HABR_STORAGE=fastpool
check "nobody has the storage: none" "$(habr_first_capable tappaas1 lan)" ""
unset HABR_STORAGE
check "without HABR_STORAGE: bridges only, as before" "$(habr_first_capable tappaas1 lan)" "tappaas2"

echo "Results: ${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]]
