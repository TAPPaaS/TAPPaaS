#!/usr/bin/env bash
#
# test-verify-repo.sh — unit tests for lib/verify-repo.sh and the ADR-033 gate in
# reconcile_repo_checkout (lib/repo-sync.sh).
#
# Temp repositories and throwaway ed25519 keys only — never the live checkout,
# never the network, never a real signing key.
#
#   verify_target:   a good signed tag; an untagged tip; an unknown signer; a key
#                    added in the same release (refused) and then trusted at the
#                    next; tree-sha256 missing or wrong; a re-published tag
#                    object; an expired key on a new tag and on an old one; no
#                    signers at the base (unsigned by declaration); expiry read
#                    against today when moving, a revoked key refused at any date;
#                    the recovery
#                    key enrols signers but may not sign code.
#   verify_moves_forward: a rollback is refused.
#   the gate:        a staging checkout moves to a signed release and records it;
#                    an unsigned tip is refused and nothing moves; an old signed
#                    release is refused; unstable moves unverified; an unsigned
#                    repository moves unless requireSigned.
#   the introduction: a fresh clone verifies against tag + fingerprint (D5);
#                    wrong key, tag, commit or an unreleased tip refused; the
#                    record it leaves makes the next update take the base rule.
#
# Usage: test-verify-repo.sh   (prints "Results: N passed, M failed"; exit 1 on fail)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info(){ :; }; warn(){ :; }; error(){ :; }; debug(){ :; }
# shellcheck source=/dev/null
. "${HERE}/repo-sync.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); }
no(){ fail=$((fail+1)); echo "FAIL: $1"; }
check(){ if [ "$2" = "$3" ]; then ok; else no "$1 (got '$2', want '$3')"; fi; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
W="$(mktemp -d "${TMPDIR:-/tmp}/verify-repo-test.XXXXXX")"
trap 'rm -rf "${W}"' EXIT

ssh-keygen -q -t ed25519 -N '' -C alice -f "${W}/alice" </dev/null
ssh-keygen -q -t ed25519 -N '' -C bob   -f "${W}/bob"   </dev/null
ssh-keygen -q -t ed25519 -N '' -C eve   -f "${W}/eve"   </dev/null
signer_line() { printf '%s namespaces="git,tappaas-image"%s %s\n' "$1" "${3:-}" "$(cut -d' ' -f1-2 "${W}/$2.pub")"; }

# stag <repo> <key> <tag> [<tree-sha256 override>|-] — a signed release tag on HEAD
# carrying the ADR-033 lines (or a wrong / missing tree hash).
stag() {
    local r="$1" key="$2" t="$3" tree="${4:-}" lines
    lines="$(verify_tag_lines "${r}" HEAD)"
    case "${tree}" in
        "") ;;
        -) lines="$(printf '%s\n' "${lines}" | grep -v '^tree-sha256:')" ;;
        *) lines="$(printf '%s\n' "${lines}" | sed "s/^tree-sha256: .*/tree-sha256: ${tree}/")" ;;
    esac
    git -C "${r}" -c gpg.format=ssh -c user.signingkey="${W}/${key}" \
        tag -s "${t}" -m "TAPPaaS ${t#v}" -m "${lines}" HEAD
}
commit() { echo "$2" >> "$1/f"; git -C "$1" add -A; git -C "$1" commit -qm "$2"; }

# ── verify_target ───────────────────────────────────────────────────────
R="${W}/r"; git init -q -b main "${R}"
commit "${R}" base
UNSIGNED_BASE="$(git -C "${R}" rev-parse HEAD)"
mkdir -p "${R}/.tappaas"; signer_line alice@x alice > "${R}/.tappaas/allowed_signers"
commit "${R}" "signers: alice"
BASE="$(git -C "${R}" rev-parse HEAD)"

# 1. a good tag, signed by a key the base lists
commit "${R}" r1; stag "${R}" alice v1.0
T1="$(git -C "${R}" rev-parse HEAD)"
verify_target "${R}" "${T1}" "${BASE}"; rc=$?
check "good tag verifies" "${rc}/${VERIFY_STATUS}/${VERIFY_TAG}" "0/verified/v1.0"
check "signer principal" "${VERIFY_SIGNER%% *}" "alice@x"
check "tree recorded" "${VERIFY_TREE}" "$(verify_tree_sha256 "${R}" "${T1}")"
check "signers-at names the signers commit" "$(verify_tag_field "${R}" v1.0 signers-at)" "${BASE}"

