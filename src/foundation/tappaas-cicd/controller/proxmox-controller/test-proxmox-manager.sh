#!/usr/bin/env bash
#
# Unit tests for proxmox-manager — the Proxmox network provider (ADR-008, #335).
#
# Offline / pure-function tests: no cluster access. Sources proxmox-manager
# (guarded so main() does not run) and exercises the helpers that only need
# zones.json (_norm, _desired_bridge_vids), plus black-box CLI checks.
#
# Usage: ./test-proxmox-manager.sh
# Exit: 0 all passed, 1 otherwise.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PM="${SCRIPT_DIR}/proxmox-controller"

# Use a self-contained fixture zones.json so the test is independent of live
# operator state.
TMP_ZONES="$(mktemp)"
cat > "${TMP_ZONES}" <<'JSON'
{
  "_README":  { "note": "doc block, no vlantag" },
  "mgmt":     { "state": "Manual",    "vlantag": 0,   "bridge": "lan" },
  "srv":      { "state": "Active",    "vlantag": 200, "bridge": "lan" },
  "home":     { "state": "Active",    "vlantag": 310, "bridge": "lan" },
  "dmz":      { "state": "Mandatory", "vlantag": 610, "bridge": "lan" },
  "old":      { "state": "Inactive",  "vlantag": 999, "bridge": "lan" }
}
JSON
# proxmox-manager reads ${CONFIG_DIR}/zones.json — point CONFIG_DIR at a temp dir.
TMP_CFG="$(mktemp -d)"
cp "${TMP_ZONES}" "${TMP_CFG}/zones.json"
export CONFIG_DIR="${TMP_CFG}"
trap 'rm -rf "${TMP_ZONES}" "${TMP_CFG}"' EXIT

PASS=0
FAIL=0
ck() {
    local desc="$1" exp="$2" got="$3"
    if [[ "${exp}" == "${got}" ]]; then
        echo "  ok: ${desc}"; PASS=$((PASS + 1))
    else
        echo "  FAIL: ${desc} (expected '${exp}', got '${got}')"; FAIL=$((FAIL + 1))
    fi
}
ck_rc() {
    local desc="$1" exp="$2" got="$3"
    ck "${desc} (rc)" "${exp}" "${got}"
}

echo "test-proxmox-manager: sourcing helpers"
# shellcheck source=proxmox-controller disable=SC1091
. "${PM}"   # guarded main() will not run
set +e      # proxmox-manager's `set -e` leaks in via source; we test exit codes

# ── _norm: sort ';'-list numerically, drop blanks ───────────────────
ck "_norm sorts numerically"        "200;210;610"     "$(_norm '610;200;210')"
ck "_norm drops blanks"             "200;310"         "$(_norm ';200;;310;')"
ck "_norm empty stays empty"        ""                "$(_norm '')"

# ── _desired_bridge_vids: active tags only (Active+Mandatory, tag>0) ─
# srv(200) home(310) dmz(610) are active; mgmt(0) excluded, old(Inactive) excluded.
ck "_desired_bridge_vids = active set" "200 310 610"  "$(_desired_bridge_vids)"

# ── Black-box CLI checks ────────────────────────────────────────────
"${PM}" --help >/dev/null 2>&1; ck_rc "--help exits 0" "0" "$?"
"${PM}" >/dev/null 2>&1;        ck_rc "no args exits 0 (usage)" "0" "$?"
"${PM}" bogus-cmd >/dev/null 2>&1; ck_rc "unknown command exits non-zero" "1" "$?"
"${PM}" show no-such-module >/dev/null 2>&1; ck_rc "show missing module exits non-zero" "1" "$?"
# #644: per-verb help, before the zones.json check; per-verb options
CONFIG_DIR=/nonexistent "${PM}" trunks --apply --help >/dev/null 2>&1; ck_rc "trunks --apply --help exits 0 without zones.json" "0" "$?"
ck "live-ok --help prints live-ok's usage" "yes" "$(grep -q 'live-ok <vmname> <node>' <<<"$("${PM}" live-ok --help)" && echo yes || echo no)"
"${PM}" show some-vm --apply >/dev/null 2>&1; ck_rc "show --apply is refused" "1" "$?"

