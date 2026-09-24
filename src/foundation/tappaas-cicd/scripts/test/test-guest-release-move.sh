#!/usr/bin/env bash
#
# test-guest-release-move.sh — a NixOS guest takes a nixpkgs release move as a
# staged boot, not a switch (#728), as the mothership does (#725).
#
# Across a release, `nixos-rebuild switch` applies but cannot reload
# dbus-broker and exits 4 (hrossen, 2026-09-24: Nextcloud, 25.11 -> 26.05).
# update-os.sh retried any non-zero exit; on hrossen attempt 2 happened to
# succeed, on another site all three failed and the guest rolled back. Now the
# target is built first, its release compared with the running one, and a move
# is staged with `nixos-rebuild boot` for the post-rebuild reboot to take.
#
# release_move_of and the rebuild block are lifted out of update-os.sh and run
# against a scripted ssh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../../manager/health-manager/update-os.sh"

PASS=0; FAIL=0
ck()   { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
ckin() { if [[ "$3" == *"$2"* ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (missing '$2' in: $3)"; FAIL=$((FAIL+1)); fi; }

[[ -f "${SRC}" ]] || { echo "update-os.sh not found — cannot run here."; exit 77; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/release-move.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

awk '/^run_quiet\(\) \{$/{f=1} f{print} f&&/^}$/{exit}' "${SRC}" > "${TMP}/run_quiet.sh"
awk '/^release_move_of\(\) \{$/{f=1} f{print} f&&/^}$/{exit}' "${SRC}" > "${TMP}/release_move_of.sh"
awk '/^    local attempt rebuilt=0 rc staged=0/{f=1} f{print} f&&/\[\[ "\$rebuilt" == "1" \]\] \|\| die/{exit}' "${SRC}" > "${TMP}/block.sh"
ck "release_move_of extracts" "yes" "$(grep -q 'nixos-version' "${TMP}/release_move_of.sh" && echo yes || echo no)"
ck "the rebuild block extracts" "yes" "$(grep -q 'nixos-rebuild boot' "${TMP}/block.sh" && grep -q 'for attempt in 1 2 3' "${TMP}/block.sh" && echo yes || echo no)"

# run <running release> <target release|FAIL> <boot rc> <switch rcs…>
# Prints: <exit>|staged=<0|1>|boots=<n>|switches=<n>; the log is in ${TMP}/out.
run() {
    CUR="$1" NEW="$2" BOOT_RC="$3" SWITCH="${*:4}" T="${TMP}" bash -c '
        set -euo pipefail
        : > "${T}/calls"
        info(){ echo "INFO $*"; }; warn(){ echo "WARN $*"; }; error(){ echo "ERROR $*"; }
        die(){ error "$@"; exit 1; }; debug(){ :; }
        sleep(){ :; }; update_ssh_known_hosts(){ :; }; wait_for_ssh(){ return 0; }
        ssh() {
            local cmd="${*: -1}"
            case "${cmd}" in
                *"/run/current-system/nixos-version"*) printf "%s\n" "${CUR}" | grep -oE "^[0-9]+\.[0-9]+" ;;
                *"nix-build"*) echo "these 3 derivations will be built:" >&2
                               [[ "${NEW}" == FAIL ]] && return 1
                               echo "/nix/store/abc-nixos-system-guest-${NEW}.20260924" ;;
                *"/nix/store/abc-nixos-system-guest-"*"/nixos-version"*) printf "%s\n" "${NEW}" | grep -oE "^[0-9]+\.[0-9]+" ;;
                *"nixos-rebuild boot"*)   echo boot >> "${T}/calls"; return "${BOOT_RC}" ;;
                *"nixos-rebuild switch"*) echo switch >> "${T}/calls"
                    local n; n=$(grep -c switch "${T}/calls"); local rcs=(${SWITCH})
                    return "${rcs[$((n-1))]:-0}" ;;
                *) return 0 ;;
            esac
        }
        source "${T}/run_quiet.sh"; source "${T}/release_move_of.sh"
        OPT_DEBUG=0 vm_ip=10.2.0.9 vmname=guest nixpkgs_arg="-I nixpkgs=x" remote_nix_path=/etc/nixos/guest.nix
        f() { '"$(cat "${TMP}/block.sh")"'
            echo "STAGED=${staged}"
        }
        f
    ' > "${TMP}/out" 2>&1
    local rc=$?
    echo "${rc}|staged=$(sed -n "s/^STAGED=//p" "${TMP}/out")|boots=$(grep -c boot "${TMP}/calls")|switches=$(grep -c switch "${TMP}/calls")"
}

echo "── the same release: an ordinary switch, as before ──"
ck "25.11 -> 25.11: one switch, no boot" "0|staged=0|boots=0|switches=1" "$(run 25.11 25.11 0 0)"

echo "── a release move: staged with nixos-rebuild boot ──"
ck "25.11 -> 26.05: boot, no switch" "0|staged=1|boots=1|switches=0" "$(run 25.11 26.05 0 4 4 4)"
ckin "  …and it says what it is doing" "Release move on guest: 25.11 -> 26.05" "$(cat "${TMP}/out")"
ck "a failed staging dies, naming where the guest still is" "1|staged=|boots=1|switches=0" "$(run 25.11 26.05 1)"
ckin "  …'still on 25.11'" "it is still on 25.11" "$(cat "${TMP}/out")"

echo "── when the target cannot be read, the switch path decides (and reports) ──"
ck "a failing build: no staging, the switch loop runs" "0|staged=0|boots=0|switches=1" "$(run 25.11 FAIL 0 0)"
ck "no running release: the switch loop runs" "0|staged=0|boots=0|switches=1" "$(run '' 26.05 0 0)"

echo "── only the numeric release counts ──"
ck "flake-built 25.11.2026… vs tarball 25.11pre-git: no move" "0|staged=0|boots=0|switches=1" "$(run 25.11.20260522.b77b3de 25.11pre-git 0 0)"
ck "25.11pre-git -> 26.05pre-git: a move" "0|staged=1|boots=1|switches=0" "$(run 25.11pre-git 26.05pre-git 0)"

echo "── the old behaviour for ordinary failures is unchanged ──"
ck "same release, switch fails once then works: retried" "0|staged=0|boots=0|switches=2" "$(run 26.05 26.05 0 1 0)"

echo "── the reboot messages tell a staged move from an active one ──"
ckin "automaticReboot=false: 'STAGED, not active'" 'The release move (${_move% *} -> ${_move#* }) is STAGED, not active' "$(cat "${SRC}")"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
