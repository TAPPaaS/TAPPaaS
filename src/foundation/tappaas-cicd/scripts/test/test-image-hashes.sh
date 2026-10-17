#!/usr/bin/env bash
#
# test-image-hashes.sh — images are checked by hash before they are used (ADR-033 D7).
#
# The image pointers (templates/tappaas-nixos.json, network/network.json) carry
# imageSha256 next to imageLocation; release/bump-version.sh writes it from the
# release's SHA256SUMS after checking SHA256SUMS.sig, and
# release/sign-image-release.sh makes that signature. A download is compared
# against the hash before it is imported — Create-TAPPaaS-VM.sh on the node, and
# templates/update.sh before it replaces the template — and refused on a
# mismatch; a pointer without a hash is warned about and used (transition).
# cluster/make-install-media.sh checks the Proxmox ISO against Proxmox's
# SHA256SUMS and the install assistant through the signed repository index.
#
# Tabletop: fixture files under a temp dir, file:// URLs, a throwaway SSH key,
# stubbed gh and gpgv. No network, no cluster.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../../../../.." && pwd)"
CREATE="${ROOT}/src/foundation/cluster/Create-TAPPaaS-VM.sh"
MEDIA="${ROOT}/src/foundation/cluster/make-install-media.sh"
TUPDATE="${ROOT}/src/foundation/templates/update.sh"
[[ -f "${CREATE}" && -f "${MEDIA}" && -f "${TUPDATE}" && -f "${ROOT}/release/bump-version.sh" ]] || {
    echo "scripts not found beside this suite — cannot run here."; exit 77; }
for _c in jq git ssh-keygen curl; do
    command -v "${_c}" >/dev/null 2>&1 || { echo "${_c} not found — cannot run here."; exit 77; }
done

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
ck()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/imagehashes.XXXXXX")"
trap 'rm -rf "${T}"' EXIT

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

# The functions under test, cut from the shipped scripts so this cannot drift.
block() { sed -n "/^# >>> $2/,/^# <<< $2/p" "$1"; }
STUBS='info() { echo "INFO $*"; }; warn() { echo "WARN $*"; }; error() { echo "ERROR $*"; }; die() { echo "DIE $*"; exit 1; }'

printf 'a disk image\n' >"${T}/img.qcow2.zst"
GOOD="$(sha "${T}/img.qcow2.zst")"
OTHER="$(printf 'x' | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | awk '{print $1}')"

echo "── Create-TAPPaaS-VM.sh: image_sha256_check ──"
CB="$(block "${CREATE}" 'image-sha256')"
[[ -n "${CB}" ]] && ok "the hash block is marked in Create-TAPPaaS-VM.sh" || bad "no image-sha256 block in Create-TAPPaaS-VM.sh"
check() { ( eval "${STUBS}"; eval "${CB}"; image_sha256_check "$@" ) 2>&1; }

cp "${T}/img.qcow2.zst" "${T}/a"; out="$(check "${T}/a" "${GOOD}")"; rc=$?
ck "matching hash passes" "0" "${rc}"
[[ -f "${T}/a" ]] && ok "the verified file stays" || bad "the verified file was removed"
cp "${T}/img.qcow2.zst" "${T}/a"; out="$(check "${T}/a" "sha256:$(printf '%s' "${GOOD}" | tr '[:lower:]' '[:upper:]')")"; rc=$?
ck "sha256: prefix and upper case are accepted" "0" "${rc}"
cp "${T}/img.qcow2.zst" "${T}/a"; out="$(check "${T}/a" "${OTHER}")"; rc=$?
ck "mismatch stops the run" "1" "${rc}"
[[ ! -e "${T}/a" ]] && ok "the mismatching download is removed" || bad "the mismatching download is still there"
[[ "${out}" == *"mismatch"* && "${out}" == *"${OTHER}"* ]] && ok "the refusal names the expected hash" || bad "refusal text: ${out}"
cp "${T}/img.qcow2.zst" "${T}/a"; out="$(check "${T}/a" "")"; rc=$?
ck "no recorded hash passes (transition)" "0" "${rc}"
[[ "${out}" == WARN*"imageSha256"* ]] && ok "… with a warning" || bad "no warning without a hash: ${out}"
cp "${T}/img.qcow2.zst" "${T}/a"; out="$(check "${T}/a" "deadbeef")"; rc=$?
ck "a malformed hash is refused" "1" "${rc}"

