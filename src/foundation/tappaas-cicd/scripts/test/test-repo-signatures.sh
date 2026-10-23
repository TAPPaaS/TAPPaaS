#!/usr/bin/env bash
#
# test-repo-signatures.sh — check-repo-signatures.sh (ADR-033 D10).
#
# Temp repositories and throwaway keys only. One site tracking five repositories,
# one per status — verified, unsigned-unstable, unsigned-declared,
# ahead-of-release, failed — then: an expiring key is listed; the first run mails
# nothing; a status change is mailed once; a run with no change mails nothing.
#
# Usage: test-repo-signatures.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="${HERE}/../.."
CHECK="${CICD}/manager/health-manager/check-repo-signatures.sh"
info(){ :; }; warn(){ :; }; error(){ :; }; debug(){ :; }
# shellcheck source=../../lib/verify-repo.sh
. "${CICD}/lib/verify-repo.sh"

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
T="$(mktemp -d "${TMPDIR:-/tmp}/repo-sig.XXXXXX")"
trap 'rm -rf "${T}"' EXIT
ssh-keygen -q -t ed25519 -N '' -C k -f "${T}/k" </dev/null

stag() { git -C "$1" -c gpg.format=ssh -c user.signingkey="${T}/k" tag -s "$2" -m "TAPPaaS $2" -m "$(verify_tag_lines "$1" HEAD)" HEAD; }
commit() { echo "$2" >> "$1/f"; git -C "$1" add -A; git -C "$1" commit -qm "$2"; }
# repo <name> <branch> <signed 0/1> [<valid-before>]
repo() {
    local r="${T}/$1"; git init -q -b "$2" "${r}"
    printf '{"production":["stable"],"staging":["staging"],"unstable":["main"]}\n' > "${r}/channels.json"
    if [[ "$3" == 1 ]]; then
        mkdir -p "${r}/.tappaas"
        printf 'k@x namespaces="git"%s %s\n' "${4:+,valid-before=\"$4\"}" "$(cut -d' ' -f1-2 "${T}/k.pub")" > "${r}/.tappaas/allowed_signers"
    fi
    commit "${r}" one
}

repo good staging 1 20991231; stag "${T}/good" v1.0
repo unst main 1
repo unsig staging 0
repo ahead staging 1; stag "${T}/ahead" v1.0
mkdir -p "${T}/trust"
( VERIFY_TAG=v1.0 VERIFY_SIGNER="k@x SHA256:x" VERIFY_TREE=x verify_state_record "${T}/trust" ahead "$(git -C "${T}/ahead" rev-parse HEAD)" )
commit "${T}/ahead" two
repo bad staging 1; commit "${T}/bad" two

mkdir -p "${T}/cfg"
jq -n --arg t "${T}" '{repositories: [
  {name:"good",  branch:"staging", path:"\($t)/good"},
  {name:"unst",  branch:"main",    path:"\($t)/unst"},
  {name:"unsig", branch:"staging", path:"\($t)/unsig"},
  {name:"ahead", branch:"staging", path:"\($t)/ahead"},
  {name:"bad",   branch:"staging", path:"\($t)/bad"}]}' > "${T}/cfg/site.json"
cat > "${T}/notify" <<'STUB'
#!/usr/bin/env bash
{ echo "--- $*"; cat; } >> "${NOTIFY_LOG}"
STUB
chmod +x "${T}/notify"
export NOTIFY_LOG="${T}/mail" TAPPAAS_CONFIG_DIR="${T}/cfg" REPO_SYNC_TRUST_DIR="${T}/trust" TAPPAAS_SITE_NOTIFY="${T}/notify"
# 2099-12-01: the good repository's key (valid until 2099-12-31) expires within 60 days.
export FAKE_NOW=4099766400
S="${T}/cfg/sbom/signatures.json"
st() { jq -r --arg n "$1" '.repositories[] | select(.name==$n) | .status' "${S}"; }

echo "── one status per repository ──"
bash "${CHECK}" >/dev/null 2>&1 && ok "exits 0" || bad "exited non-zero"
[[ -s "${S}" ]] && ok "writes sbom/signatures.json" || bad "no evidence file"
for p in good:verified unst:unsigned-unstable unsig:unsigned-declared ahead:ahead-of-release bad:failed; do
    [[ "$(st "${p%%:*}")" == "${p#*:}" ]] && ok "${p%%:*} is ${p#*:}" || bad "${p%%:*} is $(st "${p%%:*}"), want ${p#*:}"
done
[[ "$(jq -r '.repositories[] | select(.name=="good") | "\(.tag) \(.signer)"' "${S}")" == "v1.0 k@x" ]] \
    && ok "the verified row names its tag and signer" || bad "verified row: $(jq -c '.repositories[0]' "${S}")"
[[ "$(jq -r '.repositories[] | select(.name=="good") | .expiringKeys[0].validBefore' "${S}")" == "20991231" ]] \
    && ok "a key expiring within 60 days is listed" || bad "expiring key not listed"
[[ "$(jq -r '.requireSigned' "${S}")" == "false" ]] && ok "requireSigned defaults to false" || bad "requireSigned not false"
[[ ! -s "${T}/mail" ]] && ok "the first run mails nothing" || bad "first run mailed"

echo "── a change is mailed once ──"
echo dirty >> "${T}/good/f"
bash "${CHECK}" >/dev/null 2>&1
[[ "$(st good)" == "ahead-of-release" ]] && ok "uncommitted changes on a release are ahead-of-release" || bad "dirty good is $(st good)"
grep -q 'good: verified -> ahead-of-release' "${T}/mail" 2>/dev/null && ok "the change is mailed" || bad "no mail: $(cat "${T}/mail" 2>/dev/null)"
: > "${T}/mail"
bash "${CHECK}" >/dev/null 2>&1
[[ ! -s "${T}/mail" ]] && ok "an unchanged run mails nothing" || bad "mailed without a change"

echo "── summary: ${PASS} pass, ${FAIL} fail ──"
[[ "${FAIL}" -eq 0 ]]
