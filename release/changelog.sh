#!/usr/bin/env bash
#
# release/changelog.sh — compile the list of issues and changes delivered
# between two git refs, as Markdown release notes.
#
# Walks `git log <from>..<to>`, groups commits by Conventional-Commit type,
# and extracts the Codeberg issue numbers they reference. With --enrich it
# looks up each issue's title via the Forgejo API (read-only, no token).
#
# Usage: changelog.sh [options]
#
# Options:
#   --from <ref>    Start ref (exclusive). Default: latest reachable v* tag,
#                   else the 'stable' branch.
#   --to <ref>      End ref (inclusive). Default: HEAD.
#   --enrich        Fetch each issue's title from the Forgejo API. One HTTP
#                   call per issue — used only at release time; the count is
#                   printed first so you can abort a very large range.
#   --repo <slug>   Forge repo for --enrich. Default: TAPPaaS/TAPPaaS.
#   -h, --help      Show this help.
#
# Output goes to stdout — redirect it: changelog.sh --enrich > NOTES.md
#
# Exit codes: 0 ok · 2 usage/precondition error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

FORGE_API="https://codeberg.org/api/v1/repos"
REPO_SLUG="TAPPaaS/TAPPaaS"
FROM=""
TO="HEAD"
ENRICH=0

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)   FROM="${2:?--from needs a ref}"; shift 2 ;;
        --to)     TO="${2:?--to needs a ref}"; shift 2 ;;
        --enrich) ENRICH=1; shift ;;
        --repo)   REPO_SLUG="${2:?--repo needs a slug}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

require_cmd git
cd "$(repo_root)"

# Default FROM: newest v* tag reachable from TO, else the stable branch.
if [[ -z "${FROM}" ]]; then
    if FROM="$(git describe --tags --abbrev=0 --match 'v*' "${TO}" 2>/dev/null)"; then
        debug "using latest v* tag as start ref: ${FROM}"
    elif git rev-parse --verify --quiet stable >/dev/null; then
        FROM="stable"
    else
        die "no --from given and no v* tag or 'stable' branch to default to"
    fi
fi

git rev-parse --verify --quiet "${FROM}^{commit}" >/dev/null || die "bad --from ref: ${FROM}"
git rev-parse --verify --quiet "${TO}^{commit}"   >/dev/null || die "bad --to ref: ${TO}"

RANGE="${FROM}..${TO}"
NCOMMITS="$(git rev-list --count "${RANGE}")"
[[ "${NCOMMITS}" -gt 0 ]] || die "no commits in ${RANGE} — nothing to release"

# Collect referenced issue numbers (any #NNN in subject or body), deduped, sorted.
mapfile -t ISSUES < <(
    git log --format='%s%n%b' "${RANGE}" \
        | grep -oE '#[0-9]+' | tr -d '#' | sort -un
)

# ── Emit Markdown ────────────────────────────────────────────────────
echo "# TAPPaaS release notes"
echo
echo "_Changes in \`${RANGE}\` — ${NCOMMITS} commit(s), ${#ISSUES[@]} referenced issue(s)._"
echo

# Grouped commit summary by Conventional-Commit type.
declare -A TYPE_TITLE=(
    [feat]="Features" [fix]="Fixes" [docs]="Documentation"
    [refactor]="Refactoring" [perf]="Performance" [test]="Tests"
    [chore]="Chores" [ci]="CI/CD" [build]="Build"
)
for t in feat fix docs refactor perf test build ci chore; do
    lines="$(git log --format='%s' "${RANGE}" | grep -E "^${t}(\(|:)" || true)"
    [[ -n "${lines}" ]] || continue
    echo "## ${TYPE_TITLE[$t]}"
    echo
    while IFS= read -r s; do echo "- ${s}"; done <<<"${lines}"
    echo
done

# Any commits that don't follow the type(scope): convention.
other="$(git log --format='%s' "${RANGE}" \
    | grep -vE '^(feat|fix|docs|refactor|perf|test|build|ci|chore)(\(|:)' || true)"
if [[ -n "${other}" ]]; then
    echo "## Other"
    echo
    while IFS= read -r s; do echo "- ${s}"; done <<<"${other}"
    echo
fi

# Delivered issues.
echo "## Delivered issues"
echo
if [[ "${#ISSUES[@]}" -eq 0 ]]; then
    echo "_No issue references found in commit messages._"
else
    if [[ "${ENRICH}" -eq 1 ]]; then
        require_cmd curl; require_cmd jq
        warn "--enrich: ${#ISSUES[@]} Forgejo API call(s) to ${REPO_SLUG}"
    fi
    for n in "${ISSUES[@]}"; do
        if [[ "${ENRICH}" -eq 1 ]]; then
            title="$(curl -fsS "${FORGE_API}/${REPO_SLUG}/issues/${n}" 2>/dev/null \
                | jq -r '.title // empty' || true)"
            if [[ -n "${title}" ]]; then
                echo "- #${n} — ${title}"
            else
                echo "- #${n}"
            fi
        else
            echo "- #${n}"
        fi
    done
fi