echo "── Create-TAPPaaS-VM.sh: every download is checked, the hash is read from the JSON ──"
_dl="$(grep -c 'curl -fSLo' "${CREATE}")"
_ck="$(grep -A1 'curl -fSLo' "${CREATE}" | grep -c 'image_sha256_check')"
[[ "${_dl}" -ge 4 && "${_dl}" -eq "${_ck}" ]] && ok "all ${_dl} curl -fSLo downloads are followed by the check" \
    || bad "${_ck} of ${_dl} downloads are checked"
_read="$(grep -m1 '^  IMAGESHA256=' "${CREATE}")"
JSON='{"vmname":"x","config":{"cluster:vm":{"image":"i","imageLocation":"https://e/","imageSha256":"'"${GOOD}"'"}}}'
eval "${_read}"; ck "imageSha256 is read from a Pattern-A config block" "${GOOD}" "${IMAGESHA256}"
JSON='{"vmname":"x","imageSha256":"'"${OTHER}"'","config":{"cluster:vm":{"image":"i"}}}'
eval "${_read}"; ck "… and from the flat form" "${OTHER}" "${IMAGESHA256}"
JSON='{"vmname":"x","config":{"cluster:vm":{"image":"i"},"other:svc":"str"}}'
eval "${_read}"; ck "… and is empty when absent" "" "${IMAGESHA256}"

echo "── templates/update.sh: download + check before the template is destroyed ──"
PF="$(sed -n '/^prefetch_image() {/,/^}/p' "${TUPDATE}")"
_pf_line="$(grep -n '^prefetch_image "' "${TUPDATE}" | cut -d: -f1)"
_destroy_line="$(grep -n 'qm destroy' "${TUPDATE}" | head -1 | cut -d: -f1)"
[[ -n "${_pf_line}" && -n "${_destroy_line}" && "${_pf_line}" -lt "${_destroy_line}" ]] \
    && ok "the image is checked before qm destroy" || bad "prefetch (${_pf_line:-none}) is not before qm destroy (${_destroy_line:-none})"
if command -v sha256sum >/dev/null 2>&1 && sha256sum --status -c /dev/null 2>/dev/null <<<"" || sha256sum --help 2>&1 | grep -q -- '--status'; then
    prefetch() { ( eval "${STUBS}"; node_run() { bash -c "$*"; }; NODE=n1; NIX_JSON=x.json
                   IMAGE_PREFETCH_DIR="${T}/node"; eval "${PF}"; prefetch_image "$@" ) 2>&1; }
    out="$(prefetch "file://${T}/img.qcow2.zst" img.qcow2.zst "${GOOD}")"; rc=$?
    ck "a matching image is staged for Create-TAPPaaS-VM.sh" "0" "${rc}"
    [[ -f "${T}/node/img.qcow2.zst" && ! -e "${T}/node/img.qcow2.zst.part" ]] && ok "… as the final name, no .part left" || bad "staged files: $(ls "${T}/node" 2>&1)"
    out="$(prefetch "file://${T}/img.qcow2.zst" img.qcow2.zst "${OTHER}")"; rc=$?
    ck "a mismatching image stops the update" "1" "${rc}"
    [[ -z "$(ls -A "${T}/node" 2>/dev/null)" ]] && ok "… and leaves nothing behind (old copy and .part removed)" || bad "left behind: $(ls "${T}/node")"
    out="$(prefetch "file://${T}/missing" img.qcow2.zst "${GOOD}")"; rc=$?
    ck "a failed download stops the update" "1" "${rc}"
    out="$(prefetch "file://${T}/img.qcow2.zst" img.qcow2.zst "")"; rc=$?
    ck "no recorded hash: warn and continue" "0" "${rc}"
    [[ "${out}" == WARN* ]] && ok "… with a warning" || bad "no warning: ${out}"
else
    echo "  skip: no GNU sha256sum (--status) here — the node-side prefetch runs on the test site"
