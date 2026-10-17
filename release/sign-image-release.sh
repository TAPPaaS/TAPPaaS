#!/usr/bin/env bash
#
# release/sign-image-release.sh — sign an image release's SHA256SUMS (ADR-033 D7).
#
# The image builds (.github/workflows/build-*-image.yml) publish SHA256SUMS with
# every release. The signature cannot come from CI: the signing keys are the
# signers' own, kept in their Bitwarden/Vaultwarden vault and used through its
# SSH agent. A signer runs this on their own machine after the build, and before release/bump-version.sh points the
# configs at the release:
#
#   1. downloads the release's SHA256SUMS,
#   2. checks it lists every artefact of the release, with the digest GitHub
#      recorded for each upload,
#   3. signs it: ssh-keygen -Y sign -n tappaas-image (approve it in your SSH agent),
#   4. checks the signature against .tappaas/allowed_signers,
#   5. uploads SHA256SUMS.sig to the release.
#
# Usage: sign-image-release.sh <tag> [options]
#
#   <tag>             nixos-template-v1.5, opnsense-firewall-v1.2, ...
#
# Options:
#   --key <file>      The signing key's public half; the agent holds the
#                     private one. Default: git config user.signingkey.
#   --generate        The release has no SHA256SUMS (built before they were
#                     published): download every artefact, hash it, and upload
#                     SHA256SUMS too.
#   --repo <o/r>      GitHub repository (default TAPPaaS/TAPPaaS).
#   --dry-run         Sign and check, upload nothing.
#   -h, --help        Show this help.
#
# Needs: gh (logged in, with write access to releases), ssh-keygen, jq.
# Exit codes: 0 signed · 1 refused or failed · 2 usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

TAG=""
KEY=""
GENERATE=0
REPO="TAPPaaS/TAPPaaS"
DRY_RUN=0
NAMESPACE="tappaas-image"
SIGNERS=".tappaas/allowed_signers"
REVOKED=".tappaas/revoked_signers"

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; }
usage_err() { error "$*"; exit 2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --key)      KEY="${2:?--key needs a file}"; shift 2 ;;
        --generate) GENERATE=1; shift ;;
        --repo)     REPO="${2:?--repo needs owner/name}"; shift 2 ;;
        --dry-run)  DRY_RUN=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        -*)         usage_err "unknown option: $1 (see --help)" ;;
        *)          [[ -z "${TAG}" ]] || usage_err "one tag only"; TAG="$1"; shift ;;
    esac
done
[[ -n "${TAG}" ]] || usage_err "which release? (see --help)"
export DRY_RUN

require_cmd gh "https://cli.github.com"
require_cmd ssh-keygen
require_cmd jq
cd "$(repo_root)"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ── The key ──────────────────────────────────────────────────────────
if [[ -z "${KEY}" ]]; then
    KEY="$(git config --get user.signingkey || true)"
    [[ -n "${KEY}" ]] || die "no --key and no git config user.signingkey"
fi
if [[ "${KEY}" == key::* ]]; then          # git's literal-key form
    printf '%s\n' "${KEY#key::}" >"${WORK}/signing.pub"
    KEY="${WORK}/signing.pub"
fi
KEY="${KEY/#\~/${HOME}}"
[[ -f "${KEY}" ]] || die "signing key not found: ${KEY}"

# ── 1-2. SHA256SUMS, checked against the release's assets ────────────
step "Release ${TAG} (${REPO})"
gh api "repos/${REPO}/releases/tags/${TAG}" \
    --jq '.assets[] | select(.name != "SHA256SUMS" and .name != "SHA256SUMS.sig") | [.name, (.digest // "")] | @tsv' \
    >"${WORK}/assets.tsv" || die "release ${TAG} not found in ${REPO}"
[[ -s "${WORK}/assets.tsv" ]] || die "release ${TAG} has no artefacts"

