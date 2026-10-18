#!/usr/bin/env bash
#
# release/bump-version.sh — point the module configs at newly-built images.
#
# When a new NixOS-template or OPNsense-firewall image is published (a
# `nixos-template-v*` / `opnsense-firewall-v*` tag pushed to GitHub fires the
# Actions build → GitHub Release), the in-tree consumer pointers must be moved
# to the new tag. This script does that edit (via jq, byte-for-byte formatting
# preserved) and keeps tappaas-nixos.json's `version` in lockstep with its
# image tag.
#
#   templates/tappaas-nixos.json : .version + .config."cluster:vm".imageLocation
#                                  + .config."cluster:vm".imageSha256
#   network/network.json         : .config."cluster:vm".imageLocation
#                                  + .config."cluster:vm".imageSha256
#
# The image's SHA-256 is written next to its URL (ADR-033 D7): the install
# compares every download against it before importing. It comes from the
# release's SHA256SUMS, whose signature (SHA256SUMS.sig, see
# sign-image-release.sh) is checked against .tappaas/allowed_signers — required
# once that file lists a key — or from --nixos-sha256/--opnsense-sha256.
#
# Usage: bump-version.sh [options]
#
# Options:
#   --nixos <ver|tag>     Set the NixOS template to this version. Accepts
#                         "1.3" or "nixos-template-v1.3".
#   --opnsense <ver|tag>  Set the OPNsense firewall image. Accepts "1.2" or
#                         "opnsense-firewall-v1.2".
#   --nixos-sha256 <hex>  Use this SHA-256 for the NixOS image instead of the
#                         release's SHA256SUMS (a release published without one).
#   --opnsense-sha256 <hex>  The same for the OPNsense image.
#   --check               Report current pointers and flag any drift; make no
#                         changes. (Default action when no --nixos/--opnsense.)
#   -h, --help            Show this help.
#
# Exit codes: 0 ok · 2 usage error · 3 drift found (with --check).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

NIXOS_ARG=""
OPNSENSE_ARG=""
NIXOS_SHA=""
OPNSENSE_SHA=""
CHECK_ONLY=0

REL_NIXOS="src/foundation/templates/tappaas-nixos.json"
REL_OPNSENSE="src/foundation/network/network.json"
BASE_URL="${TAPPAAS_IMAGE_RELEASE_BASE:-https://github.com/TAPPaaS/TAPPaaS/releases/download}"
SIGNERS=".tappaas/allowed_signers"
REVOKED=".tappaas/revoked_signers"

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nixos)    NIXOS_ARG="${2:?--nixos needs a value}"; shift 2 ;;
        --opnsense) OPNSENSE_ARG="${2:?--opnsense needs a value}"; shift 2 ;;
        --nixos-sha256)    NIXOS_SHA="${2:?--nixos-sha256 needs a value}"; shift 2 ;;
        --opnsense-sha256) OPNSENSE_SHA="${2:?--opnsense-sha256 needs a value}"; shift 2 ;;
        --check)    CHECK_ONLY=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

[[ -z "${NIXOS_SHA}" || -n "${NIXOS_ARG}" ]] || die "--nixos-sha256 needs --nixos"
[[ -z "${OPNSENSE_SHA}" || -n "${OPNSENSE_ARG}" ]] || die "--opnsense-sha256 needs --opnsense"

require_cmd jq
cd "$(repo_root)"
[[ -f "${REL_NIXOS}" ]]    || die "not found: ${REL_NIXOS}"
[[ -f "${REL_OPNSENSE}" ]] || die "not found: ${REL_OPNSENSE}"

# normalise <prefix> <arg> — echo the full tag from either "1.3" or a full tag.
normalise() {
    local prefix="$1" arg="$2"
    [[ "${arg}" == "${prefix}"* ]] && { echo "${arg}"; return; }
    echo "${prefix}${arg}"
}