fi

echo "── release/bump-version.sh: writes the hash from (signed) SHA256SUMS ──"
R="${T}/repo"
mkdir -p "${R}/release" "${R}/src/foundation/templates" "${R}/src/foundation/network" "${R}/.tappaas"
cp "${ROOT}/release/bump-version.sh" "${ROOT}/release/lib.sh" "${ROOT}/release/sign-image-release.sh" "${R}/release/"
cp "${ROOT}/src/foundation/templates/tappaas-nixos.json" "${R}/src/foundation/templates/"
cp "${ROOT}/src/foundation/network/network.json" "${R}/src/foundation/network/"
printf '# no keys yet\n' >"${R}/.tappaas/allowed_signers"
git -C "${R}" init -q && git -C "${R}" add -A && git -C "${R}" -c user.email=t@t -c user.name=t commit -qm fixture
NJ="${R}/src/foundation/templates/tappaas-nixos.json"
OJ="${R}/src/foundation/network/network.json"
REL="${T}/rel"
mkrel() {  # mkrel <tag> <asset> — a release dir with the asset and SHA256SUMS
    mkdir -p "${REL}/$1"; printf 'image of %s\n' "$1" >"${REL}/$1/$2"
    ( cd "${REL}/$1" && printf '%s  %s\n' "$(sha "$2")" "$2" >SHA256SUMS )
}
bump() { ( cd "${R}" && TAPPAAS_IMAGE_RELEASE_BASE="file://${REL}" ./release/bump-version.sh "$@" ) 2>&1; }
field() { jq -r ".config.\"cluster:vm\".$2 // empty" "$1"; }

mkrel nixos-template-v9.1 tappaas-nixos.qcow2.zst
mkrel opnsense-firewall-v9.2 tappaas-firewall.qcow2.zst
out="$(bump --nixos 9.1 --opnsense 9.2)"; rc=$?
ck "bump from unsigned SHA256SUMS (no signers yet) succeeds" "0" "${rc}"
[[ "${out}" == *"not signed"* ]] && ok "… warning that SHA256SUMS is unsigned" || bad "no unsigned warning: ${out}"
ck "NixOS pointer: version" "9.1" "$(jq -r .version "${NJ}")"
ck "NixOS pointer: sha256" "$(sha "${REL}/nixos-template-v9.1/tappaas-nixos.qcow2.zst")" "$(field "${NJ}" imageSha256)"
ck "OPNsense pointer: sha256" "$(sha "${REL}/opnsense-firewall-v9.2/tappaas-firewall.qcow2.zst")" "$(field "${OJ}" imageSha256)"
ck "imageSha256 sits right after imageLocation" "imageLocation imageSha256" \
    "$(jq -r '.config."cluster:vm" | keys_unsorted | . as $k | (index("imageLocation")) as $i | "\($k[$i]) \($k[$i+1])"' "${NJ}")"
ck "the rest of the file is untouched" "" \
    "$(cd "${R}" && git diff -U0 -- src/foundation/network/network.json | grep '^[-+] ' | grep -v 'imageLocation\|imageSha256')"
before="$(cat "${NJ}")"; out="$(bump --nixos 9.1)"
ck "a second bump to the same release changes nothing" "${before}" "$(cat "${NJ}")"
out="$(bump --check)"; rc=$?
[[ "${out}" == *"sha256=$(field "${NJ}" imageSha256)"* ]] && ok "--check reports the recorded hash" || bad "--check: ${out}"

before="$(cat "${NJ}")"
out="$(bump --nixos 9.1 --nixos-sha256 not-a-hash)"; rc=$?
ck "a malformed --nixos-sha256 is refused" "1" "${rc}"
ck "… and the pointer is unchanged" "${before}" "$(cat "${NJ}")"
out="$(bump --nixos 9.1 --nixos-sha256 "SHA256:$(printf '%s' "${OTHER}" | tr '[:lower:]' '[:upper:]')")"; rc=$?
ck "an explicit --nixos-sha256 is used as given" "${OTHER}" "$(field "${NJ}" imageSha256)"
out="$(bump --nixos 7.0)"; rc=$?
ck "a release without SHA256SUMS is refused" "1" "${rc}"
mkdir -p "${REL}/nixos-template-v9.3"; printf '%s  other.img\n' "${GOOD}" >"${REL}/nixos-template-v9.3/SHA256SUMS"
out="$(bump --nixos 9.3)"; rc=$?
ck "SHA256SUMS that does not list the image is refused" "1" "${rc}"
out="$(bump --nixos-sha256 "${GOOD}")"; rc=$?
ck "--nixos-sha256 without --nixos is a usage error" "1" "${rc}"

