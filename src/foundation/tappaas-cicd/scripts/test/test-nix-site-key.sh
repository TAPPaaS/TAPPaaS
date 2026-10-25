#!/usr/bin/env bash
#
# test-nix-site-key.sh — the site's Nix signing key and signed guest copies (ADR-033 D8).
#
# Offline, with a stubbed nix, sudo and ssh: no key is generated with real Nix
# and nothing is copied. What it pins:
#   lib/nix-site-key.sh   the pair is created once (secret 0600, public 0644),
#                         kept on the next run, the public half re-derived when
#                         lost or wrong, named after the site; signing
#                         is recursive with the secret key file.
#   render_site_nix       carries the public key when there is a valid one, and
#                         nothing that could break out of the Nix string.
#   update-os.sh          the closure is signed before it is copied; a guest that
#                         trusts the key gets a checked copy, one that does not
#                         gets the one unchecked copy that teaches it; nothing is
#                         copied when signing fails; the guest-side fallback
#                         fetches nixpkgs by the lock's narHash, never a bare URL.
#   the baseline          asserts require-sigs and cache.nixos.org's key.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CICD="${HERE}/../.."
LIB="${CICD}/lib/nix-site-key.sh"
UOS="${CICD}/manager/health-manager/update-os.sh"
BASE="${CICD}/../templates/tappaas-common.nix"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
yes_if() { if eval "$1"; then echo yes; else echo no; fi; }

command -v jq >/dev/null || { echo "jq not found — cannot run here."; exit 77; }
W="$(mktemp -d "${TMPDIR:-/tmp}/nix-site-key.XXXXXX")"
trap 'rm -rf "${W}"' EXIT INT TERM

# A stub nix: generate-secret prints "<name>:<random>", the public half is the
# same body (a stand-in derivation), and every call is logged.
mkdir -p "${W}/bin"
cat > "${W}/bin/nix" <<'STUB'
#!/usr/bin/env bash
echo "nix $*" >> "${NIX_LOG}"
case "$1 $2" in
    "key generate-secret") printf '%s:%s' "$4" "$(head -c 32 /dev/urandom | base64)" ;;
    "key convert-secret-to-public") cat ;;
    "store sign") if [[ -z "${SIGN_FAILS:-}" ]]; then echo "added 3 signatures"; else echo "error: cannot sign" >&2; exit 1; fi ;;
esac
STUB
chmod +x "${W}/bin/nix"
export NIX_LOG="${W}/nix.log"; : > "${NIX_LOG}"

# run <shell snippet> — the library loaded, as "root", against a key dir in ${W}.
run() {
    PATH="${W}/bin:${PATH}" NIX_SITE_KEY_DIR="${W}/etc-nix" TAPPAAS_CONFIG="${W}/config" \
        bash -c 'id() { echo 0; }; export -f id; . "$1"; eval "$2"' _ "${LIB}" "$1"
}
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

echo "== the key pair =="
mkdir -p "${W}/config"; printf '{"name":"rossen","displayName":"Rossen"}' > "${W}/config/site.json"
run nix_site_key_ensure; ck "ensure succeeds on a site with no key" 0 $?
SEC="${W}/etc-nix/tappaas-site-signing.sec"; PUB="${W}/etc-nix/tappaas-site-signing.pub"
ck "the secret key exists, 0600" 600 "$(mode "${SEC}")"
ck "the public key exists, 0644" 644 "$(mode "${PUB}")"
ck "the key is named after the site" "tappaas-rossen-1" "$(cut -d: -f1 "${PUB}")"
ck "the public key is the secret's public half" "$(cat "${SEC}")" "$(head -n 1 "${PUB}")"
ck "nix_site_key_public prints it" "$(head -n 1 "${PUB}")" "$(run nix_site_key_public)"

before="$(cat "${SEC}")"; : > "${NIX_LOG}"
run nix_site_key_ensure
ck "a second run keeps the key" "${before}" "$(cat "${SEC}")"
ck "…and generates nothing" 0 "$(grep -c 'generate-secret' "${NIX_LOG}")"

rm -f "${PUB}"; run nix_site_key_ensure
ck "a lost public half is re-derived from the secret" "${before}" "$(head -n 1 "${PUB}")"
echo "other-1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" > "${PUB}"; run nix_site_key_ensure
ck "a public half that does not match is corrected" "${before}" "$(head -n 1 "${PUB}")"

