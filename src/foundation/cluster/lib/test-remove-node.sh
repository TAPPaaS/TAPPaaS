#!/usr/bin/env bash
#
# test-remove-node.sh — the decisions behind `site-manager node delete` (#417):
# what blocks a removal, what happens to the storage entries, and what --erase
# runs on the node. Pure: canned pvesh JSON, no cluster.
#
# Usage: ./test-remove-node.sh   (exit 0 = all passed)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=remove-node-lib.sh disable=SC1091
. "${HERE}/remove-node-lib.sh"
PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }

RES='[{"vmid":130,"name":"tappaas-cicd","node":"tappaas1","type":"qemu"},
      {"vmid":342,"name":"nextcloud-hpb","node":"tappaas2","type":"qemu"},
      {"vmid":312,"name":"vllm-amd","node":"tappaas2","type":"lxc"}]'
ck "guests: the node's VMs and containers, by vmid" $'312 vllm-amd lxc\n342 nextcloud-hpb qemu' "$(rmn_guests_on tappaas2 "$RES")"
ck "guests: none on an empty node" "" "$(rmn_guests_on tappaas4 "$RES")"

REPL='[{"id":"110-0","source":"tappaas1","target":"tappaas3"},{"id":"911-0","source":"tappaas2","target":"tappaas3"}]'
ck "replication: a job FROM the node"  "911-0 tappaas2->tappaas3" "$(rmn_replication_touching tappaas2 "$REPL")"
ck "replication: a job TO the node"    $'110-0 tappaas1->tappaas3\n911-0 tappaas2->tappaas3' "$(rmn_replication_touching tappaas3 "$REPL")"
ck "replication: none"                 "" "$(rmn_replication_touching tappaas1x "$REPL")"

RULES='[{"rule":"ha-tappaas-cicd","nodes":"tappaas1:2,tappaas3:1"},{"rule":"ha-network","nodes":"tappaas1,tappaas3"},{"rule":"x","nodes":null}]'
ck "ha rules: a priority-suffixed node is found" $'ha-network tappaas1,tappaas3\nha-tappaas-cicd tappaas1:2,tappaas3:1' "$(rmn_ha_rules_naming tappaas3 "$RULES")"
ck "ha rules: a prefix is not a match (tappaas1 vs tappaas11)" "" "$(rmn_ha_rules_naming tappaas11 "$RULES")"

STOR='[{"storage":"tappaas_backup","nodes":null},{"storage":"tanka1","nodes":"tappaas1,tappaas3,tappaas2"},
       {"storage":"tankc1","nodes":"tappaas3"},{"storage":"tankb1","nodes":"tappaas1"}]'
ck "storage: taken out of a shared entry, the only node's entry removed" \
   $'remove tankc1\nset tanka1 tappaas1,tappaas2' "$(rmn_storage_changes tappaas3 "$STOR")"
ck "storage: an unrestricted entry is left alone" "" "$(rmn_storage_changes tappaas9 "$STOR")"

D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
echo '{"vmid":342}' > "$D/nextcloud-hpb.json"; echo '{"name":"x"}' > "$D/site.json"
ck "module of a vmid"        "nextcloud-hpb" "$(rmn_module_of_vmid 342 "$D")"
ck "a vmid no module claims" ""              "$(rmn_module_of_vmid 999 "$D")"

rmn_pbs_on tappaas3 '{"placementState":"node","node":"tappaas3"}' && r=0 || r=1; ck "pbs: placed on the node" 0 "$r"
rmn_pbs_on tappaas3 '{"placementState":"node:tappaas3"}'          && r=0 || r=1; ck "pbs: the pre-#600 form" 0 "$r"
rmn_pbs_on tappaas2 '{"placementState":"node","node":"tappaas3"}' && r=0 || r=1; ck "pbs: elsewhere" 1 "$r"

E="$(rmn_erase_script)"
for want in 'zpool destroy -f' 'wipefs -af' 'sgdisk --zap-all' 'findmnt -no SOURCE "$m"' 'efibootmgr -q -b "$cur" -B' 'echo ERASED' 'sysrq-trigger'; do
    grep -qF -- "$want" <<<"$E" && r=yes || r=no
    ck "erase script: ${want}" yes "$r"
done
ck "erase script: the boot disk is found from / and /boot/efi" yes "$(grep -q 'for m in / /boot/efi' <<<"$E" && echo yes || echo no)"
ck "erase script: is valid sh" 0 "$(bash -n <<<"$E" && echo 0 || echo 1)"
ck "remove-node: the erase needs ERASE typed, after the node name" yes \
   "$(grep -q 'Type ERASE to wipe' "${HERE}/../remove-node.sh" && grep -q 'Type the node name to confirm' "${HERE}/../remove-node.sh" && echo yes || echo no)"
ck "remove-node: nothing runs while anything blocks" yes \
   "$(grep -q 'thing(s) stop the removal — nothing was changed' "${HERE}/../remove-node.sh" && echo yes || echo no)"

echo "── remove-node: ${PASS} passed, ${FAIL} failed ──"
[[ "$FAIL" -eq 0 ]]