echo "── … once allowed_signers lists a key, SHA256SUMS must be signed ──"
ssh-keygen -q -t ed25519 -N '' -C test-signer -f "${T}/key" >/dev/null
printf 'tester@tappaas.org namespaces="git,tappaas-image" %s\n' "$(cut -d' ' -f1,2 "${T}/key.pub")" >"${R}/.tappaas/allowed_signers"
mkrel nixos-template-v9.4 tappaas-nixos.qcow2.zst
out="$(bump --nixos 9.4)"; rc=$?
ck "unsigned SHA256SUMS is refused" "1" "${rc}"
[[ "${out}" == *"sign-image-release.sh"* ]] && ok "… pointing at sign-image-release.sh" || bad "refusal text: ${out}"
ssh-keygen -q -Y sign -f "${T}/key" -n tappaas-image "${REL}/nixos-template-v9.4/SHA256SUMS" >/dev/null 2>&1
out="$(bump --nixos 9.4)"; rc=$?
ck "signed SHA256SUMS is accepted" "0" "${rc}"
[[ "${out}" == *"signed by tester@tappaas.org"* ]] && ok "… and names its signer" || bad "no signer named: ${out}"
ck "… and its hash is written" "$(sha "${REL}/nixos-template-v9.4/tappaas-nixos.qcow2.zst")" "$(field "${NJ}" imageSha256)"
printf '%s  tappaas-nixos.qcow2.zst\n' "${OTHER}" >"${REL}/nixos-template-v9.4/SHA256SUMS"
out="$(bump --nixos 9.4)"; rc=$?
ck "SHA256SUMS changed after signing is refused" "1" "${rc}"
mkrel nixos-template-v9.5 tappaas-nixos.qcow2.zst
ssh-keygen -q -Y sign -f "${T}/key" -n git "${REL}/nixos-template-v9.5/SHA256SUMS" >/dev/null 2>&1
out="$(bump --nixos 9.5)"; rc=$?
ck "a signature in another namespace is refused" "1" "${rc}"
ssh-keygen -q -t ed25519 -N '' -f "${T}/stranger" >/dev/null
mkrel nixos-template-v9.6 tappaas-nixos.qcow2.zst
ssh-keygen -q -Y sign -f "${T}/stranger" -n tappaas-image "${REL}/nixos-template-v9.6/SHA256SUMS" >/dev/null 2>&1
out="$(bump --nixos 9.6)"; rc=$?
ck "a signature by an unlisted key is refused" "1" "${rc}"

echo "── release/sign-image-release.sh (gh stubbed) ──"
GHD="${T}/gh"; mkdir -p "${GHD}/bin"
cat >"${GHD}/bin/gh" <<'GH'
#!/usr/bin/env bash
# Stub: a release at $GH_FIXTURE/<tag>/, its asset digests in $GH_FIXTURE/<tag>.tsv.
case "$1 $2" in
  "api repos/"*) tag="${2##*/}"; [[ -f "${GH_FIXTURE}/${tag}.tsv" ]] || exit 1; cat "${GH_FIXTURE}/${tag}.tsv" ;;
  "release download")
    tag="$3"; shift 3; pat="" dir="."
    while [[ $# -gt 0 ]]; do case "$1" in -p) pat="$2"; shift 2 ;; -D) dir="$2"; shift 2 ;; *) shift ;; esac; done
    [[ -f "${GH_FIXTURE}/${tag}/${pat}" ]] || exit 1; mkdir -p "${dir}"; cp "${GH_FIXTURE}/${tag}/${pat}" "${dir}/" ;;
  "release upload")
    tag="$3"; shift 3; for f in "$@"; do [[ -f "$f" ]] && cp "$f" "${GH_FIXTURE}/uploaded-${tag}-$(basename "$f")"; done ;;
  *) exit 2 ;;