# ── live-migration compatibility (ADR-019) ──────────────────────────
#
# The verdict behind `live-ok`. Everything here is pure: canned QMP output and
# canned feature lists, no cluster. The live plumbing (which node, whose QMP
# socket) is exercised by the deep tier.
_W="$(mktemp -d)"
trap 'rm -rf "${_W}"' EXIT

# An expansion reports every feature as a boolean; only the true ones are given
# to the guest.
echo '{"return":{"model":{"props":{"avx512f":true,"gfni":false,"aes":true}}}}' > "${_W}/q"
ck "expansion keeps only the features the guest gets" \
   "aes avx512f " "$(cpu_features_from_qmp < "${_W}/q" | tr '\n' ' ')"

printf 'aes\navx512f\ngfni\n' > "${_W}/src"; printf 'aes\n' > "${_W}/dst"
ck "missing = what the source has and the destination does not" \
   "avx512f gfni " "$(cpu_missing "${_W}/src" "${_W}/dst" | tr '\n' ' ')"

# The distinction the whole verdict turns on: a guest EXECUTES an instruction
# set and takes SIGILL without it; it merely READS a mitigation bit.
printf 'avx512f\nverw-clear\nv-vmsave-vmload\ngfni\n' > "${_W}/m"
cpu_classify_missing "${_W}/m" "${_W}/hard" "${_W}/soft"
ck "losing an instruction set disqualifies live migration" \
   "avx512f gfni " "$(tr '\n' ' ' < "${_W}/hard")"
ck "losing a mitigation/virt-control bit is advisory only" \
   "verw-clear v-vmsave-vmload " "$(tr '\n' ' ' < "${_W}/soft")"

# The advisory list is a short allow-list, so anything unrecognised must land on
# the refusing side. A new CPU feature must not become silently migratable.
printf 'some-future-isa\n' > "${_W}/m2"
cpu_classify_missing "${_W}/m2" "${_W}/hard2" "${_W}/soft2"
ck "an unrecognised feature fails CLOSED (refuses, not allows)" \
   "some-future-isa " "$(tr '\n' ' ' < "${_W}/hard2")"

# Local disks with snapshots cannot move live (#825). Canned `pvesh get
# /nodes/<src>/qemu/<vmid>/migrate` output, trimmed to the fields that matter.
cat > "${_W}/pre" <<'J'
{"local_disks":[
 {"drivename":"efidisk0","cdrom":0,"is_cloudinit":0,"shared":0,"replicate":1,"referenced_in_snapshot":{"tappaas-1":1}},
 {"drivename":"scsi0","cdrom":0,"is_cloudinit":0,"shared":0,"replicate":1,"referenced_in_snapshot":{"tappaas-1":1}},
 {"drivename":"scsi1","cdrom":1,"is_cloudinit":1,"shared":0,"replicate":1,"referenced_in_snapshot":{"tappaas-1":1}},
 {"drivename":"scsi2","cdrom":0,"is_cloudinit":0,"shared":0,"replicate":1}]}
J
ck "a local disk with snapshots blocks a live migrate; cloud-init and snapshot-free disks do not" \
   "efidisk0 scsi0 " "$(storage_live_blockers tappaas2 343 < "${_W}/pre" 3<<< '[]' | tr '\n' ' ')"
ck "a replication job to the target lifts the block" \
   "" "$(storage_live_blockers tappaas2 343 < "${_W}/pre" 3<<< '[{"guest":"343","target":"tappaas2"}]' | tr '\n' ' ')"
ck "a replication job to ANOTHER node does not" \
   "efidisk0 scsi0 " "$(storage_live_blockers tappaas2 343 < "${_W}/pre" 3<<< '[{"guest":"343","target":"tappaas3"}]' | tr '\n' ' ')"
ck "a disabled replication job does not" \
   "efidisk0 scsi0 " "$(storage_live_blockers tappaas2 343 < "${_W}/pre" 3<<< '[{"guest":"343","target":"tappaas2","disable":1}]' | tr '\n' ' ')"
ck "a VM without snapshots is not blocked" \
   "" "$(storage_live_blockers tappaas2 343 <<< '{"local_disks":[{"drivename":"scsi0","cdrom":0,"is_cloudinit":0,"shared":0}]}' 3<<< '[]' | tr '\n' ' ')"


