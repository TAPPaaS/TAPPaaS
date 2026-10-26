#!/usr/bin/env bash
# test-repository-introduce.sh — `repository.sh introduce <name>` with no signer
# fingerprints in site.json, the path site-manager's reconcile clones through
# (ADR-033 D5): an unstable branch needs none, a staging one is refused with
# the way to add it, an unknown repository and a missing checkout are refused.
# Self-contained: a local bare "origin" and temp checkouts. No network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
REPO_SH="${CICD}/manager/site-manager/repository.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
has() { if grep -qF -- "$2" <<<"$3"; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (no '$2' in output)"; printf '%s\n' "$3" | sed 's/^/      | /'; fail=$((fail+1)); fi; }

d="$(mktemp -d)"; trap 'rm -rf "${d}"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# ── a repository that declares a staging channel and signs nothing ──
git init -q --bare -b main "${d}/up.git"
git clone -q "${d}/up.git" "${d}/dev" 2>/dev/null
printf '{"staging":["staging"],"unstable":["main"]}\n' > "${d}/dev/channels.json"
echo x > "${d}/dev/f"
git -C "${d}/dev" add -A && git -C "${d}/dev" commit -qm init
git -C "${d}/dev" push -q origin HEAD:main HEAD:staging

cfg="${d}/config"; mkdir -p "${cfg}"
site() {  # site <branch> <path>
    printf '{"name":"t","repositories":[{"name":"Mods","url":"file://%s/up.git","branch":"%s","path":"%s"}]}\n' "${d}" "$1" "$2" > "${cfg}/site.json"
}
introduce() { CONFIG_DIR="${cfg}" TAPPAAS_CONFIG_DIR="${cfg}" bash "${REPO_SH}" introduce "$@" 2>&1; }

echo "── an unstable branch needs no signers"
git clone -q -b main "${d}/up.git" "${d}/main-co" 2>/dev/null
site main "${d}/main-co"
out="$(introduce Mods)"; ck "rc 0" 0 "$?"
has "…and says nothing is signed there" "is unstable" "${out}"

echo "── a staging branch without signers is refused"
git clone -q -b staging "${d}/up.git" "${d}/staging-co" 2>/dev/null
site staging "${d}/staging-co"
out="$(introduce Mods)"; ck "rc 1" 1 "$?"
has "…naming the branch as staging" "is a staging branch" "${out}"
has "…and the way to track it unverified" "--unsigned" "${out}"

echo "── what it cannot judge"
out="$(introduce Nosuch)"; ck "an undeclared repository is refused" 1 "$?"
site staging "${d}/gone"
out="$(introduce Mods)"; ck "a missing checkout is refused" 1 "$?"
has "…and says so" "checkout is missing" "${out}"

echo
echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
