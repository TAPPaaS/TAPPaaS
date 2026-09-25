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
    printf '%s\n' '{"name":"testsite","channel":"unstable","repositories":[{"name":"TAPPaaS","branch":"main","path":"'"${TMP}/w"'"}]}' \
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
# Phases 1-3 already done: the pin moved, the deep test passed, main landed.
# These fixtures exercise the promotions, which is what must not be done by hand.
jq '.boundary.phasesDone = ["branch","prove","main"]' "${TMP}/cfg/release-train.json" > "${TMP}/x" && mv "${TMP}/x" "${TMP}/cfg/release-train.json"
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

echo "── --production-branch: rehearse a promotion without touching stable ──"
make_train 3 2
FAKE_NOW=1790000000 run init
jq '.boundary.phasesDone = ["branch","prove","main"]' "${TMP}/cfg/release-train.json" > "${TMP}/x" && mv "${TMP}/x" "${TMP}/cfg/release-train.json"
_stable_untouched="$(git -C "${TMP}/w" rev-parse origin/stable)"
_staging_was="$(git -C "${TMP}/w" rev-parse origin/staging)"
FAKE_NOW=$(( 1790000000 + 20*86400 )) run boundary --resume --production-branch rehearsal
[[ "${RC}" -eq 0 ]] && ok "a boundary onto an alternative branch runs" || bad "rehearsal failed: ${OUT}"
[[ "$(git -C "${TMP}/w" rev-parse origin/rehearsal 2>/dev/null)" == "${_staging_was}" ]] \
    && ok "the alternative branch is created at what staging was" || bad "rehearsal branch wrong"
[[ "$(git -C "${TMP}/w" rev-parse origin/stable)" == "${_stable_untouched}" ]] \
    && ok "…and stable was not touched" || bad "stable moved during a rehearsal"

echo "── stable is never created by a promotion ──"
# A production channel that appears because of a typo is the failure this
# whole train exists to prevent, so promotion may create a named rehearsal
# branch but never `stable` itself.
make_train 3 2
git -C "${TMP}/w" push -q origin --delete stable; git -C "${TMP}/w" fetch -q --prune origin
FAKE_NOW=1790000000 run init
[[ "${RC}" -ne 0 ]] && ok "init refuses when stable is missing" || bad "init accepted a missing stable"
git -C "${TMP}/w" rev-parse --verify --quiet origin/stable >/dev/null \
    && bad "stable was recreated" || ok "stable stayed absent"

echo "── --staging-host: phase 6 reaches the other site, or says it cannot ──"
make_train 3 2
FAKE_NOW=1790000000 run init
jq '.boundary.phasesDone = ["branch","prove","main"]' "${TMP}/cfg/release-train.json" > "${TMP}/x" && mv "${TMP}/x" "${TMP}/cfg/release-train.json"
# A stub "ssh" that answers as a healthy staging site would.
cat > "${TMP}/fakessh" <<'STUB'
#!/usr/bin/env bash
shift                      # the host
case "$*" in
  *ActiveState*)            echo "inactive" ;;
  *'.channel'*)             echo "staging" ;;
  *'.ok'*)                  echo "true" ;;
  *'site-manager update'*)  echo "update ok" ;;
  *)                        : ;;
esac
STUB
chmod +x "${TMP}/fakessh"
TAPPAAS_TRAIN_SSH="${TMP}/fakessh" FAKE_NOW=$(( 1790000000 + 20*86400 )) \
    run boundary --resume --staging-host staging.example
[[ "${OUT}" == *"verifying the staging site"* ]] && ok "phase 6 runs when a host is named" \
    || bad "phase 6 did not run: ${OUT}"
[[ "${OUT}" == *"updated cleanly"* ]] && ok "…and reports the staging site's verdict" \
    || bad "no verdict from the staging site"

