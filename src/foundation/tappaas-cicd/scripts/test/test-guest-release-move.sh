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
# Since #774 the target is built ON THE MOTHERSHIP and copied to the guest; the
# guest builds only when that is impossible, with a warning that says why. So
# the scenarios run on that path, and the fallbacks are tested on their own.
#
# release_move_of, release_move_to, guest_activate_cmd and the rebuild block are
# lifted out of update-os.sh and run against a scripted ssh; the mothership
# build itself (guest_build_on_cicd) is a stub that returns a fake system whose
# nixos-version is the target release.
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
for fn in run_quiet_rc nixos_rebuild_exit_meaning; do
    awk -v fn="${fn}" '$0 ~ "^"fn"\\(\\) \\{$"{f=1} f{print} f&&/^}$/{exit}' "${SRC}" >> "${TMP}/run_quiet.sh"
done
awk '/^release_move_of\(\) \{$/{f=1} f{print} f&&/^}$/{exit}' "${SRC}" > "${TMP}/release_move_of.sh"
for fn in release_move_to guest_activate_cmd; do
    awk -v fn="${fn}" '$0 ~ "^"fn"\\(\\) \\{$"{f=1} f{print} f&&/^}$/{exit}' "${SRC}" >> "${TMP}/release_move_of.sh"
done
awk '/^    local attempt rebuilt=0 rc staged=0/{f=1} f{print} f&&/\[\[ "\$rebuilt" == "1" \]\] \|\| die/{exit}' "${SRC}" > "${TMP}/block.sh"
ck "release_move_of, release_move_to and guest_activate_cmd extract" "yes" \
    "$(grep -q '^release_move_to()' "${TMP}/release_move_of.sh" && grep -q '^guest_activate_cmd()' "${TMP}/release_move_of.sh" && echo yes || echo no)"
ck "the rebuild block extracts" "yes" "$(grep -q 'guest_build_on_cicd' "${TMP}/block.sh" && grep -q 'nixos-rebuild boot' "${TMP}/block.sh" && grep -q 'for attempt in 1 2 3' "${TMP}/block.sh" && echo yes || echo no)"

