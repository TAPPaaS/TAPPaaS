#!/usr/bin/env bash
#
# test-node-placeholders.sh — unit test for update.sh's retire_node_placeholders (#673).
#
# The firewall's base config used to ship a dnsmasq entry for tappaas1-9 on every
# site; this retires the ones no node uses. The function is lifted out of
# update.sh with `dns-manager` stubbed, so the selection rule is tested without a
# firewall: only a tappaasN name that is NOT a cluster member is offered, and
# only `release --placeholder` decides whether it actually goes.
#
# Usage: ./test-node-placeholders.sh   (exit 0 = all passed)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/../update.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

FN="$(sed -n '/^retire_node_placeholders() {/,/^}/p' "${SRC}")"
[[ -n "${FN}" ]] || { echo "FAIL: retire_node_placeholders not found in ${SRC}"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/nodeph.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

# The entries a three-node site carries after an install that shipped nine: some
# untouched (no description), one left by a provisioning test ("TAPPaaS node …",
# tappaas9), plus a VM and the firewall (neither is a tappaasN name).
cat > "${TMP}/list" <<'LIST'
  firewall.mgmt.internal    -> 10.0.0.1   ()
  tappaas1.mgmt.internal    -> 10.0.0.10  (TAPPaaS node tappaas1)
  tappaas2.mgmt.internal    -> 10.0.0.11  (TAPPaaS node tappaas2)
  tappaas3.mgmt.internal    -> 10.0.0.12  (TAPPaaS node tappaas3)
  tappaas4.mgmt.internal    -> 10.0.0.13  ()
  tappaas5.mgmt.internal    -> 10.0.0.14  ()
  tappaas9.mgmt.internal    -> 10.0.0.18  (TAPPaaS node tappaas9)
  nextcloud.rossen.internal -> 10.2.0.50  (TAPPaaS VM)
LIST

run() {   # run <kept-name>… — every other release succeeds
    local kept="$*"
    bash -c '
        GN=""; CL=""
        info()  { echo "INFO:$*"; }
        warn()  { echo "WARN:$*"; }
        debug() { :; }
        '"${FN}"'
        # release <name> succeeds unless the name is in the "kept" set (the verb
        # refuses an entry with a MAC, a CNAME, or a description of its own).
        dns-manager() {
            shift
            if [[ "$1" == list ]]; then cat "'"${TMP}"'/list"; return 0; fi
            local name="$3"
            echo "release ${name}" >> "'"${TMP}"'/calls"
            case " '"${kept}"' " in
                *" ${name} "*) echo "${name}.mgmt.internal: kept — it is a DHCP reservation" ;;
                *)             echo "${name}.mgmt.internal: released" ;;
            esac
        }
        retire_node_placeholders mgmt tappaas1 tappaas2 tappaas3
    ' _ "${kept}" "${TMP}/calls"
}

: > "${TMP}/calls"
out="$(run tappaas4)"          # tappaas4 carries a MAC: the verb keeps it
calls="$(tr '\n' '|' < "${TMP}/calls" | sed 's/|$//')"

ck "only non-members are offered"        "release tappaas4|release tappaas5|release tappaas9" "${calls}"
ck "a released placeholder is reported"  "INFO:  ✓ tappaas5: unused placeholder entry retired" "$(grep 'tappaas5' <<< "${out}")"
ck "…and so is the other one"            "INFO:  ✓ tappaas9: unused placeholder entry retired" "$(grep 'tappaas9' <<< "${out}")"
ck "an entry the verb keeps is quiet"    ""                                                   "$(grep 'tappaas4' <<< "${out}")"
ck "a member is never offered"           ""                                                   "$(grep -E 'tappaas[123]' <<< "${calls}")"
ck "a non-node name is never offered"    ""                                                   "$(grep -E 'firewall|nextcloud' <<< "${calls}")"

echo ""
echo "node-placeholders: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