echo "── without a host, phase 6 is skipped LOUDLY ──"
# Silence here would mean a boundary that moved code and learned nothing.
make_train 3 2
FAKE_NOW=1790000000 run init
jq '.boundary.phasesDone = ["branch","prove","main"]' "${TMP}/cfg/release-train.json" > "${TMP}/x" && mv "${TMP}/x" "${TMP}/cfg/release-train.json"
FAKE_NOW=$(( 1790000000 + 20*86400 )) run boundary --resume
[[ "${OUT}" == *"Phase 6 SKIPPED"* ]] && ok "a boundary without a staging host says so" \
    || bad "phase 6 was skipped silently"

echo "── an unreachable staging host is BROKEN, not a warning ──"
make_train 3 2
FAKE_NOW=1790000000 run init
cat > "${TMP}/deadssh" <<'STUB'
#!/usr/bin/env bash
exit 255
STUB
chmod +x "${TMP}/deadssh"
TAPPAAS_TRAIN_SSH="${TMP}/deadssh" FAKE_NOW=$(( 1790000000 + 20*86400 )) \
    run boundary --dry-run --staging-host staging.example
[[ "${RC}" -ne 0 && "${OUT}" == *"cannot reach the staging site"* ]] \
    && ok "a named but unreachable staging site refuses the boundary" \
    || bad "an unreachable staging site did not refuse: ${OUT}"

echo "── both flags together isolate a WHOLE boundary ──"
# Redirecting only production would still advance the real staging channel,
# which the staging site tracks — that is a real boundary with the production
# step aimed sideways, not a rehearsal.
make_train 3 2
FAKE_NOW=1790000000 run init
jq '.boundary.phasesDone = ["branch","prove","main"]' "${TMP}/cfg/release-train.json" > "${TMP}/x" && mv "${TMP}/x" "${TMP}/cfg/release-train.json"
_real_staging="$(git -C "${TMP}/w" rev-parse origin/staging)"
_real_stable="$(git -C "${TMP}/w" rev-parse origin/stable)"
FAKE_NOW=$(( 1790000000 + 20*86400 )) run boundary --resume \
    --staging-branch rehearse-staging --production-branch rehearse-prod
[[ "${RC}" -eq 0 ]] && ok "a fully isolated boundary runs" || bad "isolated boundary failed: ${OUT}"
[[ "$(git -C "${TMP}/w" rev-parse origin/staging)" == "${_real_staging}" ]] \
    && ok "the real staging channel did not move" || bad "staging moved during a rehearsal"
[[ "$(git -C "${TMP}/w" rev-parse origin/stable)" == "${_real_stable}" ]] \
    && ok "…and neither did stable" || bad "stable moved during a rehearsal"
[[ "$(git -C "${TMP}/w" rev-parse origin/rehearse-staging)" == "$(git -C "${TMP}/w" rev-parse origin/main)" ]] \
    && ok "the throwaway staging ref took main" || bad "rehearsal staging ref wrong"

echo "── a staging ref that does not exist yet skips the production push ──"
# Nothing has soaked on a ref that was just invented, so there is nothing to
# give production; only the staging promotion runs, creating it.
[[ "${OUT}" == *"nothing has soaked, so no production push"* ]] \
    && ok "the first rehearsal says why production was skipped" \
    || bad "no explanation for the skipped production push: ${OUT}"
git -C "${TMP}/w" rev-parse --verify --quiet origin/rehearse-prod >/dev/null \
    && bad "production ref was created from nothing" \
    || ok "…and created no production ref from nothing"

echo "── the second boundary on the same refs does promote ──"
# Now rehearse-staging exists and holds something, so production gets it.
jq '.boundary.phasesDone = ["branch","prove","main"]' "${TMP}/cfg/release-train.json" > "${TMP}/x" && mv "${TMP}/x" "${TMP}/cfg/release-train.json"
FAKE_NOW=$(( 1790000000 + 40*86400 )) run boundary --resume \
    --staging-branch rehearse-staging --production-branch rehearse-prod