# run <running release> <target release|FAIL> <boot rc> <switch rcs…>
# Prints: <exit>|staged=<0|1>|boots=<n>|switches=<n>; the log is in ${TMP}/out,
# every build/activation in ${TMP}/calls.
# BUILD selects the build path: cicd (default, the mothership builds), cicdfail
# (the mothership build fails), nosrc (the pinned nixpkgs cannot be resolved),
# guest (the TAPPAAS_GUEST_BUILD=guest opt-out).
run() {
    CUR="$1" NEW="$2" BOOT_RC="$3" SWITCH="${*:4}" T="${TMP}" BUILD="${BUILD:-cicd}" bash -c '
        set -euo pipefail
        : > "${T}/calls"
        info(){ echo "INFO $*"; }; warn(){ echo "WARN $*"; }; error(){ echo "ERROR $*"; }
        die(){ error "$@"; exit 1; }; debug(){ :; }
        sleep(){ :; }; update_ssh_known_hosts(){ :; }; wait_for_ssh(){ return 0; }; report_failed_units(){ :; }
        GN=""; CL=""
        # The mothership build (#774): a fake system whose nixos-version is the
        # target release, or a failure.
        pinned_nixpkgs_source(){ [[ "${BUILD}" == nosrc ]] && return 1; echo /nix/store/fake-nixpkgs-src; }
        guest_build_on_cicd(){
            echo cicd-build >> "${T}/calls"
            [[ "${BUILD}" == cicdfail || "${NEW}" == FAIL ]] && return 1
            mkdir -p "${T}/sys"; printf "%s\n" "${NEW}" > "${T}/sys/nixos-version"
            echo "${T}/sys"
        }
        guest_build_promote(){ echo "promote $2" >> "${T}/calls"; }
        # update-os.sh bounds the rebuild ssh (#720): `timeout -k 30 <max> ssh …`.
        # The real timeout would exec the real ssh, so drop its three arguments
        # and run the scripted one.
        SSH_REBUILD_OPTS=(-o BatchMode=yes); REBUILD_MAX_SECONDS=3600
        timeout(){ shift 3; "$@"; }
        ssh() {
            local cmd="${*: -1}"
            case "${cmd}" in
                *"switch-to-configuration boot"*)   echo boot >> "${T}/calls"; return "${BOOT_RC}" ;;
                *"switch-to-configuration switch"*) echo switch >> "${T}/calls"
                    local n; n=$(grep -c switch "${T}/calls"); local rcs=(${SWITCH})
                    return "${rcs[$((n-1))]:-0}" ;;
                *"/run/current-system/nixos-version"*) printf "%s\n" "${CUR}" > "${T}/cur-version"
                    bash -c "${cmd//\/run\/current-system\/nixos-version/${T}/cur-version}" ;;
                *"nix-build"*) echo guest-build >> "${T}/calls"
                               echo "these 3 derivations will be built:" >&2
                               [[ "${NEW}" == FAIL ]] && return 1
                               echo "/nix/store/abc-nixos-system-guest-${NEW}.20260924" ;;
                *"/nix/store/abc-nixos-system-guest-"*"/nixos-version"*) printf "%s\n" "${NEW}" > "${T}/new-version"
                    bash -c "$(sed -E "s#/nix/store/abc-nixos-system-guest-[^ ]*/nixos-version#${T}/new-version#" <<< "${cmd}")" ;;
                *"nixos-rebuild boot"*)   echo boot >> "${T}/calls"; return "${BOOT_RC}" ;;
                *"nixos-rebuild switch"*) echo switch >> "${T}/calls"
                    local n; n=$(grep -c switch "${T}/calls"); local rcs=(${SWITCH})
                    return "${rcs[$((n-1))]:-0}" ;;
                *) return 0 ;;
            esac
        }
        source "${T}/run_quiet.sh"; source "${T}/release_move_of.sh"
        # The guest-side path (the guest builds, stages, boots): what this test is
        # about. Since #774 the block builds on the mothership by default and
        # needs flake_lock and the guest_build_* helpers, which this harness does
        # not stub — TAPPAAS_GUEST_BUILD=guest is the switch #774 provides.
        flake_lock=/x/flake.lock nix_basename=guest.nix
        [[ "${BUILD}" == guest ]] && TAPPAAS_GUEST_BUILD=guest
        OPT_DEBUG=0 vm_ip=10.2.0.9 vmname=guest nixpkgs_arg="-I nixpkgs=x" remote_nix_path=/etc/nixos/guest.nix
        f() { '"$(cat "${TMP}/block.sh")"'
            echo "STAGED=${staged}"
        }
        f
    ' > "${TMP}/out" 2>&1
    local rc=$?
    echo "${rc}|staged=$(sed -n "s/^STAGED=//p" "${TMP}/out")|boots=$(grep -c boot "${TMP}/calls")|switches=$(grep -c switch "${TMP}/calls")"
}
# Where the last run built: "cicd=<n> guest=<n> promote=<ok values>".
built() { echo "cicd=$(grep -c '^cicd-build' "${TMP}/calls") guest=$(grep -c '^guest-build' "${TMP}/calls") promote=$(sed -n 's/^promote //p' "${TMP}/calls" | paste -sd, -)"; }

echo "── built on the mothership (#774): the same release, an ordinary switch ──"
ck "25.11 -> 25.11: one switch, no boot" "0|staged=0|boots=0|switches=1" "$(run 25.11 25.11 0 0)"
ck "  …built on the mothership, never on the guest; its gcroot promoted" "cicd=1 guest=0 promote=1" "$(built)"

