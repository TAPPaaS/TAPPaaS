#!/usr/bin/env bash
#
# test-foundation-placement.sh — Rest of foundation's proposal and its choices
# (lib/foundation-placement.sh), from facts as Proxmox reports them: lab2 as
# it was on 2026-11-03 (one machine, everything on the boot pool, tanka1 empty),
# and three machines with the WAN on the first and a tankc pool on the third.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOUNDATION="$(cd "${HERE}/../.." && pwd)"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/placement.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

# shellcheck source=../../cluster/lib/storage-placement.sh disable=SC1091
. "${FOUNDATION}/cluster/lib/storage-placement.sh"
# shellcheck source=foundation-placement.sh disable=SC1091
. "${HERE}/foundation-placement.sh"

export FP_SRC="${FOUNDATION}" FP_CONFIG_DIR="${TMP}/config"
mkdir -p "${FP_CONFIG_DIR}"
G=$((1024 ** 3))
store() { printf '{"name":"%s","type":"zfspool","images":true,"total":%d,"avail":%d}' "$1" "$(($2 * G))" "$(($3 * G))"; }

# ── lab2: one machine ────────────────────────────────────────────────
jq -n '{"node":null,"HANode":null,"storage":null,"dependsOn":["cluster:vm","cluster:ha","network:proxy"],"bridge0":"lan","bridge1":"wan"}' > "${FP_CONFIG_DIR}/network.json"
jq -n '{"node":null,"HANode":null,"storage":"local-zfs","dependsOn":["cluster:vm","cluster:ha"]}' > "${FP_CONFIG_DIR}/tappaas-cicd.json"
cat > "${TMP}/lab2.json" <<EOF
{ "nodes": [ { "name": "tappaas1", "memory": $((64 * G)), "boot": "local-zfs", "bridges": ["lan", "wan"],
  "storages": [ $(store local-zfs 444 424), $(store tanka1 1798 1798) ],
  "guests": [ {"name":"network","storage":"local-zfs"}, {"name":"tappaas-cicd","storage":"local-zfs"}, {"name":"tappaas-nixos","storage":"local-zfs"} ] } ] }
EOF
P="$(fp_proposal "$(cat "${TMP}/lab2.json")")"
row() { jq -r --arg m "$1" ".rows[] | select(.module == \$m) | $2" <<< "${P}"; }
ck "the machines in short: name, memory, pools" "tappaas1 64 local-zfs,tanka1" "$(jq -r '.nodes[0] | "\(.name) \(.memoryGiB) \(.pools | map(.name) | join(","))"' <<< "${P}")"
ck "…the boot pool marked" "local-zfs" "$(jq -r '.nodes[0].pools[] | select(.boot) | .name' <<< "${P}")"
ck "five rows, the installed two first" "network,tappaas-cicd,backup,identity,logging" "$(jq -r '[.rows[].module] | join(",")' <<< "${P}")"
ck "network is on the boot pool, and moves to tanka1" "local-zfs → tanka1" "$(row network '"\(.current.storage) → \(.proposal.storage)"')"
ck "…tappaas-cicd too, though its config records local-zfs" "local-zfs → tanka1" "$(row tappaas-cicd '"\(.current.storage) → \(.proposal.storage)"')"
ck "identity is installed onto tanka1, on tappaas1, no HA" "false tappaas1 tanka1 -" "$(row identity '"\(.installed) \(.proposal.node) \(.proposal.storage) \(if .proposal.ha == "" then "-" else .proposal.ha end)"')"
ck "one machine: no HA machine to choose" "" "$(row identity '.choices.tappaas1.ha | join(",")')"
ck "…and its pools are tanka1 then the boot pool" "tanka1,local-zfs" "$(row identity '.choices.tappaas1.pools[""] | join(",")')"
ck "no tankc pool: backup is a placeholder, and says so" "true" "$(row backup '.proposal.node == "" and (.note | test("placeholder"))')"
ck "a choice the row offers passes" "" "$(fp_check "${P}" identity tappaas1 "" local-zfs)"
ck "…a pool the machine lacks is refused" "identity: tankb1 is not a pool on tappaas1" "$(fp_check "${P}" identity tappaas1 "" tankb1)"
ck "…and a machine that is not one" "logging: tappaas9 is not a machine it can run on" "$(fp_check "${P}" logging tappaas9 "" tanka1)"

