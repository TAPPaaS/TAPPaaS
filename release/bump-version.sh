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
#   network/network.json         : .config."cluster:vm".imageLocation
#
# Usage: bump-version.sh [options]
#
# Options:
#   --nixos <ver|tag>     Set the NixOS template to this version. Accepts
#                         "1.3" or "nixos-template-v1.3".
#   --opnsense <ver|tag>  Set the OPNsense firewall image. Accepts "1.2" or
#                         "opnsense-firewall-v1.2".
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
CHECK_ONLY=0

REL_NIXOS="src/foundation/templates/tappaas-nixos.json"
REL_OPNSENSE="src/foundation/network/network.json"
BASE_URL="https://github.com/TAPPaaS/TAPPaaS/releases/download"

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nixos)    NIXOS_ARG="${2:?--nixos needs a value}"; shift 2 ;;
        --opnsense) OPNSENSE_ARG="${2:?--opnsense needs a value}"; shift 2 ;;
        --check)    CHECK_ONLY=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

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
get_tag() { local l="${1%/}"; echo "${l##*/}"; }  # last path segment of the URL

set_json() {  # set_json <file> <jq-filter> ...args
    local file="$1"; shift
    local tmp; tmp="$(mktemp)"
    jq --indent 2 "$@" >"${tmp}" <"${file}"
    mv "${tmp}" "${file}"
}

# ── --check / default: report state and drift ────────────────────────
if [[ "${CHECK_ONLY}" -eq 1 || ( -z "${NIXOS_ARG}" && -z "${OPNSENSE_ARG}" ) ]]; then
    nver="$(jq -r '.version // "?"' "${REL_NIXOS}")"
    ntag="$(get_tag "$(get_loc "${REL_NIXOS}")")"
    otag="$(get_tag "$(get_loc "${REL_OPNSENSE}")")"
    info "NixOS template : version=${nver}  image=${ntag}"
    info "OPNsense image : image=${otag}"
    drift=0
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
    # shellcheck disable=SC2016  # $v/$l are jq variables, not shell — keep single quotes
    set_json "${REL_NIXOS}" --arg v "${ver}" --arg l "${loc}" \
        '.version = $v | .config."cluster:vm".imageLocation = $l'
    info "NixOS template -> version ${ver}, image ${tag}"
fi

if [[ -n "${OPNSENSE_ARG}" ]]; then
    tag="$(normalise opnsense-firewall-v "${OPNSENSE_ARG}")"
    loc="${BASE_URL}/${tag}/"
    # shellcheck disable=SC2016  # $l is a jq variable, not shell — keep single quotes
    set_json "${REL_OPNSENSE}" --arg l "${loc}" \
        '.config."cluster:vm".imageLocation = $l'
    info "OPNsense image -> ${tag}"
fi

info "Done. Review with: git diff -- ${REL_NIXOS} ${REL_OPNSENSE}"