if gh release download "${TAG}" --repo "${REPO}" -p SHA256SUMS -D "${WORK}" >/dev/null 2>&1; then
    [[ "${GENERATE}" -eq 0 ]] || die "${TAG} already has SHA256SUMS — sign it without --generate"
    info "downloaded SHA256SUMS"
elif [[ "${GENERATE}" -eq 1 ]]; then
    info "no SHA256SUMS — downloading the artefacts to hash them"
    : >"${WORK}/SHA256SUMS"
    while IFS=$'\t' read -r name _; do
        mkdir -p "${WORK}/a"
        gh release download "${TAG}" --repo "${REPO}" -p "${name}" -D "${WORK}/a" \
            || die "download of ${name} failed"
        printf '%s  %s\n' "$(sha256_of "${WORK}/a/${name}")" "${name}" >>"${WORK}/SHA256SUMS"
        rm -f "${WORK}/a/${name}"
    done <"${WORK}/assets.tsv"
else
    die "${TAG} has no SHA256SUMS — a release built before they were published needs --generate"
fi

bad=0
while IFS=$'\t' read -r name digest; do
    listed="$(awk -v f="${name}" '{n=$2; sub(/^\*/, "", n)} n == f {print $1; exit}' "${WORK}/SHA256SUMS")"
    if [[ -z "${listed}" ]]; then
        error "${name} is in the release but not in SHA256SUMS"; bad=1
    elif [[ -n "${digest}" && "${digest}" != "sha256:${listed}" ]]; then
        error "${name}: SHA256SUMS says ${listed}, the release recorded ${digest#sha256:}"; bad=1
    else
        info "${name}  ${listed}"
    fi
done <"${WORK}/assets.tsv"
[[ "${bad}" -eq 0 ]] || die "SHA256SUMS does not describe this release — not signing it"

# ── 3-4. Sign, then check the signature the way a verifier will ──────
step "Signing SHA256SUMS (namespace ${NAMESPACE}) — approve it in your SSH agent"
ssh-keygen -Y sign -f "${KEY}" -n "${NAMESPACE}" "${WORK}/SHA256SUMS" >/dev/null \
    || die "ssh-keygen -Y sign failed"

if grep -qvE '^[[:space:]]*(#|$)' "${SIGNERS}" 2>/dev/null; then
    who="$(ssh-keygen -Y find-principals -f "${SIGNERS}" -n "${NAMESPACE}" \
             -s "${WORK}/SHA256SUMS.sig" 2>/dev/null | head -1 || true)"
    [[ -n "${who}" ]] || die "this key is not listed in ${SIGNERS} for ${NAMESPACE} — enrol it first (src/foundation/tappaas-cicd/SIGNING.md)"
    rev=()
    if grep -vE '^[[:space:]]*(#|$)' "${REVOKED}" >"${WORK}/revoked" 2>/dev/null; then rev=(-r "${WORK}/revoked"); fi
    ssh-keygen -Y verify -f "${SIGNERS}" -I "${who}" ${rev[@]+"${rev[@]}"} -n "${NAMESPACE}" \
        -s "${WORK}/SHA256SUMS.sig" <"${WORK}/SHA256SUMS" >/dev/null \
        || die "the signature does not verify against ${SIGNERS} (expired, or revoked in ${REVOKED}?)"
    info "${GN}signature verifies${CL} as ${who}"
else
    warn "${SIGNERS} lists no key yet — the signature cannot be checked, and sites will not count it"
fi

# ── 5. Upload ────────────────────────────────────────────────────────
step "Uploading"
files=("${WORK}/SHA256SUMS.sig")
[[ "${GENERATE}" -eq 1 ]] && files=("${WORK}/SHA256SUMS" "${files[@]}")
run gh release upload "${TAG}" --repo "${REPO}" --clobber "${files[@]}"
info "Done. Next: release/bump-version.sh (it checks this signature before writing the hash)."
