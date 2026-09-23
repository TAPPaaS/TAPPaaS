#!/usr/bin/env bash
#
# test-train-status.sh — the release train's read-only half (ADR-028 D9).
#
# `status` and `init` answer one question — is the train promotable? — and the
# answer rests on a single assertion:
#
#     stable ⊆ staging ⊆ main
#
# Each channel ref an ancestor of the one above it. That is what proves every
# promotion is a fast-forward and that nothing was pushed sideways into a
# channel, so it is what these tests are mostly about.
#
# Driven against throwaway git repositories, so the shapes that must be refused
# (a channel that has diverged, a missing ref) can actually be built. Nothing
# here touches a site.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRAIN="${HERE}/../tappaas-train.sh"
[[ -x "${TRAIN}" ]] || { echo "tappaas-train.sh not found beside this suite — cannot run here."; exit 77; }
command -v jq >/dev/null 2>&1 || { echo "jq not found — cannot run here."; exit 77; }

PASS=0; FAIL=0
ok()  { echo "  ok: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/train.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

# A repository shaped like the real one: an "origin" with three channel refs,
# and a clone whose remote-tracking refs point at them.
make_train() {   # $1 = staging offset from main, $2 = stable offset from staging
    local ahead_staging="$1" ahead_stable="$2"
    rm -rf "${TMP}/origin" "${TMP}/site" "${TMP}/cfg"; mkdir -p "${TMP}/origin" "${TMP}/cfg"
    git -C "${TMP}/origin" init -q --bare
    rm -rf "${TMP}/w"; git clone -q "${TMP}/origin" "${TMP}/w"
    git -C "${TMP}/w" config user.email t@t; git -C "${TMP}/w" config user.name t
    # `git init` names the first branch from init.defaultBranch, which is
    # `master` on plenty of machines — then every `push origin main` below
    # silently matches nothing and the refs never exist.
    git -C "${TMP}/w" checkout -q -B main
    mkdir -p "${TMP}/w/src/foundation/templates"
    # A lock, because status reports the estate pin from it.
    cat > "${TMP}/w/src/foundation/templates/flake.lock" <<'EOF'
{"nodes":{"nixpkgs":{"locked":{"rev":"b77b3de8775677f84492abe84635f87b0e153f0f","lastModified":1747932386}}}}
EOF
    local i
    for i in $(seq 1 8); do
        echo "$i" > "${TMP}/w/f"; git -C "${TMP}/w" add -A
        git -C "${TMP}/w" commit -qm "c$i"
    done
    git -C "${TMP}/w" branch -f staging "HEAD~${ahead_staging}"
    git -C "${TMP}/w" branch -f stable "HEAD~$(( ahead_staging + ahead_stable ))"
    git -C "${TMP}/w" push -q origin main staging stable
    git -C "${TMP}/w" fetch -q origin
    printf '%s\n' '{"name":"testsite","channel":"unstable","repositories":[{"name":"TAPPaaS","branch":"main"}]}' \
        > "${TMP}/cfg/site.json"
}

run() {  # sets OUT/RC
    OUT="$(TAPPAAS_REPO_DIR="${TMP}/w" TAPPAAS_CONFIG_DIR="${TMP}/cfg" \
           TAPPAAS_TRAIN_NOW="${FAKE_NOW:-}" "${TRAIN}" "$@" --no-fetch 2>&1)"
    RC=$?
}

echo "── a sound train reports its shape ──"
make_train 3 2
run status
[[ "${RC}" -eq 0 ]] && ok "status exits 0" || bad "status exited ${RC}"
[[ "${OUT}" == *"stable ⊆ staging ⊆ main"* ]] && ok "the ancestry invariant is asserted by name" \
    || bad "no ancestry assertion in status"
[[ "${OUT}" == *"3 behind main"* ]] && ok "staging's distance from main is reported" \
    || bad "staging distance missing: ${OUT}"
[[ "${OUT}" == *"2 behind staging"* ]] && ok "production's distance from staging is reported" \
    || bad "stable distance missing"
[[ "${OUT}" == *"b77b3de87756"* ]] && ok "the estate pin is named" || bad "pin not reported"

echo "── status never changes anything ──"
# The whole point of a read-only half: it must be safe to run when the train is
# broken, which is exactly when someone will run it.
_before="$(git -C "${TMP}/w" rev-parse origin/stable)"
run status
[[ "$(git -C "${TMP}/w" rev-parse origin/stable)" == "${_before}" ]] \
    && ok "status moves no ref" || bad "status moved a ref"
[[ ! -f "${TMP}/cfg/release-train.json" ]] \
    && ok "status writes no state" || bad "status wrote the state file"

echo "── a diverged channel is refused, not reported as fine ──"
make_train 3 2
# stable gets a commit of its own: the shape that means someone pushed straight
# to a channel, and the one that makes a promotion not a fast-forward.
git -C "${TMP}/w" checkout -q stable
echo sideways > "${TMP}/w/oops"; git -C "${TMP}/w" add -A; git -C "${TMP}/w" commit -qm "pushed to stable directly"
git -C "${TMP}/w" push -q -f origin stable; git -C "${TMP}/w" fetch -q origin; git -C "${TMP}/w" checkout -q main
run status
[[ "${OUT}" == *"not an ancestor"* ]] && ok "status names the divergence" || bad "divergence not detected: ${OUT}"
run init
[[ "${RC}" -ne 0 ]] && ok "init refuses a diverged train" || bad "init accepted a diverged train"
[[ "${OUT}" == *"fast-forward only"* ]] && ok "…and says why" || bad "no reason given"

echo "── init verifies the refs, it does not create them ──"
# A command that creates a channel on demand is how a typo becomes a release.
make_train 3 2
git -C "${TMP}/w" push -q origin --delete stable; git -C "${TMP}/w" fetch -q --prune origin
run init
[[ "${RC}" -ne 0 ]] && ok "init refuses when a channel ref is missing" || bad "init accepted a missing ref"
[[ "${OUT}" == *"does not exist"* ]] && ok "…and names the missing one" || bad "missing ref not named"
git -C "${TMP}/w" rev-parse --verify --quiet origin/stable >/dev/null \
    && bad "init created the missing ref" || ok "init created nothing"

echo "── the soak clock ──"
make_train 3 2
FAKE_NOW=1790000000 run init
[[ "${RC}" -eq 0 ]] && ok "init starts the clock on a sound train" || bad "init failed: ${OUT}"
[[ "$(jq -r '.soakStartedAt' "${TMP}/cfg/release-train.json")" == "1790000000" ]] \
    && ok "the start is recorded" || bad "soakStartedAt not written"
FAKE_NOW=1790000000 run status
[[ "${OUT}" == *"0 of 14 days"* ]] && ok "a fresh soak is not due" || bad "soak progress wrong: ${OUT}"
FAKE_NOW=$(( 1790000000 + 14*86400 )) run status
[[ "${OUT}" == *"boundary is due"* ]] && ok "after the interval the boundary is due" || bad "soak never completes"
# Re-running init must not restart the clock — that would hide a missed soak.
FAKE_NOW=$(( 1790000000 + 14*86400 )) run init
[[ "$(jq -r '.soakStartedAt' "${TMP}/cfg/release-train.json")" == "1790000000" ]] \
    && ok "init is idempotent: it does not restart a running clock" || bad "init reset the soak clock"

echo "── a recorded fault blocks promotion (ADR-028 D9) ──"
jq '.fault = {what: "grafana lost its dashboards"}' "${TMP}/cfg/release-train.json" > "${TMP}/x" \
    && mv "${TMP}/x" "${TMP}/cfg/release-train.json"
FAKE_NOW=$(( 1790000000 + 14*86400 )) run status
[[ "${OUT}" == *"blocks promotion"* && "${OUT}" == *"grafana lost its dashboards"* ]] \
    && ok "an unresolved staging fault blocks, and is quoted" || bad "fault not reported: ${OUT}"
[[ "${OUT}" == *"Not promotable"* ]] && ok "…and the verdict says so" || bad "verdict ignored the fault"

echo "── the unimplemented half says so plainly ──"
run boundary
[[ "${RC}" -eq 2 && "${OUT}" == *"not implemented yet"* ]] \
    && ok "boundary refuses rather than pretending" || bad "boundary did something"

echo "── summary: ${PASS} pass, ${FAIL} fail ──"
[[ "${FAIL}" -eq 0 ]]