[[ "$(git -C "${TMP}/w" rev-parse origin/rehearse-prod 2>/dev/null)" == "${_real_staging:0:0}$(git -C "${TMP}/w" rev-parse origin/main)" ]] \
    && ok "production now takes what staging held" || bad "second boundary did not promote"

echo "── --to: a VERSION move rewrites the release branch, not just the lock ──"
# nixos-25.11 is frozen, so a plain refresh can never reach nextcloud34/35
# (#709). The operator names the new release; the script never picks one.
# A stub `nix` so phase 1 can run here: the real one would fetch a branch.
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/nix" <<'STUB'
#!/usr/bin/env bash
# `nix flake update` resolves whatever ref flake.nix names, and writes the rev
# it found into flake.lock. Here: a rev derived from the ref, so the test can
# tell "it re-read the file" from "it wrote a constant".
[[ "$1" == "flake" && "$2" == "update" ]] || exit 0
ref="$(sed -n 's|.*github:NixOS/nixpkgs/\([^"]*\)".*|\1|p' flake.nix | head -1)"
if [[ -z "${ref}" ]]; then
    # No ref of its own: this flake `follows` templates, so re-locking it just
    # copies whatever templates resolved. That is the mothership (ADR-028 D1).
    cp ../templates/flake.lock flake.lock 2>/dev/null
    exit 0
fi
[[ "${ref}" == "nixos-25.11" ]] && exit 0   # frozen: nothing new to resolve
printf '{"nodes":{"nixpkgs":{"locked":{"rev":"%s","lastModified":1790000000}}}}\n' \
    "$(printf '%s' "${ref}" | shasum | cut -c1-40)" > flake.lock
STUB
chmod +x "${TMP}/bin/nix"

run_to() {  # phase 1 for real, everything else already done
    OUT="$(PATH="${TMP}/bin:${PATH}" TAPPAAS_REPO_DIR="${TMP}/w" TAPPAAS_CONFIG_DIR="${TMP}/cfg" \
           TAPPAAS_TRAIN_NOW="${FAKE_NOW:-}" "${TRAIN}" "$@" --no-fetch 2>&1)"
    RC=$?
}
setup_to() {
    make_train 3 2
    printf '{\n  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";\n}\n' \
        > "${TMP}/w/src/foundation/templates/flake.nix"
    mkdir -p "${TMP}/w/src/foundation/tappaas-cicd"
    printf '{\n  inputs.nixpkgs.follows = "templates/nixpkgs";\n}\n' \
        > "${TMP}/w/src/foundation/tappaas-cicd/flake.nix"
    cp "${TMP}/w/src/foundation/templates/flake.lock" "${TMP}/w/src/foundation/tappaas-cicd/flake.lock"
    git -C "${TMP}/w" add -A && git -C "${TMP}/w" commit -qm "flake"
    git -C "${TMP}/w" push -q origin main && git -C "${TMP}/w" fetch -q origin
    FAKE_NOW=1790000000 run init >/dev/null
    jq '.boundary.phasesDone = ["prove","main"]' "${TMP}/cfg/release-train.json" \
        > "${TMP}/x" && mv "${TMP}/x" "${TMP}/cfg/release-train.json"
}

setup_to
FAKE_NOW=$(( 1790000000 + 20*86400 )) run_to boundary --resume --to nixos-26.05 \
    --staging-branch rehearse-staging --production-branch rehearse-prod
[[ "${RC}" -eq 0 ]] && ok "a boundary with --to runs" || bad "--to boundary failed: ${OUT}"
grep -q 'github:NixOS/nixpkgs/nixos-26.05' "${TMP}/w/src/foundation/templates/flake.nix" \
    && ok "templates/flake.nix now names the new release" || bad "the ref was not rewritten"
[[ "${OUT}" == *"nixos-25.11 → nixos-26.05"* ]] && ok "the move is reported both ways" \
    || bad "the move was not reported: ${OUT}"
