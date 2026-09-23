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

echo "── a boundary refuses what it cannot promote ──"
make_train 3 2
FAKE_NOW=1790000000 run init
# A FIXED clock: without it "now" is the wall clock and the soak's age depends
# on the day the suite runs, which is how a test starts passing by accident.
FAKE_NOW=1790000000 run boundary --dry-run
[[ "${RC}" -ne 0 ]] && ok "a fresh soak refuses a boundary" || bad "boundary ran during the soak"
[[ "${OUT}" == *"soak is 0 of 14 days"* ]] && ok "…and says it is a WAIT, not a fault" \
    || bad "the soak refusal is not distinguished: ${OUT}"
# WAIT is forceable; BROKEN is not. That distinction is the whole point.
FAKE_NOW=1790000000 run boundary --dry-run --force-boundary
[[ "${OUT}" == *"proceeding despite"* ]] && ok "--force-boundary lifts a WAIT, loudly" \
    || bad "--force-boundary did not lift the soak"

# Break the ancestry: BROKEN must survive --force-boundary.
git -C "${TMP}/w" checkout -q stable
echo x > "${TMP}/w/oops"; git -C "${TMP}/w" add -A; git -C "${TMP}/w" commit -qm sideways
git -C "${TMP}/w" push -q -f origin stable; git -C "${TMP}/w" fetch -q origin; git -C "${TMP}/w" checkout -q main
FAKE_NOW=$(( 1790000000 + 20*86400 )) run boundary --force-boundary
[[ "${RC}" -ne 0 && "${OUT}" == *"does not lift these"* ]] \
    && ok "a diverged channel is refused even with --force-boundary" \
    || bad "force lifted a BROKEN check: ${OUT}"

echo "── promotion is fast-forward only, and in order ──"
make_train 3 2
FAKE_NOW=1790000000 run init
# Mark phases 1-2 done, as a real operator would after proving the pin here.
jq '.boundary.phasesDone = ["prove"]' "${TMP}/cfg/release-train.json" > "${TMP}/x" && mv "${TMP}/x" "${TMP}/cfg/release-train.json"
_stable_before="$(git -C "${TMP}/w" rev-parse origin/stable)"
_staging_before="$(git -C "${TMP}/w" rev-parse origin/staging)"
FAKE_NOW=$(( 1790000000 + 20*86400 )) run boundary --resume
[[ "${RC}" -eq 0 ]] && ok "a due, proven boundary runs" || bad "boundary failed: ${OUT}"
[[ "$(git -C "${TMP}/w" rev-parse origin/stable)" == "${_staging_before}" ]] \
    && ok "stable became what staging WAS — the soaked revision, not the new one" \
    || bad "stable did not take staging's old position"
[[ "$(git -C "${TMP}/w" rev-parse origin/staging)" == "$(git -C "${TMP}/w" rev-parse origin/main)" ]] \
    && ok "staging became main" || bad "staging did not advance to main"
[[ "$(git -C "${TMP}/w" rev-parse origin/stable)" != "${_stable_before}" ]] \
    && ok "production moved exactly one boundary" || bad "stable did not move"
[[ "$(jq -r '.soakStartedAt' "${TMP}/cfg/release-train.json")" == "$(( 1790000000 + 20*86400 ))" ]] \
    && ok "the soak clock restarts from the promotion" || bad "clock not restarted"

echo "── the fault rule (ADR-028 D9) ──"
make_train 3 2
FAKE_NOW=1790000000 run init
run fault "grafana lost its dashboards on staging"
[[ "${RC}" -eq 0 && "$(jq -r '.fault.what' "${TMP}/cfg/release-train.json")" == "grafana lost its dashboards on staging" ]] \
    && ok "a staging fault is recorded" || bad "fault not recorded"
FAKE_NOW=$(( 1790000000 + 20*86400 )) run boundary --dry-run --force-boundary
[[ "${RC}" -ne 0 ]] && ok "an unresolved fault blocks promotion, even forced" || bad "fault did not block"
# "Resolved" must mean the fix is ON MAIN — a staging-only hotfix returns next boundary.
git -C "${TMP}/w" checkout -q staging
echo fix > "${TMP}/w/fix"; git -C "${TMP}/w" add -A; git -C "${TMP}/w" commit -qm "hotfix on staging only"
_hotfix="$(git -C "${TMP}/w" rev-parse HEAD)"
git -C "${TMP}/w" push -q origin staging; git -C "${TMP}/w" fetch -q origin; git -C "${TMP}/w" checkout -q main
run fault --resolved "${_hotfix}"
[[ "${RC}" -ne 0 && "${OUT}" == *"not on main"* ]] \
    && ok "a fix that lives only on staging is not 'resolved'" || bad "accepted a staging-only fix"
run fault --resolved "$(git -C "${TMP}/w" rev-parse origin/main)"
[[ "${RC}" -eq 0 && "$(jq -r '.fault' "${TMP}/cfg/release-train.json")" == "null" ]] \
    && ok "a fix on main clears the fault" || bad "fault not cleared: ${OUT}"

echo "── summary: ${PASS} pass, ${FAIL} fail ──"
[[ "${FAIL}" -eq 0 ]]
