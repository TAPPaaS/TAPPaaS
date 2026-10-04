#!/usr/bin/env bash
#
# test-update-os-baseline.sh — update-os ships the NixOS baseline every module imports (#324).
#
# Every module .nix imports /etc/nixos/tappaas-common.nix. update-os.sh copies it
# from the checkout before each rebuild; without it the rebuild fails on a
# missing path, so a module that imports it and cannot get it must stop the run
# with that reason, not a nix trace. The block is lifted out of update-os.sh and
# run against a stubbed scp/ssh/die.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../../manager/health-manager/update-os.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

[[ -f "${SRC}" ]] || { echo "update-os.sh not found — cannot run here."; exit 77; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/baseline.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

awk '/^    local _baseline=/{f=1} f{print} f&&/^    fi$/{exit}' "${SRC}" > "${TMP}/block.sh"
ck "the baseline block extracts" "yes" "$(grep -q 'tappaas-common.nix' "${TMP}/block.sh" && echo yes || echo no)"

# run <baseline exists: yes|no> <module .nix content> — prints what happened:
# "sent:<source basename>", "died", or nothing.
run() {
    : > "${TMP}/out"
    [[ "$1" == yes ]] && printf '{ }\n' > "${TMP}/tappaas-common.nix" || rm -f "${TMP}/tappaas-common.nix"
    printf '%s\n' "$2" > "${TMP}/mod.nix"
    T="${TMP}" bash -c '
        info(){ :; }
        die(){ echo died >> "${T}/out"; exit 1; }
        scp(){ echo "sent:$(basename "${@: -2:1}")" >> "${T}/out"; }
        ssh(){ :; }
        vm_ip=10.2.0.9 nix_config="${T}/mod.nix" TAPPAAS_BASELINE_NIX="${T}/tappaas-common.nix"
        f() { '"$(cat "${TMP}/block.sh")"'
        }; f' 2>/dev/null
    paste -sd, - < "${TMP}/out"
}

IMPORTS='{ imports = [ /etc/nixos/hardware-configuration.nix /etc/nixos/tappaas-common.nix ]; }'
ck "the baseline is shipped before the rebuild" "sent:tappaas-common.nix" "$(run yes "${IMPORTS}")"
ck "it is shipped to a module that does not import it yet" "sent:tappaas-common.nix" \
   "$(run yes '{ imports = [ /etc/nixos/hardware-configuration.nix ]; }')"
ck "missing, for a module that imports it: the run stops" "died" "$(run no "${IMPORTS}")"
ck "missing, for a module that does not: nothing to do" "" \
   "$(run no '{ imports = [ /etc/nixos/hardware-configuration.nix ]; }')"
ck "a comment naming it is not an import" "" \
   "$(run no '{ imports = [ ]; # not tappaas-common.nix yet
}')"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
