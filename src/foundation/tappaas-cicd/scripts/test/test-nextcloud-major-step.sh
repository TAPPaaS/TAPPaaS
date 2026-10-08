#!/usr/bin/env bash
#
# test-nextcloud-major-step.sh — a Nextcloud guest moves at most one major per build.
#
# build-facts.sh reads the major from the guest's config.php (none for a fresh
# install, unknown for an instance whose major cannot be read), and nc-major.nix
# takes min(target, installed + 1) from those facts. Here the real collector runs
# against a fixture root and its facts are evaluated with nix-instantiate — the
# pair the mothership build uses (#797).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NC="$(cd "${HERE}/../../../../collaboration/nextcloud" 2>/dev/null && pwd)"
STEP="${NC}/nc-major.nix"
FACTS="${NC}/build-facts.sh"
PASS=0; FAIL=0
ck()   { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
ckin() { if [[ "$3" == *"$2"* ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (missing '$2' in: $3)"; FAIL=$((FAIL+1)); fi; }
[[ -f "${STEP}" && -f "${FACTS}" ]] || { echo "nc-major.nix / build-facts.sh not found — cannot run here."; exit 77; }
command -v nix-instantiate >/dev/null 2>&1 || { echo "nix-instantiate not available — skipped."; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/nc-major.XXXXXX")"; trap 'rm -rf "${T}"' EXIT
G="${T}/guest"; CFG="${G}/var/lib/nextcloud/config/config.php"

AVAIL='m: builtins.elem m [ 33 34 35 ]'   # which nextcloud<N> this nixpkgs carries
eval_step() {  # $1 = attribute, $2 = target major
    nix-instantiate --eval --strict 2>&1 -E "(import ${STEP} {
        targetMajor = ${2:-35}; available = ${3:-${AVAIL}}; factsFile = \"${T}/facts.env\";
    }).$1" | tr -d '"'
}
ev() { FACTS_ROOT="${G}" bash "${FACTS}" > "${T}/facts.env"; eval_step "$@"; }
reset() { rm -rf "${G}"; mkdir -p "${G}/var/lib/nextcloud/config"; }
config() { printf "<?php\n\$CONFIG = array (\n  'instanceid' => 'x',\n  'version' => '%s',\n  'passwordsalt' => 'secret',\n);\n" "$1" > "${CFG}"; }

reset
ck "fresh install (no config.php, no data): straight to the target" "35" "$(ev major)"
ck "…the collector says so: none" "NEXTCLOUD_INSTALLED_MAJOR=none" "$(cat "${T}/facts.env")"

reset; config 33.0.4.1
ck "33 → 34, not straight to 35" "34" "$(ev major)"
ck "…the collector reads the major only" "NEXTCLOUD_INSTALLED_MAJOR=33" "$(cat "${T}/facts.env")"
ck "…and no secret leaves the guest" "0" "$(grep -c secret "${T}/facts.env")"
reset; config 34.0.1.2
ck "34 → 35" "35" "$(ev major)"
ck "…on the target" "true" "$(ev onTarget)"
reset; config 35.0.0.10
ck "on the target: stays" "35" "$(ev major)"
reset; config 36.0.0.1
ckin "newer than the target: refused" "cannot go back a major" "$(ev major)"
reset; config 32.0.0.1
ckin "a major this nixpkgs does not carry next: refused" "needs nextcloud33" "$(ev major 35 'm: builtins.elem m [ 34 35 ]')"

# #797: what the mothership build saw — nothing — must never read as a fresh install.
reset; printf "<?php\n\$CONFIG = array ( 'instanceid' => 'x' );\n" > "${CFG}"
ckin "a config.php without a version: refused" "cannot be read from config.php" "$(ev major)"
reset; rm -rf "${G}/var/lib/nextcloud/config"; mkdir -p "${G}/var/lib/nextcloud/data/admin"
ckin "data but no config.php: refused, not a fresh install" "cannot be read from config.php" "$(ev major)"
rm -f "${T}/facts.env"
ckin "no build facts at all: refused" "no build facts" "$(eval_step major)"

echo "── nextcloud major step: ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