# ── three machines: WAN on the first, tankc on the third ─────────────
cat > "${TMP}/three.json" <<EOF
{ "nodes": [
  { "name": "tappaas1", "memory": $((64 * G)), "boot": "local-zfs", "bridges": ["lan", "wan"], "storages": [ $(store local-zfs 444 400), $(store tanka1 1798 1700) ],
    "guests": [ {"name":"network","storage":"tanka1"}, {"name":"tappaas-cicd","storage":"tanka1"} ] },
  { "name": "tappaas2", "memory": $((32 * G)), "boot": "local-zfs", "bridges": ["lan"], "storages": [ $(store local-zfs 444 400), $(store tanka1 900 900) ], "guests": [] },
  { "name": "tappaas3", "memory": $((16 * G)), "boot": "local-zfs", "bridges": ["lan"], "storages": [ $(store local-zfs 444 400), $(store tankc1 3600 3600) ], "guests": [] } ] }
EOF
P="$(fp_proposal "$(cat "${TMP}/three.json")")"
ck "network on a data pool stays where it is" "tappaas1 tanka1 → tappaas1 tanka1" "$(row network '"\(.current.node) \(.current.storage) → \(.proposal.node) \(.proposal.storage)"')"
ck "network needs the WAN bridge: only tappaas1, and no HA machine has it" "tappaas1 |" "$(row network '"\(.choices | keys | join(",")) |\(.choices.tappaas1.ha | join(","))"')"
ck "tappaas-cicd's HA machine: the first other with its pool" "tappaas2" "$(row tappaas-cicd '.proposal.ha')"
ck "…its HA choices leave out its own machine" "tappaas2,tappaas3" "$(row tappaas-cicd '.choices.tappaas1.ha | join(",")')"
ck "…with tappaas3 as HA, the pools both have" "local-zfs" "$(row tappaas-cicd '.choices.tappaas1.pools.tappaas3 | join(",")')"
ck "logging (no cluster:ha) offers no HA machine" "" "$(row logging '.choices.tappaas1.ha | join(",")')"
ck "backup goes to the machine with tankc1, not the mothership's" "tappaas3 tankc1" "$(row backup '"\(.proposal.node) \(.proposal.storage)"')"
ck "…and only machines with a tankc pool are offered" "tappaas3" "$(row backup '.choices | keys | join(",")')"
ck "an HA machine without the pool on both is refused" "tappaas-cicd: tanka1 is not a pool on tappaas1 and tappaas3" "$(fp_check "${P}" tappaas-cicd tappaas1 tappaas3 tanka1)"
ck "an HA machine without the bridges is refused" "network: tappaas2 cannot be its HA machine" "$(fp_check "${P}" network tappaas1 tappaas2 tanka1)"

# ── the facts, parsed from what a machine prints ─────────────────────
out='##storage
[{"storage":"local-zfs","type":"zfspool","content":"images,rootdir","active":1,"total":100,"avail":50},{"storage":"local","type":"dir","content":"iso,vztmpl","active":1,"total":10,"avail":5}]
##status
{"memory":{"total":68719476736}}
##boot
local-zfs
##bridges
lan
wan
##guests
network local-zfs
'
F="$(_fp_parse_node tappaas1 "${out}")"
ck "a machine's report parses: memory, boot pool, bridges, guests" "68719476736 local-zfs lan,wan network:local-zfs" "$(jq -r '"\(.memory) \(.boot) \(.bridges | join(",")) \(.guests | map("\(.name):\(.storage)") | join(","))"' <<< "${F}")"
ck "…a pool holds guests only with images in its content" "local-zfs:true,local:false" "$(jq -r '.storages | map("\(.name):\(.images)") | join(",")' <<< "${F}")"

echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
