#!/usr/bin/env bash
#
# test-flake-pin-audit.sh — flake inputs on TAPPaaS code are pinned by a lock (ADR-033 D8).
#
# Fixture flakes in a temp tree, then this checkout: a TAPPaaS input locked by
# rev + narHash passes; one locked without a rev, an input without narHash, a
# flake with no lock, an absolute path and a path out of the tree are reported;
# an in-tree path input (tappaas-cicd -> ../templates) passes.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
AUDIT="${HERE}/../flake-pin-audit.sh"
PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
command -v jq >/dev/null || { echo "jq not found — cannot run here."; exit 77; }

W="$(mktemp -d "${TMPDIR:-/tmp}/flake-pin.XXXXXX")"
trap 'rm -rf "${W}"' EXIT INT TERM

REV=0123456789abcdef0123456789abcdef01234567
NH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
# flake <dir> <locked JSON of input "m">|- — a flake.nix with inputs, and its lock.
flake() {
    mkdir -p "${W}/t/$1"; echo '{ inputs.m.url = "x"; outputs = _: { }; }' > "${W}/t/$1/flake.nix"
    [[ "$2" == - ]] || printf '{ "nodes": { "root": { "inputs": { "m": "m" } }, "m": { "locked": %s } }, "root": "root", "version": 7 }\n' "$2" > "${W}/t/$1/flake.lock"
}
audit() { bash "${AUDIT}" "${W}/t"; }

flake good "{ \"type\": \"git\", \"url\": \"https://codeberg.org/TAPPaaS/Community\", \"rev\": \"${REV}\", \"narHash\": \"${NH}\" }"
ck "a TAPPaaS input locked by rev + narHash passes" "0" "$(audit >/dev/null; echo $?)"

flake norev "{ \"type\": \"tarball\", \"url\": \"https://codeberg.org/TAPPaaS/Community/archive/main.tar.gz\", \"narHash\": \"${NH}\" }"
ck "a TAPPaaS input without a locked rev is reported" "1" "$(audit | grep -c 'norev/flake.lock: .*TAPPaaS repository without a locked rev')"
rm -rf "${W}/t/norev"

flake nohash "{ \"type\": \"github\", \"owner\": \"tappaas\", \"repo\": \"x\", \"rev\": \"${REV}\" }"
ck "an input without narHash is reported" "1" "$(audit | grep -c 'nohash/flake.lock: .*no narHash')"
rm -rf "${W}/t/nohash"

flake nolock -
ck "a flake with inputs and no lock is reported" "1" "$(audit | grep -c 'nolock/flake.nix: no flake.lock')"
rm -rf "${W}/t/nolock"

flake abs '{ "type": "path", "path": "/srv/modules/x" }'
ck "an absolute path input is reported" "1" "$(audit | grep -c 'outside the signed tree')"
rm -rf "${W}/t/abs"

mkdir -p "${W}/outside"
flake escape '{ "type": "path", "path": "../../outside" }'
ck "a path input that leaves the tree is reported" "1" "$(audit | grep -c 'leaves the tree')"
rm -rf "${W}/t/escape"

mkdir -p "${W}/t/templates"
flake sib '{ "type": "path", "path": "../templates" }'
ck "an in-tree path input passes" "0" "$(audit >/dev/null; echo $?)"

out="$(bash "${AUDIT}")"; rc=$?
ck "this checkout: every flake input is pinned" "0" "${rc}"
[[ -z "${out}" ]] || echo "${out}"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
