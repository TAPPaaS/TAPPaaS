#!/usr/bin/env bash
#
# test-update-os-siblings.sh — update-os ships what a module's .nix references (#740).
#
# The main .nix may import sibling .nix helpers (#286) and apply patch files; a
# file left behind fails evaluation on the guest with "path … does not exist".
# The sibling loop is lifted out of update-os.sh and run in a fake module
# directory against a stubbed scp/ssh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../../manager/health-manager/update-os.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

[[ -f "${SRC}" ]] || { echo "update-os.sh not found — cannot run here."; exit 77; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/siblings.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

awk '/^    for _sib in /{f=1} f{print} f&&/^    done$/{exit}' "${SRC}" > "${TMP}/loop.sh"
ck "the sibling loop extracts" "yes" "$(grep -q '_sib_remote' "${TMP}/loop.sh" && echo yes || echo no)"

# shipped <files in the module dir…> — the basenames scp'd, sorted, comma-joined.
shipped() {
    rm -rf "${TMP}/mod"; mkdir -p "${TMP}/mod"; : > "${TMP}/sent"
    local f; for f in "$@"; do : > "${TMP}/mod/${f}"; done
    ( cd "${TMP}/mod" && T="${TMP}" bash -c '
        warn(){ :; }
        scp(){ basename "${@: -2:1}" >> "${T}/sent"; }
        ssh(){ :; }
        vm_ip=10.2.0.9 nix_basename=nextcloud.nix
        f() { local _sib _sib_base _sib_remote; '"$(cat "${TMP}/loop.sh")"'
        }; f' )
    sort "${TMP}/sent" | paste -sd, -
}

ck "helper .nix siblings go, not the main .nix" "eurooffice.nix,nc-major.nix" \
   "$(shipped nextcloud.nix nc-major.nix eurooffice.nix)"
ck "a patch the .nix applies goes too" "fix.patch,helper.nix,upstream.diff" \
   "$(shipped nextcloud.nix helper.nix fix.patch upstream.diff)"
ck "nothing else in the directory does" "" \
   "$(shipped nextcloud.nix install.sh README.md nextcloud.json test.sh)"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