# ── CPU inventory (#827) ────────────────────────────────────────────
# Pure: canned probe output in, set arithmetic out. The live probe is the
# deep tier's.
V3='aes popcnt pni sse4.1 sse4.2 ssse3 avx avx2 bmi1 bmi2 f16c fma abm movbe xsave'
V4="${V3} avx512f avx512bw avx512cd avx512dq avx512vl"
probe() {  # probe <vendor> <cpu> <features> <runnable models>
    local f m props="" defs=""
    for f in $3; do props+="\"${f}\":true,"; done
    for m in $4; do defs+="{\"name\":\"${m}\",\"unavailable-features\":[]},"; done
    printf '@@features\n{"return":{"model":{"name":"host","props":{%s"never":false}}}}\n' "${props}"
    printf '@@definitions\n{"return":[%s{"name":"EPYC-Genoa","unavailable-features":["avx512-bf16"]}]}\n' "${defs}"
    printf '@@levels\n'
    printf 'x86-64-v2\t+popcnt;+pni;+sse4.1;+sse4.2;+ssse3\n'
    printf 'x86-64-v3\t+%s\n' "${V3// /;+}"
    printf 'x86-64-v4\t+%s\n' "${V4// /;+}"
    printf '@@cpu\n%s\n%s\n' "$1" "$2"
}
r1="$(probe AuthenticAMD "Zen 4" "${V4} gfni flush-l1d" "qemu64 EPYC-Rome EPYC-Milan" | cpu_probe_record n1)"
r2="$(probe AuthenticAMD "Zen 3" "${V3}" "qemu64 EPYC-Rome" | cpu_probe_record n2)"
r3="$(probe AuthenticAMD "Odd" "${V4}" "EPYC-Rome" | cpu_probe_record n3)"
ck "a probe becomes a record: the features the guest gets, not the false ones" \
   "22 false" "$(jq -r '"\(.features | length) \(.features | index("never") != null)"' <<< "${r1}")"
ck "…the models that run with nothing missing, not the others" \
   "EPYC-Milan EPYC-Rome qemu64" "$(jq -r '.models | join(" ")' <<< "${r1}")"
ck "…and Proxmox's x86-64 level definitions" \
   "x86-64-v2 x86-64-v3 x86-64-v4" "$(jq -r '.levels | keys | join(" ")' <<< "${r1}")"

inv="$(jq -s . <<< "${r1}${r2}" | cpu_inventory_compute "${CPU_ADVISORY_FEATURES}")"
ck "a node's level is the richest x86-64 model all of whose flags it offers" \
   "n1=x86-64-v4 n2=x86-64-v3" "$(jq -r '[.nodes[] | "\(.node)=\(.level)"] | join(" ")' <<< "${inv}")"
ck "the common level is the richest one inside every node's features" \
   "x86-64-v3" "$(jq -r '.common.level' <<< "${inv}")"
ck "common vendor models: those every node runs" \
   "EPYC-Rome" "$(jq -r '.common.vendorModels | join(" ")' <<< "${inv}")"
ck "n1 → n2 is not live-safe: n2 lacks instructions n1 offers" \
   "false avx512bw avx512cd avx512dq avx512f avx512vl gfni" \
   "$(jq -r '.matrix[] | select(.from == "n1") | "\(.liveSafe) \(.hard | join(" "))"' <<< "${inv}")"
ck "…a missing mitigation bit is listed apart, as advisory" \
   "flush-l1d" "$(jq -r '.matrix[] | select(.from == "n1") | .soft | join(" ")' <<< "${inv}")"
ck "n2 → n1 is live-safe: n1 offers everything n2 does" \
   "true" "$(jq -r '.matrix[] | select(.from == "n2") | .liveSafe' <<< "${inv}")"
ck "a node that cannot run qemu64 has no x86-64 level" \
   "null" "$(jq -s . <<< "${r3}" | cpu_inventory_compute "" | jq -r '.nodes[0].level')"
md="$(cpu_inventory_markdown <<< "${inv}")"
ck "the page shows the matrix: ✗ with the count one way, ✓ the other" \
   "| n1 | — | ✗ −6 |
| n2 | ✓ | — |" "$(grep -E '^\| n[12] \| (—|✓)' <<< "${md}")"

echo ""
echo "test-proxmox-manager: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