# The rewrite is worthless if the lock still holds the frozen branch's rev.
grep -q 'b77b3de8' "${TMP}/w/src/foundation/templates/flake.lock" \
    && bad "the lock still holds the old rev" || ok "…and the lock was re-resolved against it"
# `follows` decides where the mothership LOOKS, not what its own lock holds:
# measured on hrossen, templates moved to 26.05 and the mothership still
# resolved the old revision. One pin (D1) has to mean both files.
[[ "$(jq -r .nodes.nixpkgs.locked.rev "${TMP}/w/src/foundation/tappaas-cicd/flake.lock")" \
   == "$(jq -r .nodes.nixpkgs.locked.rev "${TMP}/w/src/foundation/templates/flake.lock")" ]] \
    && ok "the mothership lock moved with the guests" \
    || bad "the mothership was left on the old pin"

echo "── the pin commit carries the flake, not only the lock ──"
# A lock whose rev came from a ref that was never committed is a pin nobody
# else can reproduce.
_files="$(git -C "${TMP}/w" show --stat --name-only --format= HEAD)"
[[ "${_files}" == *"templates/flake.nix"* ]] && ok "flake.nix is in the pin commit" \
    || bad "flake.nix was left uncommitted: ${_files}"
[[ "${_files}" == *"templates/flake.lock"* ]] && ok "…together with the lock it produced" \
    || bad "flake.lock missing from the pin commit"
[[ "$(git -C "${TMP}/w" log -1 --format=%s)" == *"moves to nixos-26.05"* ]] \
    && ok "the commit says which release it moved to" \
    || bad "the commit subject hides the version move: $(git -C "${TMP}/w" log -1 --format=%s)"

echo "── a frozen branch with no --to refuses rather than commit nothing ──"
setup_to
FAKE_NOW=$(( 1790000000 + 20*86400 )) run_to boundary --resume \
    --staging-branch rehearse-staging --production-branch rehearse-prod
[[ "${RC}" -ne 0 ]] && ok "a pin that cannot move stops the boundary" \
    || bad "an unmoved pin was accepted"
[[ "${OUT}" == *"--to <nixos-XX.YY>"* ]] && ok "…and says what to do about it" \
    || bad "no advice for a frozen branch: ${OUT}"
# A phase 1 that gives up half way must leave nothing behind: the next run's
# preflight refuses a dirty checkout, so the failure would become sticky.
[[ -z "$(git -C "${TMP}/w" status --porcelain)" ]] \
    && ok "a refused phase 1 leaves the checkout clean" \
    || bad "phase 1 left changes behind: $(git -C "${TMP}/w" status --porcelain)"
[[ "$(git -C "${TMP}/w" rev-parse --abbrev-ref HEAD)" == "main" ]] \
    && ok "…and back on main" || bad "left on $(git -C "${TMP}/w" rev-parse --abbrev-ref HEAD)"

echo "── --to the release already in the tree is a no-op, not a rewrite ──"
setup_to
FAKE_NOW=$(( 1790000000 + 20*86400 )) run_to boundary --resume --to nixos-25.11 \
    --staging-branch rehearse-staging --production-branch rehearse-prod
[[ "${OUT}" == *"already tracking nixos-25.11"* ]] && ok "an unchanged ref is recognised" \
    || bad "no-op --to was not recognised: ${OUT}"
[[ "${RC}" -ne 0 ]] && ok "…and the frozen pin still refuses" || bad "a frozen no-op was accepted"

echo "── a flake with no nixpkgs ref is refused, never rewritten blind ──"
setup_to
printf '{\n  inputs.nixpkgs.url = "git+https://example.invalid/np";\n}\n' \
    > "${TMP}/w/src/foundation/templates/flake.nix"
git -C "${TMP}/w" commit -qam "odd flake" && git -C "${TMP}/w" push -q origin main \
    && git -C "${TMP}/w" fetch -q origin
FAKE_NOW=$(( 1790000000 + 20*86400 )) run_to boundary --resume --to nixos-26.05 \
    --staging-branch rehearse-staging --production-branch rehearse-prod