esac
GH
chmod +x "${GHD}/bin/gh"
export GH_FIXTURE="${GHD}"
ghrel() {  # ghrel <tag> <asset> [<digest override>] [nosums]
    mkdir -p "${GHD}/$1"; printf 'built %s\n' "$1" >"${GHD}/$1/$2"
    printf '%s\t%s\n' "$2" "sha256:${3:-$(sha "${GHD}/$1/$2")}" >"${GHD}/$1.tsv"
    [[ "${4:-}" == nosums ]] || ( cd "${GHD}/$1" && printf '%s  %s\n' "$(sha "$2")" "$2" >SHA256SUMS )
}
signrel() { ( cd "${R}" && PATH="${GHD}/bin:${PATH}" ./release/sign-image-release.sh "$@" ) 2>&1; }

ghrel nixos-template-v9.7 tappaas-nixos.qcow2.zst
out="$(signrel nixos-template-v9.7 --key "${T}/key")"; rc=$?
ck "a consistent release is signed" "0" "${rc}"
U="${GHD}/uploaded-nixos-template-v9.7-SHA256SUMS.sig"
if [[ -f "${U}" ]] && ssh-keygen -Y verify -f "${R}/.tappaas/allowed_signers" -I tester@tappaas.org \
        -n tappaas-image -s "${U}" <"${GHD}/nixos-template-v9.7/SHA256SUMS" >/dev/null 2>&1; then
    ok "… and the uploaded SHA256SUMS.sig verifies (namespace tappaas-image)"
else
    bad "uploaded signature missing or not verifying: ${out}"
fi
cp "${U}" "${GHD}/nixos-template-v9.7/SHA256SUMS.sig" 2>/dev/null
mkdir -p "${REL}/nixos-template-v9.7"; cp "${GHD}/nixos-template-v9.7/"* "${REL}/nixos-template-v9.7/"
out="$(bump --nixos 9.7)"; rc=$?
ck "bump-version accepts what sign-image-release signed" "0" "${rc}"

ghrel nixos-template-v9.8 tappaas-nixos.qcow2.zst "${OTHER}"
out="$(signrel nixos-template-v9.8 --key "${T}/key")"; rc=$?
ck "SHA256SUMS that disagrees with the release's digest is not signed" "1" "${rc}"
[[ ! -e "${GHD}/uploaded-nixos-template-v9.8-SHA256SUMS.sig" ]] && ok "… and nothing is uploaded" || bad "a signature was uploaded"
ghrel nixos-template-v9.9 tappaas-nixos.qcow2.zst
printf 'x\n' >"${GHD}/nixos-template-v9.9/extra.bin"
printf 'extra.bin\tsha256:%s\n' "$(sha "${GHD}/nixos-template-v9.9/extra.bin")" >>"${GHD}/nixos-template-v9.9.tsv"
out="$(signrel nixos-template-v9.9 --key "${T}/key")"; rc=$?
ck "a release artefact missing from SHA256SUMS is not signed" "1" "${rc}"
ghrel nixos-template-v9.10 tappaas-nixos.qcow2.zst "" nosums
out="$(signrel nixos-template-v9.10 --key "${T}/key")"; rc=$?
ck "no SHA256SUMS and no --generate is refused" "1" "${rc}"
out="$(signrel nixos-template-v9.10 --key "${T}/key" --generate --dry-run)"; rc=$?
ck "--generate --dry-run hashes and signs" "0" "${rc}"
[[ ! -e "${GHD}/uploaded-nixos-template-v9.10-SHA256SUMS.sig" ]] && ok "… and --dry-run uploads nothing" || bad "--dry-run uploaded"
out="$(signrel nixos-template-v9.10 --key "${T}/key" --generate)"; rc=$?
[[ "${rc}" -eq 0 && -f "${GHD}/uploaded-nixos-template-v9.10-SHA256SUMS" && -f "${GHD}/uploaded-nixos-template-v9.10-SHA256SUMS.sig" ]] \
    && ok "--generate uploads SHA256SUMS and its signature" || bad "--generate: rc=${rc} ${out}"