# 2. an untagged tip
commit "${R}" untagged
verify_target "${R}" HEAD "${BASE}"; rc=$?
check "untagged tip fails" "${rc}/${VERIFY_STATUS}" "1/failed"

# 3. an unknown signer
stag "${R}" eve v1.1
verify_target "${R}" HEAD "${BASE}"; rc=$?
check "unknown signer fails" "${rc}/${VERIFY_STATUS}" "1/failed"
case "${VERIFY_REASON}" in *v1.1:*) ok ;; *) no "reason names the tag (${VERIFY_REASON})" ;; esac

# 4. bob adds himself in a release and signs it: the base does not list him
signer_line bob@x bob >> "${R}/.tappaas/allowed_signers"; commit "${R}" "signers: + bob"
stag "${R}" bob v1.2
T12="$(git -C "${R}" rev-parse HEAD)"
verify_target "${R}" "${T12}" "${BASE}"; rc=$?
check "self-added signer refused" "${rc}" "1"
#    the same release signed by alice is fine, and from there bob counts
git -C "${R}" tag -d v1.2 >/dev/null; stag "${R}" alice v1.2
verify_target "${R}" "${T12}" "${BASE}"; rc=$?
check "release adding bob, signed by alice" "${rc}" "0"
commit "${R}" r13; stag "${R}" bob v1.3
verify_target "${R}" HEAD "${T12}"; rc=$?
check "bob trusted from the next release" "${rc}/${VERIFY_TAG}" "0/v1.3"

# 5. tree-sha256 missing / wrong
commit "${R}" r14; stag "${R}" alice v1.4 -
verify_target "${R}" HEAD "${T12}"; rc=$?
check "no tree-sha256 fails" "${rc}" "1"
commit "${R}" r15; stag "${R}" alice v1.5 "sha256:0000"
verify_target "${R}" HEAD "${T12}"; rc=$?
check "wrong tree-sha256 fails" "${rc}" "1"
case "${VERIFY_REASON}" in *mismatch*) ok ;; *) no "reason says mismatch (${VERIFY_REASON})" ;; esac

# 6. a signed tag object re-published under another number
commit "${R}" r16; stag "${R}" alice v1.6
T16="$(git -C "${R}" rev-parse HEAD)"
git -C "${R}" update-ref refs/tags/v9.0 "$(git -C "${R}" rev-parse refs/tags/v1.6)"
git -C "${R}" tag -d v1.6 >/dev/null
verify_target "${R}" "${T16}" "${T12}"; rc=$?
check "re-published tag object refused" "${rc}" "1"
case "${VERIFY_REASON}" in *"named 'v1.6'"*) ok ;; *) no "reason names the real tag (${VERIFY_REASON})" ;; esac

# 7. an expired key. Moving to a release (VERIFY_AT=now, the default) reads its
#    validity against today, so a back-dated tag by an expired key is refused;
#    reporting on a running release (VERIFY_AT=tag) reads the tag's own date.
E="${W}/e"; git init -q -b main "${E}"; mkdir -p "${E}/.tappaas"
signer_line alice@x alice ',valid-before="20200101"' > "${E}/.tappaas/allowed_signers"
commit "${E}" base; EBASE="$(git -C "${E}" rev-parse HEAD)"
GIT_COMMITTER_DATE="2019-06-01T00:00:00Z" stag "${E}" alice v0.1
VERIFY_AT=tag verify_target "${E}" HEAD "${EBASE}"; rc=$?
check "retired key, tag from before, reported on" "${rc}" "0"
verify_target "${E}" HEAD "${EBASE}"; rc=$?
check "retired key, back-dated tag, moved to: refused" "${rc}/${VERIFY_STATUS}" "1/failed"
commit "${E}" new; stag "${E}" alice v0.2
VERIFY_AT=tag verify_target "${E}" HEAD "${EBASE}"; rc=$?
check "retired key, tag from after, reported on" "${rc}" "1"
verify_target "${E}" HEAD "${EBASE}"; rc=$?
check "retired key, tag from after, moved to" "${rc}" "1"
#    the clock is today's: a key valid until tomorrow still signs, one not valid
#    until tomorrow does not
VERIFY_NOW=20191231235959 verify_target "${E}" "v0.1^{commit}" "${EBASE}"; rc=$?
check "a key still inside its window" "${rc}" "0"
F2="${W}/f2"; git init -q -b main "${F2}"; mkdir -p "${F2}/.tappaas"
signer_line alice@x alice ',valid-after="20990101"' > "${F2}/.tappaas/allowed_signers"
commit "${F2}" base; F2BASE="$(git -C "${F2}" rev-parse HEAD)"
GIT_COMMITTER_DATE="2099-06-01T00:00:00Z" stag "${F2}" alice v0.1
verify_target "${F2}" HEAD "${F2BASE}"; rc=$?
check "a key not valid yet, forward-dated tag: refused" "${rc}" "1"