[[ "${RC}" -ne 0 && "${OUT}" == *"no github:NixOS/nixpkgs/<ref> found"* ]] \
    && ok "an unrecognised flake refuses the move" || bad "a blind rewrite was attempted: ${OUT}"
grep -q 'example.invalid' "${TMP}/w/src/foundation/templates/flake.nix" \
    && ok "…and left the file alone" || bad "the odd flake was modified"

echo "── phase 2 makes the SITE track the pin branch, not just the checkout ──"
# The failure this exists for, seen on hrossen 2026-09-23: the checkout was
# parked on the pin branch, the sweep refreshed the control plane, repo-sync
# reconciled the tree back to the branch site.json declares — and every module
# after the first guest was rebuilt against the OLD revision while the run
# reported progress. Only a DECLARED branch survives a sweep.
setup_prove() {
    setup_to
    # A module the guest-first step can pick: the signal is dependsOn, since
    # most guests declare no `os` field at all.
    printf '%s\n' '{"name":"euro-office","dependsOn":["templates:nixos"]}' > "${TMP}/cfg/euro-office.json"
    mkdir -p "${TMP}/bin2"
    # update-module.sh: the guest-first step.
    printf '#!/usr/bin/env bash\nexit 0\n' > "${TMP}/bin2/update-module.sh"
    chmod +x "${TMP}/bin2/update-module.sh"
    # Every phase runs here: 1 moves the pin, 2 proves it, 3 lands it and puts
    # the site back on main. The declaration's round trip is the point.
    jq '.boundary.phasesDone = []' "${TMP}/cfg/release-train.json" > "${TMP}/x" \
        && mv "${TMP}/x" "${TMP}/cfg/release-train.json"
    setup_sm_ok
}

# site-manager: `repository modify --branch` moves BOTH the declaration and the
# checkout, exactly as the real one does; `update` is repo-sync reconciling the
# tree to whatever site.json declares.
setup_sm_ok() {
    cat > "${TMP}/bin/site-manager" <<'STUB'
#!/usr/bin/env bash
W="${TAPPAAS_REPO_DIR}"
case "$1 $2" in
  "repository modify")
      br=""; for a in "$@"; do [[ "${_w:-}" == "1" ]] && { br="$a"; _w=0; }; [[ "$a" == "--branch" ]] && _w=1; done
      jq --arg b "${br}" '.repositories[0].branch = $b' "${TAPPAAS_CONFIG_DIR}/site.json" > "${TAPPAAS_CONFIG_DIR}/.s" \
        && mv "${TAPPAAS_CONFIG_DIR}/.s" "${TAPPAAS_CONFIG_DIR}/site.json"
      git -C "${W}" checkout -q "${br}" 2>/dev/null ;;
  "update"*)
      # repo-sync: reconcile the tree to whatever site.json DECLARES.
      d="$(jq -r '.repositories[0].branch' "${TAPPAAS_CONFIG_DIR}/site.json")"
      git -C "${W}" checkout -q "${d}" 2>/dev/null ;;
  *) : ;;
esac
exit 0
STUB
    chmod +x "${TMP}/bin/site-manager"
}
run_prove() {
    OUT="$(PATH="${TMP}/bin:${PATH}" TAPPAAS_BIN_DIR="${TMP}/bin2" \
           TAPPAAS_REPO_DIR="${TMP}/w" TAPPAAS_CONFIG_DIR="${TMP}/cfg" \
           TAPPAAS_TRAIN_NOW="${FAKE_NOW:-}" "${TRAIN}" "$@" --no-fetch 2>&1)"
    RC=$?
}

setup_prove
FAKE_NOW=$(( 1790000000 + 20*86400 )) run_prove boundary --resume --to nixos-26.05 \
    --staging-branch rehearse-staging --production-branch rehearse-prod
[[ "${RC}" -eq 0 ]] && ok "a boundary that declares the branch survives its own sweep" \
    || bad "phase 2 failed: ${OUT}"