ghrel nixos-template-v9.11 tappaas-nixos.qcow2.zst
out="$(signrel nixos-template-v9.11 --key "${T}/stranger")"; rc=$?
ck "a key not in allowed_signers is refused" "1" "${rc}"
[[ ! -e "${GHD}/uploaded-nixos-template-v9.11-SHA256SUMS.sig" ]] && ok "… before anything is uploaded" || bad "a stranger's signature was uploaded"

echo "── make-install-media.sh: ISO and assistant .deb ──"
MB="$(block "${MEDIA}" 'media-checks')"
[[ -n "${MB}" ]] && ok "the checks block is marked in make-install-media.sh" || bad "no media-checks block"
M="${T}/media"; mkdir -p "${M}/iso" "${M}/keys" "${M}/repo/dists/trixie/pve-no-subscription/binary-amd64" "${M}/repo/pool" "${M}/bin"
printf 'pve iso\n' >"${M}/proxmox-ve_9.2-1.iso"
printf '%s  proxmox-ve_9.2-1.iso\n%s  proxmox-ve_9.1-1.iso\n' "$(sha "${M}/proxmox-ve_9.2-1.iso")" "${OTHER}" >"${M}/iso/SHA256SUMS"
media() { ( eval "${STUBS}"; PVE_ISO_SUMS_URL="${SUMS_URL:-file://${M}/iso/SHA256SUMS}" PVE_REPO_BASE="file://${M}/repo" \
            PVE_KEY_BASE="file://${M}/keys" PATH="${M}/bin:${PATH}"; eval "${MB}"; "$@" ) 2>&1; }
out="$(media iso_check "${M}/proxmox-ve_9.2-1.iso")"; rc=$?
ck "an ISO matching Proxmox's SHA256SUMS passes" "0" "${rc}"
cp "${M}/proxmox-ve_9.2-1.iso" "${M}/proxmox-ve_9.1-1.iso"
out="$(media iso_check "${M}/proxmox-ve_9.1-1.iso")"; rc=$?
ck "an ISO that does not match is refused" "1" "${rc}"
cp "${M}/proxmox-ve_9.2-1.iso" "${M}/renamed.iso"
out="$(media iso_check "${M}/renamed.iso")"; rc=$?
ck "an ISO not listed is refused" "1" "${rc}"
[[ "${out}" == *"--iso-sha256"* ]] && ok "… pointing at --iso-sha256" || bad "refusal text: ${out}"
out="$(media iso_check "${M}/renamed.iso" "$(sha "${M}/renamed.iso")")"; rc=$?
ck "--iso-sha256 checks an unlisted ISO" "0" "${rc}"
out="$(media iso_check "${M}/renamed.iso" "${OTHER}")"; rc=$?
ck "… and refuses a wrong one" "1" "${rc}"
out="$( SUMS_URL="file://${M}/nowhere" media iso_check "${M}/proxmox-ve_9.2-1.iso")"; rc=$?
ck "no reachable SHA256SUMS and no --iso-sha256 is refused" "1" "${rc}"

