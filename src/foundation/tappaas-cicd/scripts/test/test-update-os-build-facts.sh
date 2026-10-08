#!/usr/bin/env bash
#
# test-update-os-build-facts.sh — update-os collects a module's build facts on the
# guest before it builds (#797).
#
# A module whose build steps along what the guest runs (identity, nextcloud) ships
# build-facts.sh. update-os.sh runs it on the guest and writes its KEY=value lines
# to /etc/nixos/tappaas-build-facts.env, which the mothership build stages with
# the rest of /etc/nixos. A collector that fails must stop the run: no facts would
# otherwise read as a fresh install. The block is lifted out of update-os.sh and
# run against a stubbed ssh whose "guest" runs the real identity collector on a
# fixture root.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../../manager/health-manager/update-os.sh"
COLLECTOR="${HERE}/../../../identity/build-facts.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

[[ -f "${SRC}" && -f "${COLLECTOR}" ]] || { echo "update-os.sh or identity/build-facts.sh not found — cannot run here."; exit 77; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/buildfacts.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

awk '/^    if \[\[ -f \.\/build-facts\.sh \]\]; then$/{f=1} f{print} f&&/^    fi$/{exit}' "${SRC}" > "${TMP}/block.sh"
ck "the build-facts block extracts" "yes" "$(grep -q 'tappaas-build-facts.env' "${TMP}/block.sh" && echo yes || echo no)"

# run <module dir> <collector ssh rc> — prints what happened: the written facts
# (one line), "died", or nothing.
run() {
    rm -f "${TMP}/written" "${TMP}/out"
    ( cd "$1" && T="${TMP}" RC="$2" bash -c '
        info(){ :; }
        die(){ echo died >> "${T}/out"; exit 1; }
        ssh(){
            case "$*" in
                *"bash -s"*) [[ "${RC}" -eq 0 ]] || return "${RC}"; FACTS_ROOT="${T}/guest" bash -s ;;
                *"tee /etc/nixos/tappaas-build-facts.env"*) cat > "${T}/written" ;;
            esac
        }
        vm_ip=10.2.0.9 vmname=identity
        f() { local _facts
        '"$(cat "${TMP}/block.sh")"'
        }; f' 2>/dev/null )
    if [[ -f "${TMP}/out" ]]; then cat "${TMP}/out"; elif [[ -f "${TMP}/written" ]]; then paste -sd' ' - < "${TMP}/written"; fi
}

mkdir -p "${TMP}/plain" "${TMP}/ident" "${TMP}/guest/var/lib/authentik"
cp "${COLLECTOR}" "${TMP}/ident/build-facts.sh"
printf '2025.4.4\n' > "${TMP}/guest/var/lib/authentik/tappaas-version"

ck "a module without build-facts.sh: nothing collected" "" "$(run "${TMP}/plain" 0)"
ck "identity: the guest's facts are written to /etc/nixos" "AUTHENTIK_INSTALLED=2025.4.4 AUTHENTIK_STEP_BLOCKED=" "$(run "${TMP}/ident" 0)"
ck "a collector that cannot run stops the update" "died" "$(run "${TMP}/ident" 255)"
ck "…and writes no facts" "no" "$([[ -f ${TMP}/written ]] && echo yes || echo no)"
ck "the facts are written before the build, with the rest of /etc/nixos" "yes" \
   "$(awk '/tappaas-build-facts.env/{f=NR} /guest_build_on_cicd "\$\{vmname\}"/{b=NR} END{print (f && b && f < b) ? "yes" : "no"}' "${SRC}")"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
