#!/usr/bin/env bash
#
# test-update-os-guest-build.sh — guest systems are built on the mothership (#774).
#
# The helpers are lifted out of update-os.sh and run against stubs: the pin is
# fetched by narHash (never a GitHub URL that tarball-ttl refetches), the guest
# activates exactly the system it was sent, the GC roots rotate only on success,
# and a release move is read from the built system. The build itself — the mount
# namespace over /etc/nixos — needs root and a guest, and is proven live.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../../manager/health-manager/update-os.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

[[ -f "${SRC}" ]] || { echo "update-os.sh not found — cannot run here."; exit 77; }
command -v jq >/dev/null || { echo "jq not found — cannot run here."; exit 77; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/guest-build.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

for fn in pinned_nixpkgs_source guest_build_promote guest_activate_cmd release_move_to; do
    awk -v f="${fn}() {" '$0 == f {p=1} p {print} p && /^}$/ {exit}' "${SRC}" >> "${TMP}/fns.sh"
done
ck "the four helpers extract" "4" "$(grep -c '^[a-z_]*() {$' "${TMP}/fns.sh")"

# ── pinned_nixpkgs_source ────────────────────────────────────────────────────
cat > "${TMP}/github.lock" <<'EOF'
{ "nodes": { "nixpkgs": { "locked": { "type": "github", "owner": "NixOS", "repo": "nixpkgs",
  "rev": "c508844df6c28fa6dabc1b6af70f3ccbd65c5201", "narHash": "sha256-AAAA" } } } }
EOF
cat > "${TMP}/path.lock" <<'EOF'
{ "nodes": { "nixpkgs": { "locked": { "type": "path", "path": "/x", "narHash": "sha256-AAAA" } } } }
EOF
pin() {
    bash -c 'source "$1"; nix() { printf "%s" "${@: -1}"; }; pinned_nixpkgs_source "$2"' _ "${TMP}/fns.sh" "$1"
}
EXPR="$(pin "${TMP}/github.lock")"
ck "the pin is fetched by its narHash" "yes" "$([[ "${EXPR}" == *'narHash = "sha256-AAAA"'* ]] && echo yes || echo no)"
ck "…at the locked revision" "yes" "$([[ "${EXPR}" == *'rev = "c508844df6c28fa6dabc1b6af70f3ccbd65c5201"'* ]] && echo yes || echo no)"
ck "…through fetchTree, not a tarball URL" "yes" "$([[ "${EXPR}" == '(builtins.fetchTree {'*').outPath' ]] && echo yes || echo no)"
ck "a lock that pins no GitHub revision gives nothing" "" "$(pin "${TMP}/path.lock")"

# ── guest_activate_cmd ───────────────────────────────────────────────────────
SYS=/nix/store/aaaa-nixos-system-vw-26.05
CMD="$(bash -c 'source "$1"; guest_activate_cmd "$2" switch' _ "${TMP}/fns.sh" "${SYS}")"
ck "the system profile is set to the system sent" "yes" \
   "$([[ "${CMD}" == "sudo nix-env -p /nix/var/nix/profiles/system --set ${SYS} && "* ]] && echo yes || echo no)"
ck "activation runs under systemd-run and waits" "yes" \
   "$([[ "${CMD}" == *"systemd-run "*"--wait ${SYS}/bin/switch-to-configuration switch" ]] && echo yes || echo no)"
ck "a release move is staged with boot" "yes" \
   "$(bash -c 'source "$1"; guest_activate_cmd "$2" boot' _ "${TMP}/fns.sh" "${SYS}" | grep -q 'switch-to-configuration boot$' && echo yes || echo no)"
ck "nothing is evaluated on the guest" "" \
   "$(grep -oE 'nixos-rebuild|nix-build|nix-instantiate' <<< "${CMD}")"

# ── guest_build_promote ──────────────────────────────────────────────────────
R="${TMP}/roots"; mkdir -p "${R}"
promote() { GUEST_BUILD_GCROOTS="${R}" bash -c 'source "$1"; sudo() { [[ "$1" == -n ]] && shift; "$@"; }; guest_build_promote "$2" "$3"' _ "${TMP}/fns.sh" "$1" "$2"; }
state() { local f out=""; for f in current new previous; do out+="${f}=$(readlink "${R}/vw.${f}" 2>/dev/null || echo -),"; done; echo "${out%,}"; }
ln -s /nix/store/g1 "${R}/vw.new"; promote vw 1
ck "the first switch roots the build as current" "current=/nix/store/g1,new=-,previous=-" "$(state)"
ln -s /nix/store/g2 "${R}/vw.new"; promote vw 1
ck "the next one keeps the old current as previous" "current=/nix/store/g2,new=-,previous=/nix/store/g1" "$(state)"
ln -s /nix/store/g3 "${R}/vw.new"; promote vw 0
ck "a failed switch drops the build and keeps both roots" "current=/nix/store/g2,new=-,previous=/nix/store/g1" "$(state)"
ln -s /nix/store/g2 "${R}/vw.new"; promote vw 1
ck "rebuilding the same system does not lose previous" "current=/nix/store/g2,new=-,previous=/nix/store/g1" "$(state)"

# ── release_move_to ──────────────────────────────────────────────────────────
mkdir -p "${TMP}/sys"; printf '26.05.20260924.c508844\n' > "${TMP}/sys/nixos-version"
move() { RUNNING="$1" bash -c 'source "$1"; ssh() { echo "${RUNNING}"; }; release_move_to 10.2.0.9 "$2"' _ "${TMP}/fns.sh" "${TMP}/sys"; }
ck "a guest on 25.11 receiving 26.05 is a release move" "25.11 26.05" "$(move 25.11)"
ck "the same release is not a move" "" "$(move 26.05)"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
