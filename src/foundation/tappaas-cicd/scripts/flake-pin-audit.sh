#!/usr/bin/env bash
#
# flake-pin-audit.sh — flake inputs that point at TAPPaaS code are pinned by the
# lock a signed release covers (ADR-033 D8).
#
# The signed release tag covers every flake.lock in the tree; a lock entry
# covers its input only when it records the revision AND the narHash (Nix
# refuses content that does not match it). So, for every flake.nix under the
# given trees:
#   - it has a flake.lock beside it;
#   - an input on a TAPPaaS repository (owner or URL naming TAPPaaS) is locked
#     with a 40-hex rev and a narHash — never only a branch;
#   - a path input is relative and stays inside the tree (the tag covers it);
#     an absolute path is outside anything signed.
# Inputs elsewhere (nixpkgs) are pinned by narHash already; they are checked
# for the narHash only.
#
# Usage: flake-pin-audit.sh [<dir>...]   (default: this checkout's src/)
# Prints one line per finding; exit 0 none, 1 findings, 2 usage.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "flake-pin-audit: needs jq" >&2; exit 2; }
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
[[ $# -gt 0 ]] || set -- "${HERE}/../../.."

found=0
report() { echo "$1: $2"; found=1; }

for root in "$@"; do
while IFS= read -r -d '' flake; do
    dir="$(dirname "${flake}")"
    lock="${dir}/flake.lock"
    # The tree a tag covers: the flake's git checkout, else the directory given.
    top="$(git -C "${dir}" rev-parse --show-toplevel 2>/dev/null || { cd "${root}" && pwd; })"
    top="$(cd "${top}" && pwd -P)"
    grep -q 'inputs' "${flake}" || continue
    if [[ ! -f "${lock}" ]]; then
        report "${flake}" "no flake.lock — its inputs are not pinned"
        continue
    fi
    # Fields joined by US (\x1f), not tabs: read would merge empty tab fields.
    while IFS=$'\x1f' read -r name type ref rev narhash path; do
        [[ -n "${name}" ]] || continue
        if [[ "${type}" == path ]]; then
            if [[ "${path}" == /* ]]; then
                report "${lock}" "input '${name}' is the absolute path ${path} — outside the signed tree"
            elif [[ "$(cd "${dir}" 2>/dev/null && cd "${path}" 2>/dev/null && pwd -P)/" != "${top}/"* ]]; then
                report "${lock}" "input '${name}' (${path}) leaves the tree"
            fi
            continue
        fi
        if [[ "$(tr 'A-Z' 'a-z' <<<"${ref}")" == *tappaas* && ! "${rev}" =~ ^[0-9a-f]{40}$ ]]; then
            report "${lock}" "input '${name}' (${ref}) is a TAPPaaS repository without a locked rev"
        fi
        [[ "${narhash}" == sha256-* ]] \
            || report "${lock}" "input '${name}' (${ref}) has no narHash — its content is not checked"
    done < <(jq -r '.nodes | to_entries[] | select(.key != "root" and .value.locked != null)
        | .value.locked as $l
        | [ .key, $l.type,
            ([$l.owner, $l.repo, $l.url, $l.host] | map(select(. != null)) | join("/")),
            ($l.rev // ""), ($l.narHash // ""), ($l.path // "") ] | join("\u001f")' "${lock}")
done < <(find "${root}" -name flake.nix -not -path '*/.git/*' -not -path '*/node_modules/*' -print0)
done

exit "${found}"