[[ "${OUT}" == *"the site now tracks pin/"* ]] && ok "phase 2 says it is moving the declaration" \
    || bad "the branch declaration is invisible: ${OUT}"
[[ "$(jq -r .repositories[0].branch "${TMP}/cfg/site.json")" == "main" ]] \
    && ok "…and phase 3 puts the site back on main" \
    || bad "the site was left tracking $(jq -r .repositories[0].branch "${TMP}/cfg/site.json")"
git -C "${TMP}/w" rev-parse --verify --quiet origin/main >/dev/null \
    && ok "main was published" || bad "main was not published"

echo "── a boundary retried in the same week republishes its pin branch ──"
# The situation this comes from: a boundary BLOCKED in phase 2 (#721) never
# reaches phase 3, so the pin branch it published is still on the forge. The
# retry cuts the same name from origin/main again, carrying a different commit
# — and a plain push is refused as non-fast-forward, killing phase 1.
setup_prove
# A sweep that fails, so phase 3 (which would delete the branch) never runs.
cat > "${TMP}/bin/site-manager" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "repository modify") exit 0 ;;
  "update"*) exit 1 ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "${TMP}/bin/site-manager"
FAKE_NOW=$(( 1790000000 + 20*86400 )) run_prove boundary --resume --to nixos-26.05 \
    --staging-branch rehearse-staging --production-branch rehearse-prod
[[ "${RC}" -ne 0 ]] && ok "a blocked boundary stops" || bad "the blocked boundary did not stop"
git -C "${TMP}/w" rev-parse --verify --quiet "origin/pin/$(date -u +%Y-w%V)" >/dev/null \
    && ok "…and its pin branch stays on the forge for the retry" \
    || bad "the blocked run left no pin branch to clash with"

# The retry: main has moved on (the fix landed), so the same branch name now
# carries a different commit.
echo fixed > "${TMP}/w/f"; git -C "${TMP}/w" checkout -q main
git -C "${TMP}/w" add -A; git -C "${TMP}/w" commit -qm "the fix"
git -C "${TMP}/w" push -q origin main; git -C "${TMP}/w" fetch -q origin
jq '.boundary.phasesDone = []' "${TMP}/cfg/release-train.json" > "${TMP}/x" \
    && mv "${TMP}/x" "${TMP}/cfg/release-train.json"
setup_sm_ok    # a sweep that works again
FAKE_NOW=$(( 1790000000 + 40*86400 )) run_prove boundary --resume --to nixos-26.05 \
    --staging-branch rehearse-staging --production-branch rehearse-prod
[[ "${OUT}" != *"could not publish"* ]] && ok "the retry publishes over its own branch" \
    || bad "a same-week retry could not publish its pin branch"
[[ "${RC}" -eq 0 ]] && ok "…and the retried boundary completes" || bad "the retry failed: ${OUT}"

echo "── a sweep that resets the checkout is caught, not reported as proof ──"
setup_prove
# A site.json the train does not own — repo-sync then pulls the tree back to
# main during the sweep, which is precisely what happened on hrossen.
cat > "${TMP}/bin/site-manager" <<'STUB'
#!/usr/bin/env bash
W="${TAPPAAS_REPO_DIR}"
case "$1 $2" in
  "repository modify") exit 0 ;;                 # declaration ignored
  "update"*) git -C "${W}" checkout -q main 2>/dev/null ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "${TMP}/bin/site-manager"
FAKE_NOW=$(( 1790000000 + 20*86400 )) run_prove boundary --resume --to nixos-26.05 \
    --staging-branch rehearse-staging --production-branch rehearse-prod
[[ "${RC}" -ne 0 ]] && ok "a reverted checkout stops the boundary" \
    || bad "the boundary proceeded on the old revision"
[[ "${OUT}" == *"nothing after the guest was proved"* ]] \
    && ok "…and says exactly what was and was not proved" || bad "the reason is not reported: ${OUT}"
