#!/usr/bin/env bash
# test-rename-instance.sh — `module modify <instance> --set instance=<new>` (#566).
#
# The instance name is the config file's (ADR-026 D6.1) and the module is named
# by .moduleSource (D6.2), so a rename moves config files and repoints what named
# the instance — and touches nothing on the guest. Uses THIS tree's script.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
RI="${CICD}/manager/module-manager/rename-instance.sh"
pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/rename.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

MOD="${TMP}/src/apps/hass"; CFG="${TMP}/config"
mkdir -p "${MOD}" "${CFG}"
echo '{"description":"hass"}' > "${MOD}/hass.json"
fixture() {
    rm -rf "${CFG:?}"/*.json*
    # A legacy, unsuffixed name for an instance of hass in environment delbuschy.
    cat > "${CFG}/hassanova.json" <<JSON
{"kind":"vm","vmname":"hassanova","vmid":231,"environment":"delbuschy","moduleSource":"${MOD}"}
JSON
    cp "${CFG}/hassanova.json" "${CFG}/hassanova.json.orig"
    echo '{"note":"meta"}' > "${CFG}/hassanova.meta.json"
    # A machine, and something naming the instance as its Host (the safety net:
    # a Host is normally a machine, and a machine is refused below).
    echo "{\"kind\":\"machine\",\"address\":\"10.0.0.90\",\"moduleSource\":\"${TMP}/src/foundation/debianhost\"}" > "${CFG}/dh1.json"
    echo '{"placementState":"node","node":"hassanova"}' > "${CFG}/backup.json"
}
run() { CONFIG_DIR="${CFG}" bash "${RI}" "$@" >"${TMP}/out" 2>&1; echo $?; }

fixture
ck "--dry-run exits 0"                     0 "$(run hassanova hass-delbuschy --dry-run)"
ck "…and renames nothing"                  "yes no" "$([[ -f "${CFG}/hassanova.json" ]] && echo yes || echo no) $([[ -f "${CFG}/hass-delbuschy.json" ]] && echo yes || echo no)"

ck "the rename exits 0"                    0 "$(run hassanova hass-delbuschy)"
ck "…the config is the new name"           "no yes" "$([[ -f "${CFG}/hassanova.json" ]] && echo yes || echo no) $([[ -f "${CFG}/hass-delbuschy.json" ]] && echo yes || echo no)"
ck "…the merge baseline follows"           "yes" "$([[ -f "${CFG}/hass-delbuschy.json.orig" ]] && echo yes || echo no)"
ck "…and the meta file"                    "yes" "$([[ -f "${CFG}/hass-delbuschy.meta.json" ]] && echo yes || echo no)"
ck "…the module is unchanged"              "${MOD}" "$(jq -r .moduleSource "${CFG}/hass-delbuschy.json")"
ck "…the guest keeps its own name"         "hassanova 231" "$(jq -r '"\(.vmname) \(.vmid)"' "${CFG}/hass-delbuschy.json")"
ck "…and is said to keep it"               "yes" "$(grep -q 'still' "${TMP}/out" && echo yes || echo no)"
ck "…what named the instance follows it"   "hass-delbuschy" "$(jq -r .node "${CFG}/backup.json")"

fixture
ck "a name already in use is refused"      1 "$(run hassanova backup)"
ck "…nothing moved"                        "yes" "$([[ -f "${CFG}/hassanova.json" ]] && echo yes || echo no)"
ck "a name that is not a DNS label is refused" 1 "$(run hassanova Hass_Delbuschy)"
ck "a reserved name is refused"            1 "$(run hassanova site)"
ck "the same name is refused"              1 "$(run hassanova hassanova)"
ck "an instance that is not installed is refused" 1 "$(run ghost other)"
ck "a machine is refused"                  1 "$(run dh1 dh-test1)"
ck "…naming what to do instead"            "yes" "$(grep -q 'adopt' "${TMP}/out" && echo yes || echo no)"
ck "…and nothing moved"                    "yes" "$([[ -f "${CFG}/dh1.json" ]] && echo yes || echo no)"

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