# 7a. a revoked key: refused whatever the tag's date, when moving and when reporting
V="${W}/v"; git init -q -b main "${V}"; mkdir -p "${V}/.tappaas"
{ signer_line alice@x alice; signer_line bob@x bob; } > "${V}/.tappaas/allowed_signers"
commit "${V}" base
GIT_COMMITTER_DATE="2019-06-01T00:00:00Z" stag "${V}" bob v0.9
VOLD="$(git -C "${V}" rev-parse HEAD)"
printf '# bob-2026: stolen\n%s\n' "$(cut -d' ' -f1-2 "${W}/bob.pub")" > "${V}/.tappaas/revoked_signers"
commit "${V}" "revoke bob"; stag "${V}" alice v1.0; VREV="$(git -C "${V}" rev-parse HEAD)"
verify_target "${V}" "${VREV}" "${VOLD}"; rc=$?
check "the revoking release, signed by the other key" "${rc}" "0"
commit "${V}" "thief"; GIT_COMMITTER_DATE="2019-06-01T00:00:00Z" stag "${V}" bob v1.1
verify_target "${V}" HEAD "${VREV}"; rc=$?
check "a revoked key, back-dated tag: refused" "${rc}" "1"
case "${VERIFY_REASON}" in *v1.1:*) ok ;; *) no "reason names the tag (${VERIFY_REASON})" ;; esac
VERIFY_AT=tag verify_target "${V}" HEAD "${VREV}"; rc=$?
check "…and refused when reported on" "${rc}" "1"
verify_target "${V}" "${VOLD}" "${VOLD}"; rc=$?
check "a release before the revocation, judged by its own list, still verifies" "${rc}" "0"

# 7b. the recovery key (D4a): both signers lost — it may enrol new ones, nothing else
ssh-keygen -q -t ed25519 -N '' -C recovery -f "${W}/rec" </dev/null
ssh-keygen -q -t ed25519 -N '' -C carol -f "${W}/carol" </dev/null
K="${W}/k"; git init -q -b main "${K}"; mkdir -p "${K}/.tappaas"
{ signer_line alice@x alice; signer_line recovery@x rec; } > "${K}/.tappaas/allowed_signers"
commit "${K}" base; KBASE="$(git -C "${K}" rev-parse HEAD)"
signer_line carol@x carol >> "${K}/.tappaas/allowed_signers"
git -C "${K}" add -A; git -C "${K}" commit -qm "signers: + carol (alice's key is lost)"
stag "${K}" rec v1.1; KREC="$(git -C "${K}" rev-parse HEAD)"
verify_target "${K}" "${KREC}" "${KBASE}"; rc=$?
check "recovery key signs a signers-only release" "${rc}/${VERIFY_SIGNER%% *}" "0/recovery@x"
commit "${K}" "code"; stag "${K}" rec v1.2
verify_target "${K}" HEAD "${KREC}"; rc=$?
check "recovery key may not sign code" "${rc}" "1"
case "${VERIFY_REASON}" in *"recovery key"*) ok ;; *) no "reason names the recovery rule (${VERIFY_REASON})" ;; esac
git -C "${K}" tag -d v1.2 >/dev/null; stag "${K}" carol v1.2
verify_target "${K}" HEAD "${KREC}"; rc=$?
check "the signer it enrolled counts from the next release" "${rc}/${VERIFY_TAG}" "0/v1.2"
verify_only_signers_changed "${K}" "${KBASE}" no-such-rev && no "a diff git cannot compute passed" || ok

# 8. no signers at the base
verify_target "${R}" "${T1}" "${UNSIGNED_BASE}"; rc=$?
check "no signers at base" "${rc}/${VERIFY_STATUS}" "4/unsigned-declared"
verify_repo_signs "${R}" "${UNSIGNED_BASE}" && no "verify_repo_signs on unsigned" || ok
verify_repo_signs "${R}" "${BASE}" && ok || no "verify_repo_signs on signed"