printf '{}' > "${W}/config/site.json"
ck "no site name: the host name names it" "tappaas-$(hostname | tr -d '\n' | tr -c 'A-Za-z0-9.-' '-')-1" "$(run nix_site_key_name)"
printf '{"name":"a:b c"}' > "${W}/config/site.json"
ck "a ':' cannot reach the key name" "tappaas-a-b-c-1" "$(run nix_site_key_name)"

echo 'evil"; }; x = { "a:b' > "${W}/bad.pub"
ck "a public key that is not one is refused" "1" "$(NIX_SITE_KEY_PUBLIC="${W}/bad.pub" run 'nix_site_key_public >/dev/null; echo $?')"

: > "${NIX_LOG}"; run 'nix_site_key_sign /nix/store/aaaa-nixos-system-vw'
ck "signing is recursive, with the secret key file" \
   "nix store sign --key-file ${SEC} --recursive /nix/store/aaaa-nixos-system-vw" "$(cat "${NIX_LOG}")"
ck "…and Nix's 'added N signatures' is not printed" "" "$(run 'nix_site_key_sign /nix/store/aaaa-nixos-system-vw' 2>&1)"
ck "…but is there for debug" "nix store sign: added 3 signatures" \
   "$(run 'debug() { echo "$*"; }; nix_site_key_sign /nix/store/aaaa-nixos-system-vw' 2>&1)"
ck "a failed signing says what Nix said, and fails" "error: cannot sign|1" \
   "$(SIGN_FAILS=1 run 'nix_site_key_sign /nix/store/aaaa-nixos-system-vw; echo "|$?"' 2>&1 | tr -d '\n')"

echo "== the key reaches the guest through tappaas-site.nix =="
printf '{"location":{"timezone":"UTC"}}' > "${W}/config/site.json"
render() { NIX_SITE_KEY_PUBLIC="$1" TAPPAAS_CONFIG="${W}/config" bash -c '. "$1"; render_site_nix ""' _ "${CICD}/lib/site-locale.sh"; }
out="$(render "${PUB}")"
ck "the fragment trusts the site key" "yes" "$(yes_if 'grep -qF "nix.settings.trusted-public-keys = [ \"${before}\" ];" <<<"${out}"')"
ck "no key yet: the fragment says nothing about keys" "no" "$(yes_if 'grep -q trusted-public-keys <<<"$(render "${W}/none.pub")"')"
ck "a malformed key is not written into Nix" "no" "$(yes_if 'grep -q trusted-public-keys <<<"$(render "${W}/bad.pub")"')"

echo "== update-os.sh signs before it copies =="
for fn in guest_build_on_cicd guest_trusts_site_key guest_pinned_nixpkgs; do
    awk -v f="${fn}() {" '$0 == f {p=1} p {print} p && /^}$/ {exit}' "${UOS}" >> "${W}/uos.sh"
done
ck "the three helpers extract" "3" "$(grep -c '^[a-z_]*() {$' "${W}/uos.sh")"

KEY="tappaas-rossen-1:$(head -c 32 /dev/urandom | base64)"
# copy <guest nix.conf trusted-public-keys line> [sign fails] — prints the nix
# calls that reached the copy, and the function's exit code.
copy() {
    : > "${NIX_LOG}"
    CONF="$1" KEY="${KEY}" SIGN_FAILS="${2:-}" PATH="${W}/bin:${PATH}" GUEST_BUILD_STAGE="${W}/stage" \
        GUEST_BUILD_GCROOTS="${W}/roots" bash -c '
        . "$1"
        sudo() { [[ "$1" == -n ]] && shift; case "$1" in rm|install|tar) return 0 ;; esac; return 0; }
        ssh() { case "${*: -1}" in "cat /etc/nix/nix.conf") printf "%s\n" "${CONF}" ;; *) return 0 ;; esac; }
        tar() { :; }; warn() { echo "WARN $*" >&2; }; info() { :; }
        binary_cache_reachable() { return 0; }
        run_quiet_rc() { shift; "$@"; }
        readlink() { echo /nix/store/bbbb-nixos-system-vw-26.05; }
        nix_site_key_ensure() { :; }; nix_site_key_public() { printf "%s" "${KEY}"; }
        nix_site_key_sign() { nix store sign --key-file k --recursive "$1"; }
        guest_build_on_cicd vw 10.2.0.9 vw.nix /nix/store/src >/dev/null 2>"$2"; echo "rc=$?"' _ "${W}/uos.sh" "${W}/stderr"
    grep -E '^nix (copy|store)' "${NIX_LOG}"
}
out="$(copy "trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= ${KEY}")"
ck "the closure is signed before the copy" "yes" "$(yes_if '[[ "$(grep -m1 "^nix " <<<"${out}")" == "nix store sign --key-file k --recursive /nix/store/bbbb-nixos-system-vw-26.05" ]]')"
ck "a guest that trusts the key gets a checked copy" "nix copy --to ssh-ng://tappaas@10.2.0.9 /nix/store/bbbb-nixos-system-vw-26.05" "$(grep '^nix copy' <<<"${out}")"
ck "…and the copy succeeds" "yes" "$(yes_if 'grep -q "^rc=0" <<<"$(copy "trusted-public-keys = ${KEY}")"')"
out="$(copy "trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=")"
ck "a guest that has not learnt the key gets one unchecked copy" "nix copy --no-check-sigs --to ssh-ng://tappaas@10.2.0.9 /nix/store/bbbb-nixos-system-vw-26.05" "$(grep '^nix copy' <<<"${out}")"
ck "…and the run says so" "yes" "$(yes_if 'grep -q "does not trust the site" "${W}/stderr"')"
out="$(copy "trusted-public-keys = ${KEY}x")"
ck "a key that only starts the same is not trust" "yes" "$(yes_if 'grep -q -- "--no-check-sigs" <<<"${out}"')"
out="$(copy "trusted-public-keys = ${KEY}" fail)"
ck "signing fails: nothing is copied" "" "$(grep '^nix copy' <<<"${out}")"
ck "…and the build is not returned" "yes" "$(yes_if 'grep -q "^rc=1" <<<"${out}"')"