echo "── a release move: staged as a boot (switch-to-configuration boot) ──"
ck "25.11 -> 26.05: boot, no switch" "0|staged=1|boots=1|switches=0" "$(run 25.11 26.05 0 4 4 4)"
ckin "  …and it says what it is doing" "Release move on guest: 25.11 -> 26.05" "$(cat "${TMP}/out")"
ck "  …the mothership-built system is staged, not a guest build" "cicd=1 guest=0 promote=1" "$(built)"
ck "a failed staging dies, naming where the guest still is" "1|staged=|boots=1|switches=0" "$(run 25.11 26.05 1)"
ckin "  …'still on 25.11'" "it is still on 25.11" "$(cat "${TMP}/out")"
ck "  …and the unused build is not promoted" "cicd=1 guest=0 promote=0" "$(built)"

echo "── when the target cannot be built or read, the switch path decides ──"
ck "no build anywhere: no staging, the switch loop runs" "0|staged=0|boots=0|switches=1" "$(run 25.11 FAIL 0 0)"
ck "no running release: the switch loop runs" "0|staged=0|boots=0|switches=1" "$(run '' 26.05 0 0)"

echo "── only the numeric release counts ──"
ck "flake-built 25.11.2026… vs tarball 25.11pre-git: no move" "0|staged=0|boots=0|switches=1" "$(run 25.11.20260522.b77b3de 25.11pre-git 0 0)"
ck "25.11pre-git -> 26.05pre-git: a move" "0|staged=1|boots=1|switches=0" "$(run 25.11pre-git 26.05pre-git 0)"
ck "fresh template clone efi-qcow2-25.11… -> 26.05pre-git: a move" "0|staged=1|boots=1|switches=0" "$(run efi-qcow2-25.11.20260522.b77b3de 26.05pre-git 0)"
ck "efi-qcow2-26.05… -> 26.05pre-git: no move" "0|staged=0|boots=0|switches=1" "$(run efi-qcow2-26.05.20260922.1bc55b9 26.05pre-git 0 0)"

echo "── only a lost connection is retried; nixos-rebuild's own verdict is not ──"
ck "same release, ssh drops once (255) then works: retried" "0|staged=0|boots=0|switches=2" "$(run 26.05 26.05 0 255 0)"
ck "same release, switch fails (1): no retry, it stops" "1|staged=|boots=0|switches=1" "$(run 26.05 26.05 0 1 0)"

echo "── the guest builds only when the mothership cannot, and says why ──"
ck "mothership build fails, same release: guest builds, one switch" "0|staged=0|boots=0|switches=1" "$(BUILD=cicdfail run 25.11 25.11 0 0)"
ck "  …tried the mothership first, then the guest" "cicd=1 guest=1 promote=0" "$(built)"
ckin "  …and names why" "building it on the mothership failed (#774)" "$(cat "${TMP}/out")"
ck "mothership build fails, a release move: still staged (guest-built)" "0|staged=1|boots=1|switches=0" "$(BUILD=cicdfail run 25.11 26.05 0 4)"
ck "pinned nixpkgs unresolvable: guest builds, no mothership attempt" "0|staged=0|boots=0|switches=1" "$(BUILD=nosrc run 25.11 25.11 0 0)"
ck "  …built on the guest only" "cicd=0 guest=1 promote=" "$(built)"
ckin "  …and names why" "the pinned nixpkgs could not be resolved" "$(cat "${TMP}/out")"
ck "TAPPAAS_GUEST_BUILD=guest: the guest builds, as asked" "0|staged=1|boots=1|switches=0" "$(BUILD=guest run 25.11 26.05 0)"
ck "  …no mothership build" "cicd=0 guest=1 promote=" "$(built)"

echo "── the reboot messages tell a staged move from an active one ──"
ckin "automaticReboot=false: 'STAGED, not active'" 'The release move (${_move% *} -> ${_move#* }) is STAGED, not active' "$(cat "${SRC}")"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
