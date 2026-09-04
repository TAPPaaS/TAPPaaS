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

echo ""
echo "test-proxmox-manager: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