echo "== the guest-side fallback fetches nixpkgs by narHash =="
NH="sha256-$(head -c 32 /dev/urandom | base64)"
cat > "${W}/flake.lock" <<EOF
{ "nodes": { "nixpkgs": { "locked": { "type": "github", "owner": "NixOS", "repo": "nixpkgs",
  "rev": "c508844df6c28fa6dabc1b6af70f3ccbd65c5201", "narHash": "${NH}" } } } }
EOF
pinned() { REPLY_PATH="$2" SENT="${W}/sent" bash -c '. "$1"; ssh() { echo "${*: -1}" > "${SENT}"; printf "%s" "${REPLY_PATH}"; }
    guest_pinned_nixpkgs 10.2.0.9 "$2"; echo " rc=$?"' _ "${W}/uos.sh" "$1"; }
out="$(pinned "${W}/flake.lock" /nix/store/0123456789abcdfghijklmnpqrsvwxyz-source)"
ck "the guest is asked for fetchTarball with the lock's narHash" \
   "nix eval --impure --raw --expr 'builtins.fetchTarball { url = \"https://github.com/NixOS/nixpkgs/archive/c508844df6c28fa6dabc1b6af70f3ccbd65c5201.tar.gz\"; sha256 = \"${NH}\"; }'" \
   "$(cat "${W}/sent")"
ck "…and its store path comes back" "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-source rc=0" "${out}"
ck "an answer that is not a store path fails" "rc=1" "$(pinned "${W}/flake.lock" "error: hash mismatch" | tr -d ' ')"
jq 'del(.nodes.nixpkgs.locked.narHash)' "${W}/flake.lock" > "${W}/nohash.lock"
ck "a lock without narHash: no fetch at all" "rc=1" "$(rm -f "${W}/sent"; pinned "${W}/nohash.lock" x | tr -d ' ')$(test -f "${W}/sent" && echo SENT)"
jq '.nodes.nixpkgs.locked.owner = "x\"; y = \"z"' "${W}/flake.lock" > "${W}/evil.lock"
ck "a lock field that would escape the expression is refused" "rc=1" "$(pinned "${W}/evil.lock" x | tr -d ' ')"
ck "update-os.sh names no nixpkgs tarball outside a fetchTarball with its hash" "" \
   "$(grep -n 'nixpkgs/archive' "${UOS}" | grep -v 'fetchTarball' || true)"
ck "--no-check-sigs appears only behind the trust check" "1" "$(grep -c 'check=(--no-check-sigs)' "${UOS}")"
ck "…and nowhere else" "1" "$(grep -v '^[[:space:]]*#' "${UOS}" | grep -c -- '--no-check-sigs')"

echo "== the baseline =="
ck "require-sigs is set" "1" "$(grep -c '^  nix.settings.require-sigs = true;' "${BASE}")"
ck "…and asserted" "1" "$(grep -c 'assertion = config.nix.settings.require-sigs == true' "${BASE}")"
ck "cache.nixos.org's key is trusted" "yes" "$(yes_if 'grep -q "trusted-public-keys = \[ \"cache.nixos.org-1:" "${BASE}"')"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