git -C "${TMP}/w" rev-parse --verify --quiet origin/rehearse-staging >/dev/null \
    && bad "a failed proof still promoted" || ok "and promoted nothing"

echo "── --allow-no-pin-change: prove what is already pinned ──"
# After a pin is landed by other means — or on a frozen branch — a boundary's
# value is the PROOF, not the move. Without this the run dies at phase 1 and
# the guest, the sweep and the deep test never happen.
setup_prove
FAKE_NOW=$(( 1790000000 + 20*86400 )) run_prove boundary --resume --allow-no-pin-change \
    --staging-branch rehearse-staging --production-branch rehearse-prod
[[ "${RC}" -eq 0 ]] && ok "a boundary runs with an unmoved pin when allowed" \
    || bad "--allow-no-pin-change did not run: ${OUT}"
[[ "${OUT}" == *"proving what is already pinned"* ]] && ok "…and says that is what it is doing" \
    || bad "the run does not say the pin was not moved"
[[ "${OUT}" == *"nothing to land"* ]] && ok "…and phase 3 lands nothing" \
    || bad "phase 3 tried to land a branch that was never made"
# The lie this must not tell: a pin commit for a move that did not happen.
[[ "$(git -C "${TMP}/w" log -1 --format=%s)" != chore\(pin\)* ]] \
    && ok "no pin commit is invented" || bad "an empty pin commit was made"
[[ "$(jq -r .boundary.noPinChange "${TMP}/cfg/release-train.json" 2>/dev/null)" != "true" ]] \
    && ok "…and the record is cleared when the boundary completes" \
    || bad "the boundary record was left behind"

echo "── without the flag an unmoved pin still stops the run ──"
setup_prove
FAKE_NOW=$(( 1790000000 + 20*86400 )) run_prove boundary --resume \
    --staging-branch rehearse-staging --production-branch rehearse-prod
[[ "${RC}" -ne 0 ]] && ok "silence does not authorize a boundary that proves nothing new" \
    || bad "an unmoved pin was accepted without the flag"
[[ "${OUT}" == *"--allow-no-pin-change"* ]] && ok "…and the refusal names the flag that would allow it" \
    || bad "the refusal does not mention the flag"

echo "── --help explains the two words the whole train turns on ──"
# An operator meeting this command needs to know what is being moved and what
# is being waited for. Both were jargon until now.
H="$("${TRAIN}" --help 2>&1)"
[[ "${H}" == *"The PIN is"* ]] && ok "--help says what a pin is" || bad "--help does not define the pin"
[[ "${H}" == *"The SOAK is"* ]] && ok "--help says what a soak is" || bad "--help does not define the soak"
# usage() prints a fixed line RANGE of the header. Grow the header without
# growing the range and the help silently loses its last lines — so assert the
# range still reaches the end.
[[ "${H}" == *"fault --resolved"* ]] \
    && ok "…and the range still reaches the last usage line" \
    || bad "--help is truncated: the sed range no longer covers the header"

echo "── channels.json: a repository says which branch is which channel (D11) ──"
CL_LIB="${HERE}/../../lib/channels-lib.sh"
if [[ ! -r "${CL_LIB}" ]]; then
    bad "channels-lib.sh not found beside the suite"
