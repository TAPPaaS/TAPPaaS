#!/usr/bin/env bash
# test-repository-sync.sh — `repository.sh sync <name>`: one repository to its
# branch tip, without the sweep (#814).
# Self-contained: a local bare "origin", a checkout, a temp config dir with a
# migration ledger and two installed modules. No network, no cluster.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
REPO_SH="${CICD}/manager/site-manager/repository.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
has() { if grep -qF -- "$2" <<<"$3"; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (no '$2' in output)"; printf '%s\n' "$3" | sed 's/^/      | /'; fail=$((fail+1)); fi; }
hasnt() { if ! grep -qF -- "$2" <<<"$3"; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 ('$2' in output)"; fail=$((fail+1)); fi; }

d="$(mktemp -d)"; trap 'rm -rf "${d}"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# ── origin, a working clone to push from, and the site's checkout ──
git init -q --bare -b main "${d}/up.git"
git clone -q "${d}/up.git" "${d}/dev" 2>/dev/null
C="src/foundation/tappaas-cicd"
mkdir -p "${d}/dev/${C}/migrations" "${d}/dev/${C}/lib" "${d}/dev/src/apps/foo" "${d}/dev/src/apps/bar"
echo '#!/bin/bash' > "${d}/dev/${C}/migrations/0001-first.sh"
echo 'x=1' > "${d}/dev/${C}/lib/shared.sh"
echo '{ }' > "${d}/dev/${C}/tappaas-cicd.nix"
echo 'foo' > "${d}/dev/src/apps/foo/foo.nix"
echo 'bar' > "${d}/dev/src/apps/bar/bar.nix"
echo 'notes' > "${d}/dev/README.md"
git -C "${d}/dev" add -A && git -C "${d}/dev" commit -qm init && git -C "${d}/dev" push -q origin HEAD:main
upstream() {  # upstream <file> <content> <msg>
    mkdir -p "$(dirname "${d}/dev/$1")"
    echo "$2" > "${d}/dev/$1"
    git -C "${d}/dev" add -A && git -C "${d}/dev" commit -qm "$3" && git -C "${d}/dev" push -q origin HEAD:main
}
R="${d}/TAPPaaS"
git clone -q "${d}/up.git" "${R}" 2>/dev/null

cfg="${d}/config"; mkdir -p "${cfg}/.migrations"
printf '{"name":"t","repositories":[{"name":"TAPPaaS","url":"file://%s/up.git","branch":"main","path":"%s"}]}\n' "${d}" "${R}" > "${cfg}/site.json"
printf '0001  2026-01-01T00:00:00Z  abc1234  applied\n' > "${cfg}/.migrations/applied"
printf '{"moduleSource":"%s/src/apps/foo"}\n' "${R}" > "${cfg}/foo.json"
printf '{"moduleSource":"%s/src/apps/bar"}\n' "${R}" > "${cfg}/bar.json"

# The refresh is a stub that records how it was called.
cat > "${d}/refresh" <<EOF
#!/usr/bin/env bash
echo "NO_GIT_PULL=\${TAPPAAS_NO_GIT_PULL:-unset}" > "${d}/refresh.called"
EOF
chmod +x "${d}/refresh"

# Not the running control plane unless a case says so.
sync() { CONFIG_DIR="${cfg}" TAPPAAS_CICD_DIR="${TAPPAAS_CICD_DIR:-${d}/elsewhere}" TAPPAAS_REFRESH_CMD="${d}/refresh" \
    bash "${REPO_SH}" sync "$@" 2>&1; }
head_of() { git -C "${R}" rev-parse HEAD; }
tip_of()  { git -C "${d}/up.git" rev-parse main; }

echo "── arguments"
out="$(sync)"; ck "no name is refused" 1 "$?"
has "…and points at the full update for every repository" "site-manager update" "${out}"
out="$(sync TAPPaaS other)"; ck "two names are refused" 1 "$?"
out="$(sync nosuch)"; ck "an undeclared repository is refused" 1 "$?"

echo "── already current"
out="$(sync TAPPaaS)"; ck "a current checkout is rc 0" 0 "$?"
has "…and says so" "nothing to do" "${out}"

echo "── a module's source changes upstream"
upstream src/apps/foo/foo.nix 'foo v2' 'foo: v2'
before="$(head_of)"
out="$(sync TAPPaaS --dry-run)"; ck "--dry-run is rc 0" 0 "$?"
ck "--dry-run moves nothing" "${before}" "$(head_of)"
has "the incoming commit is listed" "foo: v2" "${out}"
has "the changed installed module is named" "foo: 1 file(s) in src/apps/foo/" "${out}"
hasnt "an unchanged installed module is not" "bar:" "${out}"
echo 'local edit' >> "${R}/README.md"
out="$(sync TAPPaaS)"; ck "the sync is rc 0" 0 "$?"
ck "the checkout is at origin's tip" "$(tip_of)" "$(head_of)"
has "…and still names the module to deploy" "module-manager update foo" "${out}"
hasnt "raw git output is not shown" "Fast-forward" "${out}"
has "the stash being put back is" "repo-sync: local changes restored" "${out}"
ck "the operator's uncommitted edit is back" "local edit" "$(tail -1 "${R}/README.md")"
git -C "${R}" checkout -q -- README.md
ck "a checkout that is not the control plane runs no refresh" no "$([[ -e "${d}/refresh.called" ]] && echo yes || echo no)"

echo "── a new migration upstream"
upstream "${C}/migrations/0002-second.sh" '#!/bin/bash' 'migration 0002'
before="$(head_of)"
out="$(sync TAPPaaS)"; ck "a pending migration refuses the sync" 1 "$?"
ck "…and nothing moved" "${before}" "$(head_of)"
has "the migration is named" "0002-second.sh" "${out}"
has "the full update is proposed" "site-manager update" "${out}"
out="$(sync TAPPaaS --dry-run)"; ck "--dry-run reports the refusal as non-zero" 1 "$?"
printf '0002  2026-01-02T00:00:00Z  abc1234  applied\n' >> "${cfg}/.migrations/applied"
out="$(sync TAPPaaS)"; ck "once the ledger holds it, the sync runs" 0 "$?"
ck "…to the tip" "$(tip_of)" "$(head_of)"

echo "── a pull hold"
mkdir -p "${cfg}/.repo-hold"
printf '{"repository":"TAPPaaS","reason":"testing a fix","by":"lars","since":"x","until":"2099-01-01T00:00:00Z","untilEpoch":4070908800}\n' \
    > "${cfg}/.repo-hold/TAPPaaS.json"
upstream src/apps/bar/bar.nix 'bar v2' 'bar: v2'
before="$(head_of)"
out="$(sync TAPPaaS)"; ck "an active hold refuses the sync" 1 "$?"
has "…and names it" "testing a fix" "${out}"
ck "…and nothing moved" "${before}" "$(head_of)"
rm -f "${cfg}/.repo-hold/TAPPaaS.json"

echo "── commits that exist only in the checkout"
echo 'mine' > "${R}/local.txt"; git -C "${R}" add local.txt; git -C "${R}" commit -qm 'unpushed work'
out="$(sync TAPPaaS)"; ck "an unpushed commit refuses the sync" 1 "$?"
has "…and lists it" "unpushed work" "${out}"
git -C "${R}" reset -q --hard HEAD~1

echo "── the running control plane"
export TAPPAAS_CICD_DIR="${R}/${C}"
upstream "${C}/lib/shared.sh" 'x=2' 'shared lib change'
out="$(sync TAPPaaS)"; ck "a control-plane change syncs" 0 "$?"
has "a shared lib change is said to reach every module" "every module's update sources them" "${out}"
ck "…and the refresh ran without a pull" "NO_GIT_PULL=1" "$(cat "${d}/refresh.called" 2>/dev/null)"
rm -f "${d}/refresh.called"
upstream "${C}/controller/opnsense-controller/src/x.py" 'x = 2' 'controller change'
out="$(sync TAPPaaS)"; ck "a controller change syncs (the system copy is only a PATH fallback)" 0 "$?"
ck "…and the refresh rebuilds it" "NO_GIT_PULL=1" "$(cat "${d}/refresh.called" 2>/dev/null)"
upstream "${C}/tappaas-cicd.nix" '{ x = 1; }' 'system config change'
before="$(head_of)"
out="$(sync TAPPaaS)"; ck "a change to the mothership's NixOS config refuses the sync" 1 "$?"
has "…naming the file" "${C}/tappaas-cicd.nix" "${out}"
ck "…and nothing moved" "${before}" "$(head_of)"
unset TAPPAAS_CICD_DIR

echo "── an origin change is not a sync"
git -C "${R}" remote set-url origin "https://example.invalid/other.git"
out="$(sync TAPPaaS)"; ck "a mismatched origin refuses the sync" 1 "$?"
has "…and points at repository modify" "repository modify TAPPaaS --url" "${out}"

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