# The repository: a stub gpgv "verifies" InRelease when GPGV_OK=1 (no gpg needed here).
cat >"${M}/bin/gpgv" <<'G'
#!/usr/bin/env bash
out=""; last=""
while [[ $# -gt 0 ]]; do case "$1" in --output) out="$2"; shift 2 ;; --keyring) shift 2 ;; *) last="$1"; shift ;; esac; done
[[ "${GPGV_OK:-0}" == 1 ]] || exit 1
cp "${last}" "${out}"
G
chmod +x "${M}/bin/gpgv"
printf 'key\n' >"${M}/keys/proxmox-archive-keyring-trixie.gpg"
printf 'old deb\n' >"${M}/repo/pool/paia_9.0.6.deb"; printf 'new deb\n' >"${M}/repo/pool/paia_9.2.1.deb"
P="${M}/repo/dists/trixie/pve-no-subscription/binary-amd64/Packages"
mkpkgs() {  # mkpkgs <sha of the 9.2.1 deb>
    printf 'Package: proxmox-auto-install-assistant\nVersion: 9.0.6\nFilename: pool/paia_9.0.6.deb\nSHA256: %s\n\nPackage: other\nVersion: 1\nFilename: pool/o.deb\nSHA256: %s\n\nPackage: proxmox-auto-install-assistant\nVersion: 9.2.1\nFilename: pool/paia_9.2.1.deb\nSHA256: %s\n' \
        "$(sha "${M}/repo/pool/paia_9.0.6.deb")" "${OTHER}" "$1" >"${P}"
    printf 'Origin: Proxmox\nMD5Sum:\n 0 1 pve-no-subscription/binary-amd64/Packages\nSHA256:\n %s %s pve-no-subscription/binary-amd64/Packages\n' \
        "$(sha "${P}")" "$(wc -c <"${P}" | tr -d ' ')" >"${M}/repo/dists/trixie/InRelease"
}
mkpkgs "$(sha "${M}/repo/pool/paia_9.2.1.deb")"
mkdir -p "${M}/w"
out="$(GPGV_OK=1 media paia_fetch "${M}/w")"; rc=$?
ck "a signed index and matching .deb pass" "0" "${rc}"
ck "… the newest version is the one fetched" "new deb" "$(cat "${M}/w/paia.deb" 2>/dev/null)"
out="$(GPGV_OK=0 media paia_fetch "${M}/w")"; rc=$?
ck "an InRelease that does not verify is refused" "1" "${rc}"
printf 'tampered\n' >>"${P}"
out="$(GPGV_OK=1 media paia_fetch "${M}/w")"; rc=$?
ck "a Packages index that does not match InRelease is refused" "1" "${rc}"
mkpkgs "${OTHER}"; rm -f "${M}/w/paia.deb"
out="$(GPGV_OK=1 media paia_fetch "${M}/w")"; rc=$?
ck "a .deb that does not match its Packages entry is refused" "1" "${rc}"
[[ ! -e "${M}/w/paia.deb" ]] && ok "… and removed" || bad "the mismatching .deb was kept"
_iso_line="$(grep -n '^iso_check "\$ISO"' "${MEDIA}" | cut -d: -f1)"
_prep_line="$(grep -n 'prepare-iso "\$ISO"' "${MEDIA}" | cut -d: -f1)"
[[ -n "${_iso_line}" && -n "${_prep_line}" && "${_iso_line}" -lt "${_prep_line}" ]] \
    && ok "the ISO is checked before prepare-iso uses it" || bad "iso_check (${_iso_line:-none}) not before prepare-iso (${_prep_line:-none})"
grep -q 'paia_fetch "\${_PAIA_DIR}"' "${MEDIA}" && ok "the assistant is fetched only through paia_fetch" || bad "paia_fetch is not used for the assistant"

echo "── workflows publish SHA256SUMS and check their inputs ──"
for wf in build-nixos-template-image build-opnsense-image; do
    f="${ROOT}/.github/workflows/${wf}.yml"
    grep -q 'sha256sum .* > SHA256SUMS' "${f}" && grep -qE '^\s+SHA256SUMS$' "${f}" \
        && ok "${wf}: SHA256SUMS is made and published" || bad "${wf}: SHA256SUMS not published"
done
f="${ROOT}/.github/workflows/build-opnsense-image.yml"
grep -qE 'OPNSENSE_BASE_SHA256: "[0-9a-f]{64}"' "${f}" && grep -q 'sha256 -q base.qcow2.bz2' "${f}" \
    && ok "build-opnsense-image: the base image is pinned and checked before use" || bad "build-opnsense-image: base image not checked"
for f in "${ROOT}/src/foundation/templates/tappaas-nixos.json" "${ROOT}/src/foundation/network/network.json"; do
    [[ "$(jq -r '.config."cluster:vm".imageSha256 // ""' "${f}")" =~ ^[0-9a-f]{64}$ ]] \
        && ok "$(basename "${f}") records imageSha256" || bad "$(basename "${f}") has no imageSha256"
done

echo ""
echo "image hashes: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