# 9. rollback
verify_moves_forward "${R}" "${T12}" "${T1}" && no "rollback accepted" || ok
verify_moves_forward "${R}" "${T1}" "${T12}" && ok || no "forward refused"

# 10. trust state
S="${W}/state"
VERIFY_TAG=v1.0 VERIFY_SIGNER="alice@x SHA256:x" VERIFY_TREE=sha256:y verify_state_record "${S}" r "${T1}"
check "state records the commit" "$(verify_state_commit "${S}" r)" "${T1}"
check "base is the recorded commit" "$(verify_base "${R}" "${S}" r)" "${T1}"
check "base without state is HEAD" "$(verify_base "${R}" "${S}" other)" "$(git -C "${R}" rev-parse HEAD)"

# ── the gate in reconcile_repo_checkout ────────────────────────────────
# A forge whose `staging` branch is a channel, and a site checkout on it.
F="${W}/forge.git"; git init -q --bare -b main "${F}"
D="${W}/dev"; git clone -q "${F}" "${D}" 2>/dev/null
printf '{"production":["stable"],"staging":["staging"],"unstable":["main"]}\n' > "${D}/channels.json"
mkdir -p "${D}/.tappaas"; signer_line alice@x alice > "${D}/.tappaas/allowed_signers"
commit "${D}" "r1"; stag "${D}" alice v2.1
git -C "${D}" push -q origin main main:staging --tags
SITE="${W}/site"; git clone -q -b staging "${F}" "${SITE}"
export REPO_SYNC_TRUST_DIR="${W}/trust"

# 11. a signed release moves, and is recorded
commit "${D}" r2; stag "${D}" alice v2.2; git -C "${D}" push -q origin main:staging --tags
V22="$(git -C "${D}" rev-parse HEAD)"
reconcile_repo_checkout "${SITE}" "file://${F}" staging 0 site >/dev/null 2>&1; rc=$?
check "signed release moves" "${rc}/$(git -C "${SITE}" rev-parse HEAD)" "0/${V22}"
check "recorded as last verified" "$(verify_state_commit "${REPO_SYNC_TRUST_DIR}" site)" "${V22}"

# 12. an unsigned tip is refused; nothing moves
commit "${D}" sneaky; git -C "${D}" push -q origin main:staging
reconcile_repo_checkout "${SITE}" "file://${F}" staging 0 site >/dev/null 2>&1; rc=$?
check "unsigned tip refused" "${rc}/$(git -C "${SITE}" rev-parse HEAD)" "3/${V22}"
check "record unchanged" "$(verify_state_commit "${REPO_SYNC_TRUST_DIR}" site)" "${V22}"

# 13. staging forced back to an old signed release: refused
git -C "${D}" push -q -f origin "v2.1^{commit}:refs/heads/staging"
reconcile_repo_checkout "${SITE}" "file://${F}" staging 0 site >/dev/null 2>&1; rc=$?
check "rollback to old signed release refused" "${rc}/$(git -C "${SITE}" rev-parse HEAD)" "3/${V22}"

# 14. unstable moves without verification
git -C "${D}" push -q origin main
reconcile_repo_checkout "${SITE}" "file://${F}" main 0 site >/dev/null 2>&1; rc=$?
check "unstable moves unverified" "${rc}/$(git -C "${SITE}" rev-parse HEAD)" "0/$(git -C "${D}" rev-parse HEAD)"

# 15. a repository that signs nothing moves — unless requireSigned
U="${W}/uforge.git"; git init -q --bare -b main "${U}"
UD="${W}/udev"; git clone -q "${U}" "${UD}" 2>/dev/null
printf '{"staging":["staging"],"unstable":["main"]}\n' > "${UD}/channels.json"
commit "${UD}" u1; git -C "${UD}" push -q origin main:staging
US="${W}/usite"; git clone -q -b staging "${U}" "${US}"
commit "${UD}" u2; git -C "${UD}" push -q origin main:staging
REPO_SYNC_REQUIRE_SIGNED=1 reconcile_repo_checkout "${US}" "file://${U}" staging 0 usite >/dev/null 2>&1; rc=$?
check "requireSigned refuses unsigned" "${rc}" "3"
reconcile_repo_checkout "${US}" "file://${U}" staging 0 usite >/dev/null 2>&1; rc=$?
check "unsigned repository moves by default" "${rc}/$(git -C "${US}" rev-parse HEAD)" "0/$(git -C "${UD}" rev-parse HEAD)"