else
    . "${CL_LIB}"
    mkdir -p "${TMP}/decl" "${TMP}/undecl"
    printf '%s\n' '{"_README":"x","production":["stable"],"staging":["staging"],"unstable":["main"]}' \
        > "${TMP}/decl/channels.json"

    [[ "$(channel_branches "${TMP}/decl" production)" == "stable" ]] \
        && ok "a channel resolves to its branch" || bad "channel_branches wrong"
    [[ "$(branch_channel "${TMP}/decl" stable)" == "production" ]] \
        && ok "a branch resolves to its channel" || bad "branch_channel wrong"
    # The rule that keeps this safe: anything unlisted is unstable, never
    # production. A pin branch must not read as a release channel.
    [[ "$(branch_channel "${TMP}/decl" pin/2026-w39)" == "unstable" ]] \
        && ok "an unlisted branch is unstable, not production" || bad "unlisted branch misclassified"
    # Keys beginning with _ are prose, not channels.
    [[ "$(branch_channel "${TMP}/decl" _README)" == "unstable" ]] \
        && ok "…and a _README key is not a channel" || bad "_README treated as a channel"

    channel_matches "${TMP}/decl" stable production \
        && ok "stable matches production" || bad "stable should match production"
    channel_matches "${TMP}/decl" main production \
        && bad "main must NOT match production" || ok "main does not match production"

    # Undeclared is distinguishable from unstable: "nobody said" is what the
    # warning is about, and a repository that promises nothing never matches.
    channels_declared "${TMP}/undecl" && bad "an empty dir read as declared" \
        || ok "a repository without channels.json reads as undeclared"
    [[ -z "$(branch_channel "${TMP}/undecl" main)" ]] \
        && ok "…and returns nothing, so callers can tell it from 'unstable'" \
        || bad "undeclared repo answered as if it had declared"
    channel_matches "${TMP}/undecl" stable production \
        && bad "an undeclared repo matched a channel" || ok "…and never matches a channel"

    # Malformed JSON must read as undeclared, not crash a status run.
    printf '%s\n' '{ this is not json' > "${TMP}/undecl/channels.json"
    [[ -z "$(branch_channel "${TMP}/undecl" main)" ]] \
        && ok "unreadable channels.json reads as undeclared" || bad "malformed json was trusted"
    rm -f "${TMP}/undecl/channels.json"

    # site_repos must yield every registered repository, not just TAPPaaS.
    printf '%s\n' '{"repositories":[{"name":"TAPPaaS","branch":"main","path":"/a"},{"name":"Community","branch":"main","path":"/b"}]}' \
        > "${TMP}/site-two.json"
    [[ "$(site_repos "${TMP}/site-two.json" | wc -l | tr -d ' ')" == "2" ]] \
        && ok "every registered repository is returned, not only TAPPaaS" \
        || bad "site_repos did not return both repositories"
fi

echo "── a repository with no branch for the channel is its own case ──"
# A site on `production` tracking a repo that only ever cut `main`. The
# operator cannot fix this by switching branches — there is nothing to switch
# to — so it must not be reported as "you are on the wrong branch".
printf '%s\n' '{"unstable":["main"]}' > "${TMP}/decl/only-unstable.json"
mkdir -p "${TMP}/nobranch" && cp "${TMP}/decl/only-unstable.json" "${TMP}/nobranch/channels.json"
channels_declared "${TMP}/nobranch" \
    && ok "it IS declared — this is not the undeclared case" || bad "should read as declared"
[[ -z "$(channel_branches "${TMP}/nobranch" production)" ]] \
    && ok "…and offers no branch for production" || bad "production resolved to something"
[[ "$(branch_channel "${TMP}/nobranch" main)" == "unstable" ]] \
    && ok "…while its main is honestly unstable" || bad "main misclassified"
channel_matches "${TMP}/nobranch" main production \
    && bad "main matched production" || ok "…so a production site cannot claim it"

echo "── this repository declares its own channels ──"
# The file the rest of this depends on: if it goes missing, every site tracking
# TAPPaaS silently reads as unstable.
_CJ="${HERE}/../../../../../channels.json"
if [[ -r "${_CJ}" ]]; then
    ok "channels.json exists at the repository root"
    [[ "$(jq -r '.production[0]' "${_CJ}")" == "stable" ]] \
        && ok "…and names stable as production" || bad "production is not stable"
    [[ "$(jq -r '.unstable[0]' "${_CJ}")" == "main" ]] \
        && ok "…and main as unstable" || bad "unstable is not main"
else
    bad "channels.json missing from the repository root (${_CJ})"
fi

echo "── summary: ${PASS} pass, ${FAIL} fail ──"
[[ "${FAIL}" -eq 0 ]]