# get_loc <file> — current imageLocation. get_tag <prefix> <loc> — tag from URL.
get_loc() { jq -r '.config."cluster:vm".imageLocation // empty' "$1"; }
get_image() { jq -r '.config."cluster:vm".image // empty' "$1"; }
get_sha() { jq -r '.config."cluster:vm".imageSha256 // empty' "$1"; }
get_tag() { local l="${1%/}"; echo "${l##*/}"; }  # last path segment of the URL

set_json() {  # set_json <file> <jq-filter> ...args
    local file="$1"; shift
    local tmp; tmp="$(mktemp)"
    jq --indent 2 "$@" >"${tmp}" <"${file}"
    mv "${tmp}" "${file}"
}

# The jq that sets imageLocation and, right after it, imageSha256 ($l, $h).
# shellcheck disable=SC2016  # jq variables, not shell
readonly SET_IMAGE='.config."cluster:vm" |= (to_entries
    | map(select(.key != "imageSha256"))
    | map(if .key == "imageLocation"
          then {key: "imageLocation", value: $l}, {key: "imageSha256", value: $h}
          else . end)
    | from_entries)'

# normalise_sha <value> — bare lowercase hex, or die.
normalise_sha() {
    local h
    h="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    h="${h#sha256:}"
    [[ "${h}" =~ ^[0-9a-f]{64}$ ]] || die "not a SHA-256 hash: $1"
    printf '%s' "${h}"
}

# release_sha <loc> <image> — print the image's SHA-256 from the release's SHA256SUMS,
# after checking SHA256SUMS.sig against the signers on this branch. A signature
# is required once allowed_signers lists a key; before that it is checked when
# present and its absence is a warning (the repository signs nothing yet).
release_sha() {
    local loc="$1" image="$2" d h principals signed=0
    d="$(mktemp -d)"
    curl -fsSL "${loc}SHA256SUMS" -o "${d}/SHA256SUMS" 2>/dev/null || {
        rm -rf "${d}"
        die "no SHA256SUMS in ${loc} — pass the hash with --nixos-sha256/--opnsense-sha256"; }
    grep -qvE '^[[:space:]]*(#|$)' "${SIGNERS}" 2>/dev/null && signed=1
    if curl -fsSL "${loc}SHA256SUMS.sig" -o "${d}/SHA256SUMS.sig" 2>/dev/null; then
        [[ "${signed}" -eq 1 ]] || { rm -rf "${d}"; die "${loc}SHA256SUMS is signed, but ${SIGNERS} lists no key to check it with"; }
        # A key in revoked_signers never verifies (ssh-keygen -r), whatever it signed.
        local -a rev=()
        if grep -vE '^[[:space:]]*(#|$)' "${REVOKED}" >"${d}/revoked" 2>/dev/null; then rev=(-r "${d}/revoked"); fi
        principals="$(ssh-keygen -Y find-principals -f "${SIGNERS}" -n tappaas-image \
                        -s "${d}/SHA256SUMS.sig" 2>/dev/null | head -1 || true)"
        if [[ -z "${principals}" ]] || ! ssh-keygen -Y verify -f "${SIGNERS}" -I "${principals}" ${rev[@]+"${rev[@]}"} \
                -n tappaas-image -s "${d}/SHA256SUMS.sig" <"${d}/SHA256SUMS" >/dev/null 2>&1; then
            rm -rf "${d}"
            die "SHA256SUMS.sig in ${loc} does not verify against ${SIGNERS} (namespace tappaas-image), or its key is revoked"
        fi
        info "SHA256SUMS signed by ${principals}" >&2
    elif [[ "${signed}" -eq 1 ]]; then
        rm -rf "${d}"
        die "${loc}SHA256SUMS is not signed — run release/sign-image-release.sh first"
    else
        warn "SHA256SUMS in ${loc} is not signed (${SIGNERS} lists no key yet)"
    fi
    h="$(awk -v f="${image}" '{n=$2; sub(/^\*/, "", n)} n == f {print $1; exit}' "${d}/SHA256SUMS")"
    rm -rf "${d}"
    [[ -n "${h}" ]] || die "${image} is not listed in ${loc}SHA256SUMS"
    normalise_sha "${h}"
}

# ── --check / default: report state and drift ────────────────────────
if [[ "${CHECK_ONLY}" -eq 1 || ( -z "${NIXOS_ARG}" && -z "${OPNSENSE_ARG}" ) ]]; then
    nver="$(jq -r '.version // "?"' "${REL_NIXOS}")"
    ntag="$(get_tag "$(get_loc "${REL_NIXOS}")")"
    otag="$(get_tag "$(get_loc "${REL_OPNSENSE}")")"
    info "NixOS template : version=${nver}  image=${ntag}  sha256=$(get_sha "${REL_NIXOS}")"
    info "OPNsense image : image=${otag}  sha256=$(get_sha "${REL_OPNSENSE}")"
    drift=0
    for f in "${REL_NIXOS}" "${REL_OPNSENSE}"; do
        [[ -n "$(get_sha "${f}")" ]] || warn "${f} records no imageSha256 — downloads are not checked (ADR-033 D7)"
    done
    if [[ "${ntag}" != "nixos-template-v${nver}" ]]; then
        warn "drift: tappaas-nixos.json version (${nver}) != image tag (${ntag})"
        drift=1
    fi
    if git rev-parse -q --verify "refs/tags/${ntag}" >/dev/null 2>&1; then :; fi
    latest_nixos="$(git tag --list 'nixos-template-v*' --sort=-v:refname | head -1)"
    latest_opn="$(git tag --list 'opnsense-firewall-v*' --sort=-v:refname | head -1)"
    [[ -n "${latest_nixos}" && "${latest_nixos}" != "${ntag}" ]] && \
        { warn "a newer NixOS image tag exists: ${latest_nixos} (pointer is ${ntag})"; drift=1; }
    [[ -n "${latest_opn}" && "${latest_opn}" != "${otag}" ]] && \
        { warn "a newer OPNsense image tag exists: ${latest_opn} (pointer is ${otag})"; drift=1; }
    [[ "${drift}" -eq 0 ]] && info "${GN}pointers consistent${CL}"
    exit $(( drift == 1 && CHECK_ONLY == 1 ? 3 : 0 ))
fi

# ── Apply bumps ──────────────────────────────────────────────────────
if [[ -n "${NIXOS_ARG}" ]]; then
    tag="$(normalise nixos-template-v "${NIXOS_ARG}")"
    ver="${tag#nixos-template-v}"
    loc="${BASE_URL}/${tag}/"
    if [[ -n "${NIXOS_SHA}" ]]; then sha="$(normalise_sha "${NIXOS_SHA}")"
    else sha="$(release_sha "${loc}" "$(get_image "${REL_NIXOS}")")"; fi
    # shellcheck disable=SC2016  # $v is a jq variable, not shell — keep single quotes
    set_json "${REL_NIXOS}" --arg v "${ver}" --arg l "${loc}" --arg h "${sha}" \
        ".version = \$v | ${SET_IMAGE}"
    info "NixOS template -> version ${ver}, image ${tag}, sha256 ${sha}"
fi

if [[ -n "${OPNSENSE_ARG}" ]]; then
    tag="$(normalise opnsense-firewall-v "${OPNSENSE_ARG}")"
    loc="${BASE_URL}/${tag}/"
    if [[ -n "${OPNSENSE_SHA}" ]]; then sha="$(normalise_sha "${OPNSENSE_SHA}")"
    else sha="$(release_sha "${loc}" "$(get_image "${REL_OPNSENSE}")")"; fi
    set_json "${REL_OPNSENSE}" --arg l "${loc}" --arg h "${sha}" "${SET_IMAGE}"
    info "OPNsense image -> ${tag}, sha256 ${sha}"
fi

info "Done. Review with: git diff -- ${REL_NIXOS} ${REL_OPNSENSE}"