# ── the introduction: first trust for a fresh clone (D5) ───────────────
fp() { ssh-keygen -lf "${W}/$1.pub" | awk '{print $2}'; }
FPA="$(fp alice)" FPB="$(fp bob)" FPE="$(fp eve)"
V21="$(git -C "${D}" rev-parse 'v2.1^{commit}')"
# the forge's staging back at the newest signed release (13 forced it back)
git -C "${D}" push -q -f origin "v2.2^{commit}:refs/heads/staging"
fresh() { rm -rf "$1" "${REPO_SYNC_TRUST_DIR}"; git clone -q -b "${2:-staging}" "${F}" "$1" 2>/dev/null; }

# 16. verify_introduction on its own
C="${W}/c1"; fresh "${C}"
verify_introduction "${C}" v2.1 "${V21}" "${FPA}" HEAD; rc=$?
check "introduction leads to the tip" "${rc}/${VERIFY_TAG}/${VERIFY_INTRO_SIGNER%% *}" "0/v2.2/alice@x"
verify_introduction "${C}" v2.1 "${V21}" "${FPB} ${FPA}" HEAD; rc=$?
check "any listed fingerprint will do" "${rc}" "0"
verify_introduction "${C}" v2.1 "${V21}" "${FPE}" HEAD; rc=$?
check "wrong fingerprint refused" "${rc}" "1"
case "${VERIFY_REASON}" in *"not by ${FPE}"*) ok ;; *) no "reason names the expected key (${VERIFY_REASON})" ;; esac
verify_introduction "${C}" v2.1 "${V22}" "${FPA}" HEAD; rc=$?
check "tag not at introductionCommit refused" "${rc}" "1"
verify_introduction "${C}" v2.1 "${V21:0:12}" "${FPA}" HEAD; rc=$?
check "short introductionCommit refused" "${rc}" "1"
verify_introduction "${C}" v7.0 "${V21}" "${FPA}" HEAD; rc=$?
check "missing introduction tag refused" "${rc}" "1"
verify_introduction "${C}" v2.2 "${V22}" "${FPA}" "${V21}"; rc=$?
check "target before the introduction refused" "${rc}" "1"
verify_introduction "${C}" v2.2 "${V22}" "${FPA}" "${V22}"; rc=$?
check "introduction is the target" "${rc}/${VERIFY_STATUS}/${VERIFY_TAG}" "0/verified/v2.2"

# 17. an introduction signed by a key its own commit does not list (eve signs
#     a release whose allowed_signers names only alice)
EV="${W}/c2"; rm -rf "${EV}"; git clone -q "${D}" "${EV}" 2>/dev/null
git -C "${EV}" checkout -q "${V22}"; git -C "${EV}" tag -d v2.2 >/dev/null; stag "${EV}" eve v2.2
verify_introduction "${EV}" v2.2 "${V22}" "${FPE}" "${V22}"; rc=$?
check "introduction by an unlisted key refused" "${rc}" "1"

# 18. repo_sync_introduce: staging needs an introduction, or --unsigned
C="${W}/c3"; fresh "${C}"
repo_sync_introduce "${C}" staging c3 "" "" "" 0 >/dev/null 2>&1; rc=$?
check "staging clone without introduction refused" "${rc}" "3"
repo_sync_introduce "${C}" staging c3 "" "" "" 1 >/dev/null 2>&1; rc=$?
check "staging clone --unsigned allowed" "${rc}/$(verify_state_commit "${REPO_SYNC_TRUST_DIR}" c3)" "0/"
repo_sync_introduce "${C}" staging c3 v2.1 "" "" 0 >/dev/null 2>&1; rc=$?
check "tag without fingerprint is an error" "${rc}" "1"
repo_sync_introduce "${C}" staging c3 v2.1 "" "SHA256:short" 0 >/dev/null 2>&1; rc=$?
check "malformed fingerprint is an error" "${rc}" "1"
repo_sync_introduce "${C}" staging c3 v2.1 "" "${FPA}" 0 >/dev/null 2>&1; rc=$?
check "introduced clone verifies" "${rc}/${REPO_SYNC_INTRO_COMMIT}/${REPO_SYNC_INTRO_SIGNER}" "0/${V21}/${FPA}"
check "introduced clone is recorded" "$(verify_state_commit "${REPO_SYNC_TRUST_DIR}" c3)" "${V22}"
repo_sync_introduce "${C}" staging c3 v2.1 "" "${FPE}" 0 >/dev/null 2>&1; rc=$?
check "introduction with the wrong key refused" "${rc}" "3"

