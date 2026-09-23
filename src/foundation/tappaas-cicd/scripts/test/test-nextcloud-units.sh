#!/usr/bin/env bash
#
# test-nextcloud-units.sh — nextcloud.nix orders its boot-time units so that
# none races another over the same state (#715).
#
#   1. nextcloud-apply-db-pass ran concurrently with postgresql-setup: on NixOS
#      25.11 the latter issues CREATE USER / ALTER ROLE "nextcloud" itself, and
#      both were ordered only after postgresql.service. One lost with
#      "ERROR: tuple concurrently updated" (hrossen: 09-20, 09-21, twice 09-23),
#      and psql without ON_ERROR_STOP exited 0 regardless.
#   2. The boot-time occ units (six nextcloud-configure-*, the preview backfill)
#      ordered after nextcloud-setup without requiring it, so one failed setup
#      surfaced as seven failures.
#   3. configure-talk and configure-hpb both write spreed turn_servers and
#      stun_servers, unordered: the boot-time winner was whichever finished last.
#
# Evaluates nextcloud.nix's unit definitions; needs nix-instantiate.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NC="$(cd "${HERE}/../../../.." && pwd)/apps/nextcloud"

PASS=0; FAIL=0
ck()   { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
ckin() { if [[ "$3" == *"$2"* ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (missing '$2' in: $3)"; FAIL=$((FAIL+1)); fi; }

[[ -f "${NC}/nextcloud.nix" ]] || { echo "nextcloud.nix not found — cannot run here."; exit 77; }
command -v nix-instantiate >/dev/null 2>&1 || {
    echo "nix-instantiate not found — this suite evaluates nextcloud.nix and cannot run here."
    exit 77
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/nc-units.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
cp -r "${NC}" "${TMP}/nc"

cat > "${TMP}/ev.nix" <<'EOF'
let pkgs = import <nixpkgs> {};
    lib  = pkgs.lib;
    m    = import ./nc/nextcloud.nix {
             config = { networking.hostName = "nextcloud"; };
             inherit lib pkgs; modulesPath = ""; system = "x86_64-linux"; };
    s    = m.systemd.services;
    u    = n: s.${n}.content or s.${n};
    configure = builtins.filter (n: lib.hasPrefix "nextcloud-configure-" n) (builtins.attrNames s)
                ++ [ "nextcloud-preview-backfill" ];
in {
  dbpass_after    = (u "nextcloud-apply-db-pass").after;
  dbpass_requires = (u "nextcloud-apply-db-pass").requires or [];
  dbpass_before   = (u "nextcloud-apply-db-pass").before;
  configure       = configure;
  configure_without_requires = builtins.filter
    (n: !(builtins.elem "nextcloud-setup.service" ((u n).requires or []))) configure;
  configure_without_after = builtins.filter
    (n: !(builtins.elem "nextcloud-setup.service" ((u n).after or []))) configure;
  hpb_after = (u "nextcloud-configure-hpb").after;
  talk_after = (u "nextcloud-configure-talk").after;
}
EOF
EV="$(cd "${TMP}" && nix-instantiate --eval --strict --json ev.nix 2>"${TMP}/ev.err")"
if [[ -z "${EV}" ]]; then
    echo "  FAIL: nextcloud.nix did not evaluate"; sed 's/^/    /' "${TMP}/ev.err" | tail -8; exit 1
fi
j() { jq -r "$1" <<< "${EV}"; }

echo "── 1. the DB password, after the role's own setup ──"
ck "apply-db-pass is ordered after postgresql-setup" "true" \
    "$(j '.dbpass_after | index("postgresql-setup.service") != null')"
ck "…and requires it" "true" "$(j '.dbpass_requires | index("postgresql-setup.service") != null')"
ck "…and still runs before nextcloud-setup" "true" "$(j '.dbpass_before | index("nextcloud-setup.service") != null')"
SCRIPT_SRC="$(sed -n '/systemd.services.nextcloud-apply-db-pass = {/,/^  };/p' "${NC}/nextcloud.nix")"
ckin "the ALTER ROLE stops on an SQL error" "psql -v ON_ERROR_STOP=1" "${SCRIPT_SRC}"

echo "── 2. boot-time occ units require setup, not only follow it ──"
ck "the seven boot-time occ units are all found" "true" "$(j '(.configure | length) >= 7')"
ck "every one is ordered after nextcloud-setup" "" "$(j '.configure_without_after | join(" ")')"
ck "every one requires nextcloud-setup" "" "$(j '.configure_without_requires | join(" ")')"

echo "── 3. one writer wins the Talk keys, always the same one ──"
ck "configure-hpb runs after configure-talk" "true" \
    "$(j '.hpb_after | index("nextcloud-configure-talk.service") != null')"
ck "…and not the other way round" "false" \
    "$(j '.talk_after | index("nextcloud-configure-hpb.service") != null')"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
