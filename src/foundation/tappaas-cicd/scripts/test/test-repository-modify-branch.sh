#!/usr/bin/env bash
# test-repository-modify-branch.sh — `repository.sh modify <name> --branch <b>`
# moves the checkout through the signature gate (ADR-033 D6), like a sweep.
# Self-contained: a local bare "origin" whose main lists a throwaway signing key,
# a staging branch, a temp config dir. No network, no cluster.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
REPO_SH="${CICD}/manager/site-manager/repository.sh"
info(){ :; }; warn(){ :; }; error(){ :; }
# shellcheck source=../../lib/verify-repo.sh
. "${CICD}/lib/verify-repo.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
has() { if grep -qF -- "$2" <<<"$3"; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (no '$2' in output)"; printf '%s\n' "$3" | sed 's/^/      | /'; fail=$((fail+1)); fi; }

d="$(mktemp -d)"; trap 'rm -rf "${d}"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
ssh-keygen -q -t ed25519 -N '' -C k -f "${d}/k" </dev/null

# ── origin: main lists the key; staging carries one unsigned commit ──
git init -q --bare -b main "${d}/up.git"
git clone -q "${d}/up.git" "${d}/dev" 2>/dev/null
printf '{"production":["stable"],"staging":["staging"],"unstable":["main","feature"]}\n' > "${d}/dev/channels.json"
mkdir -p "${d}/dev/.tappaas"
printf 'k@x namespaces="git" %s\n' "$(cut -d' ' -f1-2 "${d}/k.pub")" > "${d}/dev/.tappaas/allowed_signers"
echo one > "${d}/dev/f"
git -C "${d}/dev" add -A && git -C "${d}/dev" commit -qm one && git -C "${d}/dev" push -q origin HEAD:main
git -C "${d}/dev" checkout -qb staging
echo two >> "${d}/dev/f"; git -C "${d}/dev" commit -qam two && git -C "${d}/dev" push -q origin staging
git -C "${d}/dev" checkout -qb feature main
echo three >> "${d}/dev/f"; git -C "${d}/dev" commit -qam three && git -C "${d}/dev" push -q origin feature

R="${d}/TAPPaaS"
git clone -q "${d}/up.git" "${R}" 2>/dev/null
cfg="${d}/config"; mkdir -p "${cfg}"
printf '{"name":"t","repositories":[{"name":"TAPPaaS","url":"file://%s/up.git","branch":"main","path":"%s"}]}\n' "${d}" "${R}" > "${cfg}/site.json"

modify() { CONFIG_DIR="${cfg}" bash "${REPO_SH}" modify TAPPaaS "$@" 2>&1; }
branch_of() { git -C "${R}" rev-parse --abbrev-ref HEAD; }
declared() { jq -r '.repositories[0].branch' "${cfg}/site.json"; }

echo "── an unsigned staging tip is refused"
before="$(git -C "${R}" rev-parse HEAD)"
out="$(modify --branch staging)"; rc=$?
ck "exit non-zero" 1 "$(( rc != 0 ))"
has "says it is not a verified release" "not a verified release" "${out}"
ck "checkout stays on main" "main" "$(branch_of)"
ck "checkout HEAD unchanged" "${before}" "$(git -C "${R}" rev-parse HEAD)"
ck "site.json still declares main" "main" "$(declared)"

echo "── a signed release on staging is taken"
git -C "${d}/dev" checkout -q staging
git -C "${d}/dev" -c gpg.format=ssh -c user.signingkey="${d}/k" tag -s v9.1 -m "TAPPaaS v9.1" -m "$(verify_tag_lines "${d}/dev" HEAD)" HEAD
git -C "${d}/dev" push -q origin v9.1
out="$(modify --branch staging)"; rc=$?
ck "exit 0" 0 "${rc}"
ck "checkout on staging" "staging" "$(branch_of)"
ck "at the release" "$(git -C "${d}/up.git" rev-parse staging)" "$(git -C "${R}" rev-parse HEAD)"
ck "site.json declares staging" "staging" "$(declared)"

echo "── an unstable branch moves unsigned"
out="$(modify --branch feature)"; rc=$?
ck "exit 0" 0 "${rc}"
ck "checkout on feature" "feature" "$(branch_of)"
ck "at the tip" "$(git -C "${d}/up.git" rev-parse feature)" "$(git -C "${R}" rev-parse HEAD)"

echo ""
echo "${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]]