# 19. ... and from the record, the next update takes the normal base rule:
#     bob is added in v2.3 (signed by alice) and signs v2.4
C="${W}/c4"; fresh "${C}"
repo_sync_introduce "${C}" staging c4 v2.1 "" "${FPA}" 0 >/dev/null 2>&1
signer_line bob@x bob >> "${D}/.tappaas/allowed_signers"; commit "${D}" "signers: + bob"
stag "${D}" alice v2.3; git -C "${D}" push -q origin main:staging --tags
reconcile_repo_checkout "${C}" "file://${F}" staging 0 c4 >/dev/null 2>&1; rc=$?
check "update after the introduction" "${rc}/$(verify_state_commit "${REPO_SYNC_TRUST_DIR}" c4)" "0/$(git -C "${D}" rev-parse HEAD)"
commit "${D}" r24; stag "${D}" bob v2.4; git -C "${D}" push -q origin main:staging --tags
reconcile_repo_checkout "${C}" "file://${F}" staging 0 c4 >/dev/null 2>&1; rc=$?
check "bob signs the release after the one adding him" "${rc}/$(git -C "${C}" rev-parse HEAD)" "0/$(git -C "${D}" rev-parse HEAD)"

# 20. a tip that is not a release, on a fresh staging clone, is refused even
#     with a good introduction
commit "${D}" unreleased; git -C "${D}" push -q origin main:staging
C="${W}/c5"; fresh "${C}"
repo_sync_introduce "${C}" staging c5 v2.1 "" "${FPA}" 0 >/dev/null 2>&1; rc=$?
check "unreleased tip refused on introduction" "${rc}/$(verify_state_commit "${REPO_SYNC_TRUST_DIR}" c5)" "3/"

# 21. unstable: no introduction needed; a given one is still checked
C="${W}/c6"; fresh "${C}" main
repo_sync_introduce "${C}" main c6 "" "" "" 0 >/dev/null 2>&1; rc=$?
check "unstable clone needs no introduction" "${rc}" "0"
repo_sync_introduce "${C}" main c6 v2.1 "" "${FPA}" 0 >/dev/null 2>&1; rc=$?
check "unstable clone, introduction checked" "${rc}/$(verify_state_commit "${REPO_SYNC_TRUST_DIR}" c6)" "0/${V21}"
repo_sync_introduce "${C}" main c6 v2.1 "" "${FPE}" 0 >/dev/null 2>&1; rc=$?
check "unstable clone, wrong key still refused" "${rc}" "3"

# 22. a repository that signs nothing: refused on staging unless --unsigned
C="${W}/c7"; rm -rf "${C}"; git clone -q -b staging "${U}" "${C}" 2>/dev/null
repo_sync_introduce "${C}" staging c7 "" "" "" 0 >/dev/null 2>&1; rc=$?
check "unsigned repository needs --unsigned" "${rc}" "3"
repo_sync_introduce "${C}" staging c7 "" "" "" 1 >/dev/null 2>&1; rc=$?
check "unsigned repository with --unsigned" "${rc}" "0"

# 23. bootstrap.sh's pre-rebuild check (git and ssh-keygen only)
msg_info(){ :; }
eval "$(sed -n '/^bootstrap_signed_release() {/,/^}/p' "${HERE}/../bootstrap.sh")"
git -C "${D}" push -q -f origin "v2.4^{commit}:refs/heads/staging"
C="${W}/b1"; fresh "${C}"
bsr() { (cd "${C}" && bootstrap_signed_release "$@" >/dev/null 2>&1 && echo "0 ${INTRO_TAG} ${INTRO_FP}") || echo 1; }
check "bootstrap: signed release, published key" "$(bsr staging "${FPE} ${FPB}")" "0 v2.4 ${FPB}"
check "bootstrap: signed by another key" "$(bsr staging "${FPE}")" "1"
check "bootstrap: signs, nothing published" "$(bsr staging "")" "1"
check "bootstrap: TAPPAAS_UNSIGNED=1 lets it through" "$(TAPPAAS_UNSIGNED=1 bsr staging "")" "0  "
check "bootstrap: unstable is not checked" "$(bsr main "${FPE}")" "0  "
C="${W}/b2"; rm -rf "${C}"; git clone -q -b staging "${U}" "${C}" 2>/dev/null
check "bootstrap: repository signs nothing yet" "$(bsr staging "")" "0  "
check "bootstrap: keys published, repository lists none" "$(bsr staging "${FPA}")" "1"

echo "Results: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
