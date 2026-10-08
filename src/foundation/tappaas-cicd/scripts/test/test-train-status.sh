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

# The module blueprint (ADR-027, #674) is checked by module-manager, which a
# fixture site does not have: a stub answers with the report in FAKE_BLUEPRINT
# (default: every module whole), so each test says what the check found.
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/module-manager" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${FAKE_MM_LOG:-/dev/null}"
clean='{"modules":["a"],"findings":[],"errors":0,"warnings":0}'
printf '%s\n' "${FAKE_BLUEPRINT:-${clean}}"
STUB
chmod +x "${TMP}/bin/module-manager"

# The secret scan (#378) is gitleaks; the stub writes the JSON report it would
# write — FAKE_LEAKS (default: none found) — and logs how it was called.
cat > "${TMP}/bin/gitleaks" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${FAKE_GL_LOG:-/dev/null}"
rp=""; while [[ $# -gt 0 ]]; do [[ "$1" == --report-path ]] && rp="$2"; shift; done
leaks="${FAKE_LEAKS:-[]}"; [[ "$*" == *" dir "* || -z "${FAKE_LEAKS_DIR:-}" ]] || leaks="${FAKE_LEAKS_DIR}"
printf '%s\n' "${leaks}" > "${rp}"
[[ "${leaks}" == "[]" ]]
STUB
chmod +x "${TMP}/bin/gitleaks"

run() {  # sets OUT/RC
    OUT="$(TAPPAAS_REPO_DIR="${TMP}/w" TAPPAAS_CONFIG_DIR="${TMP}/cfg" TAPPAAS_BIN_DIR="${TMP}/bin" \
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
[[ "$(jq -r '.soakStarted' "${TMP}/cfg/release-train.json")" == "2026-09-21T14:13:20Z" ]] \
    && ok "the start is recorded, as a date a person can read" || bad "soakStarted not written: $(cat "${TMP}/cfg/release-train.json")"
[[ "$(jq -r '.nextBoundary' "${TMP}/cfg/release-train.json")" == "2026-10-05" ]] \
    && ok "…and so is when the boundary falls due" || bad "nextBoundary wrong"
FAKE_NOW=1790000000 run status
[[ "${OUT}" == *"0 of 14 days"* ]] && ok "a fresh soak is not due" || bad "soak progress wrong: ${OUT}"
FAKE_NOW=$(( 1790000000 + 14*86400 )) run status
[[ "${OUT}" == *"boundary is due"* ]] && ok "after the interval the boundary is due" || bad "soak never completes"
# Re-running init must not restart the clock — that would hide a missed soak.
FAKE_NOW=$(( 1790000000 + 14*86400 )) run init
[[ "$(jq -r '.soakStarted' "${TMP}/cfg/release-train.json")" == "2026-09-21T14:13:20Z" ]] \
    && ok "init is idempotent: it does not restart a running clock" || bad "init reset the soak clock"
# A file from before D13 (epoch seconds) is still read.
jq 'del(.soakStarted) | .soakStartedAt = 1790000000' "${TMP}/cfg/release-train.json" > "${TMP}/x" \
    && mv "${TMP}/x" "${TMP}/cfg/release-train.json"
FAKE_NOW=$(( 1790000000 + 14*86400 )) run status
[[ "${OUT}" == *"boundary is due"* ]] && ok "the epoch shape before D13 is still read" || bad "old soakStartedAt ignored: ${OUT}"

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

echo "── the module blueprint gates a boundary (ADR-027 D5, #674) ──"
make_train 3 2
FAKE_NOW=1790000000 run init
BAD='{"modules":["coturn"],"findings":[{"module":"coturn","severity":"error","path":"services/turn/README.md","message":"missing"},{"module":"coturn","severity":"warning","path":"test.sh","message":"missing"}],"errors":1,"warnings":1}'
FAKE_BLUEPRINT="${BAD}" FAKE_NOW=$(( 1790000000 + 20*86400 )) run status
[[ "${OUT}" == *"module blueprint NOT met"* && "${OUT}" == *"coturn: services/turn/README.md"* ]] \
    && ok "status names the module and the missing MUST" || bad "status did not report the blueprint: ${OUT}"
[[ "${OUT}" == *"Not promotable"* ]] && ok "…and a missing MUST makes the train not promotable" || bad "blueprint did not block status"
[[ "$(jq -r '.blueprint // "none"' "${TMP}/cfg/release-train.json")" == "none" ]] \
    && ok "status records nothing" || bad "status wrote the blueprint record"
FAKE_BLUEPRINT="${BAD}" FAKE_NOW=$(( 1790000000 + 20*86400 )) run boundary --force-boundary
[[ "${RC}" -ne 0 && "${OUT}" == *"does not lift these"* && "${OUT}" == *"blueprint NOT met"* ]] \
    && ok "a missing MUST refuses the boundary, even with --force-boundary" || bad "the blueprint did not block: ${OUT}"
[[ "$(jq -r '.blueprint.ok, .blueprint.errors' "${TMP}/cfg/release-train.json" | tr '\n' ' ')" == "false 1 " ]] \
    && ok "the boundary records what it found, pass or fail" || bad "blueprint not recorded: $(jq -c .blueprint "${TMP}/cfg/release-train.json")"
FAKE_MM_LOG="${TMP}/mm.log" FAKE_NOW=$(( 1790000000 + 20*86400 )) run status
grep -q -- "validate --blueprint --repo ${TMP}/w --json" "${TMP}/mm.log" \
    && ok "the check runs on this repository only — TAPPaaS, not Community" || bad "module-manager called as: $(cat "${TMP}/mm.log")"
[[ "${OUT}" == *"module blueprint met"* ]] && ok "a clean report is shown as met" || bad "a clean report not shown as met"
rm -f "${TMP}/bin/module-manager.off"; mv "${TMP}/bin/module-manager" "${TMP}/bin/module-manager.off"
FAKE_NOW=$(( 1790000000 + 20*86400 )) run boundary --dry-run --force-boundary
[[ "${RC}" -ne 0 && "${OUT}" == *"could not be checked"* ]] \
    && ok "a blueprint that cannot be checked is not a pass" || bad "a missing module-manager passed: ${OUT}"
mv "${TMP}/bin/module-manager.off" "${TMP}/bin/module-manager"

echo "── no secret in what is released (#378) ──"
make_train 3 2
FAKE_NOW=1790000000 run init
LEAK='[{"RuleID":"github-fine-grained-pat","File":"'"${TMP}/w"'/docs/x.md","StartLine":3,"Commit":"abcdef123456","Secret":"REDACTED"}]'
FAKE_LEAKS="${LEAK}" FAKE_NOW=$(( 1790000000 + 20*86400 )) run status
[[ "${OUT}" == *"SECRETS found"* && "${OUT}" == *"docs/x.md:3 [github-fine-grained-pat]"* ]] \
    && ok "status names the file, line and rule — never the value" || bad "status did not report the finding: ${OUT}"
[[ "${OUT}" == *"Not promotable"* ]] && ok "…and a finding makes the train not promotable" || bad "a finding did not block status"
FAKE_LEAKS="${LEAK}" FAKE_NOW=$(( 1790000000 + 20*86400 )) run boundary --force-boundary
[[ "${RC}" -ne 0 && "${OUT}" == *"does not lift these"* && "${OUT}" == *"SECRETS found"* ]] \
    && ok "a finding refuses the boundary, even with --force-boundary" || bad "a finding did not block: ${OUT}"
[[ "$(jq -r '.secrets.ok, .secrets.findings, .secrets.range' "${TMP}/cfg/release-train.json" | tr '\n' ' ')" == "false 1 tree only (no release yet) " ]] \
    && ok "the boundary records what the scan found (no release yet: the tree)" || bad "secrets not recorded: $(jq -c .secrets "${TMP}/cfg/release-train.json")"
: > "${TMP}/gl.log"
FAKE_GL_LOG="${TMP}/gl.log" FAKE_NOW=$(( 1790000000 + 20*86400 )) run status
[[ "${OUT}" == *"no secret found"* ]] && ok "a clean scan is shown as such" || bad "a clean scan not shown: ${OUT}"
grep -q -- "dir ${TMP}/w " "${TMP}/gl.log" && grep -q -- "--redact" "${TMP}/gl.log" \
    && ok "the tree is scanned, redacted" || bad "gitleaks called as: $(cat "${TMP}/gl.log")"
rm -f "${TMP}/bin/gitleaks.off"; mv "${TMP}/bin/gitleaks" "${TMP}/bin/gitleaks.off"
TAPPAAS_GITLEAKS=/nonexistent/gitleaks FAKE_NOW=$(( 1790000000 + 20*86400 )) run boundary --dry-run --force-boundary
[[ "${RC}" -ne 0 && "${OUT}" == *"secret scan could not run"* ]] \
    && ok "a scan that cannot run is not a pass" || bad "a missing gitleaks passed: ${OUT}"
mv "${TMP}/bin/gitleaks.off" "${TMP}/bin/gitleaks"

echo "── container image pins are reported, never a refusal (#750) ──"
make_train 3 2
FAKE_NOW=1790000000 run init
echo '{"pins":[]}' > "${TMP}/w/src/image-pins.json" 2>/dev/null || { mkdir -p "${TMP}/w/src"; echo '{"pins":[]}' > "${TMP}/w/src/image-pins.json"; }
cat > "${TMP}/bin/image-pins" <<'STUB'
#!/usr/bin/env python3
import json
print(json.dumps({"tripwireDays": 45, "stale": 1, "unlisted": [{"image": "acme/x", "file": "src/x.nix"}], "pins": [
  {"module": "identity", "image": "ghcr.io/goauthentik/server", "kind": "tag", "pinned": "2026.8.3", "ageDays": 0,
   "latest": "2026.8.3", "newer": 0, "status": "ok", "file": "f", "maintainer": "@TAPPaaS"},
  {"module": "litellm", "image": "litellm/litellm", "kind": "tag", "pinned": "v1.85.0", "ageDays": 235,
   "latest": "v1.102.1", "newer": 17, "status": "stale", "file": "f", "maintainer": "@ErikDaniel007"}]}))
STUB
chmod +x "${TMP}/bin/image-pins"
TAPPAAS_IMAGE_PINS="${TMP}/bin/image-pins" FAKE_NOW=$(( 1790000000 + 20*86400 )) run status
[[ "${OUT}" == *"image litellm: litellm/litellm:v1.85.0, 235d old — 17 newer, latest v1.102.1 — STALE"* ]] \
    && ok "status names a stale pin, its age, its distance and its maintainer" || bad "stale pin not reported: ${OUT}"
[[ "${OUT}" == *"image identity: ghcr.io/goauthentik/server:2026.8.3, 0d old — current"* ]] \
    && ok "…and a current one as current" || bad "current pin not reported"
[[ "${OUT}" == *"not yet in src/image-pins.json: acme/x"* ]] && ok "…and what is not yet listed" || bad "unlisted not reported"
[[ "${OUT}" != *"Not promotable"* ]] && ok "a stale pin never makes the train unpromotable" || bad "a stale pin blocked: ${OUT}"
TAPPAAS_IMAGE_PINS="${TMP}/bin/image-pins" FAKE_NOW=$(( 1790000000 + 20*86400 )) run boundary --force-boundary
[[ "$(jq -r '.imagePins.stale, (.imagePins.pins | length)' "${TMP}/cfg/release-train.json" | tr '\n' ' ')" == "1 2 " ]] \
    && ok "the boundary records the pins" || bad "pins not recorded: $(jq -c .imagePins "${TMP}/cfg/release-train.json")"
rm -f "${TMP}/w/src/image-pins.json"

echo "── promotion is fast-forward only, and in order ──"
make_train 3 2
FAKE_NOW=1790000000 run init
# Phases 1-3 already done: the pin moved, the deep test passed, main landed.
# These fixtures exercise the promotions, which is what must not be done by hand.
jq '.boundary.phasesDone = ["branch","prove","main"]' "${TMP}/cfg/release-train.json" > "${TMP}/x" && mv "${TMP}/x" "${TMP}/cfg/release-train.json"
_stable_before="$(git -C "${TMP}/w" rev-parse origin/stable)"
_staging_before="$(git -C "${TMP}/w" rev-parse origin/staging)"
_main_before="$(git -C "${TMP}/w" rev-parse origin/main)"
FAKE_NOW=$(( 1790000000 + 20*86400 )) run boundary --resume
[[ "${RC}" -eq 0 ]] && ok "a due, proven boundary runs" || bad "boundary failed: ${OUT}"
[[ "$(git -C "${TMP}/w" rev-parse origin/stable)" == "${_staging_before}" ]] \
    && ok "stable became what staging WAS — the soaked revision, not the new one" \
    || bad "stable did not take staging's old position"
# Staging becomes main as it is after the release record (and ROADMAP.md cut) was
# committed to it: main itself, or main plus that one record commit.
_main_now="$(git -C "${TMP}/w" rev-parse origin/main)"
[[ "$(git -C "${TMP}/w" rev-parse origin/staging)" == "${_main_now}" ]] \
    && { [[ "${_main_now}" == "${_main_before}" ]] || [[ "$(git -C "${TMP}/w" rev-parse "${_main_now}~1")" == "${_main_before}" ]]; } \
    && ok "staging became main (with the release record on top)" || bad "staging did not advance to main"
[[ "$(git -C "${TMP}/w" rev-parse origin/stable)" != "${_stable_before}" ]] \
    && ok "production moved exactly one boundary" || bad "stable did not move"
[[ "$(jq -r '.soakStarted' "${TMP}/cfg/release-train.json")" == "2026-10-11T14:13:20Z" ]] \
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
    OUT="$(PATH="${TMP}/bin:${PATH}" TAPPAAS_BIN_DIR="${TMP}/bin" TAPPAAS_REPO_DIR="${TMP}/w" TAPPAAS_CONFIG_DIR="${TMP}/cfg" \
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

echo "── pin preview and ack: what a pin move brings is accepted before the deep test (#788) ──"
# The findings are stubbed: FAKE_GATE is the list of items the next pin brings.
export TAPPAAS_PIN_FINDINGS='printf "{\"gate\":%s,\"digest\":\"d\",\"to\":\"abc\",\"majors\":[],\"cves\":{}}\n" "${FAKE_GATE:-[]}" > "$3"'
setup_to
FAKE_GATE='[]' run_to preview
[[ "${RC}" -eq 0 && "${OUT}" == *"nothing to acknowledge"* ]] && ok "a pin bringing nothing notable: no ack needed" || bad "empty preview: ${OUT}"
[[ -s "${TMP}/cfg/train-preview.json" ]] && ok "…and the preview is written to config" || bad "no train-preview.json"
FAKE_GATE='["major grafana 13->14"]' run_to preview
[[ "${OUT}" == *"stops before its deep test until 1 item(s) are accepted"* && "${OUT}" != *"    major grafana 13->14"* ]] \
    && ok "what needs an ack is one line, not a list" || bad "ack line: ${OUT}"
[[ "${OUT}" == *"preview --module <name>"* ]] && ok "…pointing at the per-module view" || bad "no --module hint: ${OUT}"
printf '{"baseLabel":"v2.1","from":"a","to":"b","modules":{"logging":{"module":"logging","approximate":false,"note":"","image":{},"packages":[],"cves":{"new":[{"id":"CVE-2","severity":"High","packages":[{"pkg":"grafana","version":"14.0.1","fixed":"","from":"nixos"}]}],"fixed":[],"same":[],"vex":[]}}}}' > "${TMP}/cfg/train-preview-details.json"
run_to preview --module logging
[[ "${RC}" -eq 0 && "${OUT}" == *"NEW"*"CVE-2"*"grafana"* ]] && ok "preview --module shows one module from the details" || bad "--module: ${OUT}"
FAKE_GATE='["major grafana 13->14"]' FAKE_NOW=$(( 1790000000 + 20*86400 )) run_to boundary --resume --to nixos-26.05
[[ "${RC}" -ne 0 && "${OUT}" == *"stopped before the deep test"* && "${OUT}" == *"major grafana 13->14"* ]] \
    && ok "the boundary stops on an unaccepted major, before the deep test" || bad "boundary went on: ${OUT}"
[[ -z "$(git -C "${TMP}/w" status --porcelain)" && "$(git -C "${TMP}/w" rev-parse --abbrev-ref HEAD)" == "main" ]] \
    && ok "…leaving the checkout clean, on main" || bad "the gate left the checkout dirty"
FAKE_GATE='["major grafana 13->14"]' run_to boundary --dry-run --force-boundary
[[ "${OUT}" == *"the gate would STOP on 1 unacknowledged item"* ]] && ok "a dry run says the gate would stop" || bad "dry run silent: ${OUT}"
NOTE_OUT="$(PATH="${TMP}/bin:${PATH}" TAPPAAS_REPO_DIR="${TMP}/w" TAPPAAS_CONFIG_DIR="${TMP}/cfg" TAPPAAS_TRAIN_NOW=$(( 1790000000 + 20*86400 )) "${TRAIN}" ack --note "read the Grafana 14 notes" --no-fetch 2>&1)"
[[ "${NOTE_OUT}" == *"acknowledged 1 item"* && "$(jq -r '.ack.note' "${TMP}/cfg/release-train.json")" == "read the Grafana 14 notes" ]] \
    && ok "ack records what was accepted, and why" || bad "ack: ${NOTE_OUT}"
FAKE_GATE='["major grafana 13->14"]' run_to boundary --dry-run --force-boundary
[[ "${OUT}" == *"all acknowledged — the gate would pass"* ]] && ok "…and a dry run then says the gate would pass" || bad "dry run after ack: ${OUT}"
FAKE_GATE='["cve CVE-2026-9 openssl","major grafana 13->14"]' FAKE_NOW=$(( 1790000000 + 20*86400 )) run_to boundary --resume --to nixos-26.05
[[ "${RC}" -ne 0 && "${OUT}" == *"cve CVE-2026-9 openssl"* && "${OUT}" != *"    major grafana"* ]] \
    && ok "something new beyond the ack stops it again, naming only the new item" || bad "a new item passed: ${OUT}"
FAKE_GATE='["major grafana 13->14"]' FAKE_NOW=$(( 1790000000 + 20*86400 )) run_to boundary --resume --to nixos-26.05
[[ "${RC}" -eq 0 && "${OUT}" == *"all acknowledged"* ]] && ok "what was accepted goes ahead" || bad "acked boundary failed: ${OUT}"
_rel="$(git -C "${TMP}/w" show origin/main:release/releases.json 2>/dev/null)"
[[ "$(jq -c '[.releases[] | .accepted // empty] | add' <<<"${_rel}")" == '["major grafana 13->14"]' ]] \
    && ok "…the release record names what was accepted" || bad "accepted not recorded: ${_rel}"
[[ "$(jq -r '.ack // "gone"' "${TMP}/cfg/release-train.json")" == "gone" ]] && ok "…and the ack is used up by the boundary" || bad "ack survived the boundary"
FAKE_GATE='[]' run_to preview
FAKE_GATE='[]' run_to ack
[[ "${RC}" -eq 0 && "${OUT}" == *"nothing to acknowledge"* ]] && ok "ack with nothing to accept says so" || bad "ack on empty: ${OUT}"
unset TAPPAAS_PIN_FINDINGS

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
    cp "${TMP}/bin/module-manager" "${TMP}/bin2/module-manager"   # the blueprint stub (#674)
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

# ── versions (ADR-028 D13) ──────────────────────────────────────────
tags_on() { git -C "${TMP}/w" tag --points-at "$1" | tr '\n' ' '; }
releases_on_main() { git -C "${TMP}/w" show origin/main:release/releases.json 2>/dev/null; }
proven() { jq '.boundary.phasesDone = ["branch","prove","main"]' "${TMP}/cfg/release-train.json" > "${TMP}/x" && mv "${TMP}/x" "${TMP}/cfg/release-train.json"; }

echo "── a boundary cuts the next minor into staging, as a tag ──"
make_train 3 2
# Production on the 2.0 line (past its tag, as on the real train), staging
# already numbered 2.1 — the shape the retro-tag left.
git -C "${TMP}/w" tag -a v2.0 -m "TAPPaaS 2.0" "origin/stable~1"
git -C "${TMP}/w" tag -a v2.1 -m "TAPPaaS 2.1" origin/staging
git -C "${TMP}/w" push -q origin v2.0 v2.1
# A ROADMAP.md and the real release/roadmap-cut.py on main, so the boundary cuts the roadmap
# the way it will in the repository: one ✅ row to move, one open row to stay.
mkdir -p "${TMP}/w/release"
cp "${HERE}/../../../../../release/roadmap-cut.py" "${TMP}/w/release/roadmap-cut.py"
cat > "${TMP}/w/ROADMAP.md" <<'EOF'
# TAPPaaS Roadmap

## At a glance

old table

## Wave 1 — the test wave

What it is for.

### G1.1 A group — Ease L · Risk L · done for 2.2: 1 · open: 1

Intent.

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #1 | the done thing | L | L | done |
| #2 | the open thing | L | L | open |

## Next release

<!-- next-release summary -->
The test release: the done thing.
<!-- /next-release summary -->

## Release 2.1 — staging 2026-09-25 · production at the next boundary

Tag `v2.1`.

## Release 2.0 — production 2026-07-21

Before.
EOF
git -C "${TMP}/w" add -A; git -C "${TMP}/w" commit -qm "docs: a roadmap"
git -C "${TMP}/w" push -q origin main; git -C "${TMP}/w" fetch -q origin
FAKE_NOW=1790000000 run status
[[ "${OUT}" == *"2.0+1"* && "${OUT}" == *" 2.1 "* ]] \
    && ok "status shows each channel's version (production is 2.0 plus one commit)" || bad "versions not shown: ${OUT}"
FAKE_NOW=1790000000 run init; proven
FAKE_NOW=$(( 1790000000 + 20*86400 )) run boundary --resume --dry-run
[[ "${OUT}" == *"tag it"*"v2.2"* ]] && ok "the plan names the version it will cut" || bad "plan without a version: ${OUT}"
[[ "${OUT}" == *"ROADMAP.md: 2.2: 1 row move"* ]] && ok "the dry run says what the ROADMAP.md cut would move" || bad "no roadmap cut in the plan: ${OUT}"
[[ "$(git -C "${TMP}/w" show origin/main:ROADMAP.md)" != *"## Release 2.2"* ]] && ok "…and changes nothing" || bad "a dry run cut the roadmap"
_main_before="$(git -C "${TMP}/w" rev-parse origin/main)"
FAKE_NOW=$(( 1790000000 + 20*86400 )) run boundary --resume
[[ "${RC}" -eq 0 ]] && ok "the boundary runs" || bad "boundary failed: ${OUT}"
[[ "$(tags_on origin/staging)" == *"v2.2"* ]] && ok "staging's new revision is tagged v2.2" || bad "no v2.2 on staging: $(tags_on origin/staging)"
git -C "${TMP}/w" ls-remote --tags "${TMP}/origin" | grep -q 'refs/tags/v2.2$' \
    && ok "…and the tag is published" || bad "v2.2 not pushed"
_msg="$(git -C "${TMP}/w" tag -l --format='%(contents)' v2.2)"
[[ "${_msg}" == *"TAPPaaS 2.2"* && "${_msg}" == *"Cut into staging 2026-10-11"* && "${_msg}" == *"Previous:   v2.1"* ]] \
    && ok "the tag says when it was cut and what came before" || bad "tag message: ${_msg}"
[[ "$(git -C "${TMP}/w" rev-parse origin/stable)" == "$(git -C "${TMP}/w" rev-parse 'v2.1^{commit}')" ]] \
    && ok "production now runs 2.1" || bad "production is not 2.1"
_r="$(releases_on_main)"
[[ "$(jq -r '.releases[] | select(.version=="2.2") | .staging' <<<"${_r}")" == "2026-10-11" ]] \
    && ok "release/releases.json on main records 2.2 entering staging" || bad "2.2 not recorded: ${_r}"
[[ "$(jq -r '.releases[] | select(.version=="2.1") | .production' <<<"${_r}")" == "2026-10-11" ]] \
    && ok "…and 2.1 reaching production" || bad "2.1 production not recorded: ${_r}"
git -C "${TMP}/w" show origin/main:RELEASES.md | grep -q '^| 2.2 | ' \
    && ok "RELEASES.md is rendered from it" || bad "RELEASES.md missing the row"
[[ "$(git -C "${TMP}/w" log -1 --format=%s origin/main)" == "chore(release): 2.2 to staging, 2.1 to production" ]] \
    && ok "one commit on main says what moved" || bad "record commit: $(git -C "${TMP}/w" log -1 --format=%s origin/main)"
[[ "$(git -C "${TMP}/w" rev-parse origin/main~1)" == "${_main_before}" ]] \
    && ok "…and it is the only thing added to main" || bad "main moved by more than the record"
# Recorded BEFORE main reached staging: the v2.2 tag holds its own record and roadmap.
_rm="$(git -C "${TMP}/w" show v2.2:ROADMAP.md)"
[[ "$(git -C "${TMP}/w" show v2.2:release/releases.json | jq -r '.releases[] | select(.version=="2.2") | .staging')" == "2026-10-11" ]] \
    && ok "the v2.2 tag already holds its own release record" || bad "v2.2 lacks its record"
[[ "${_rm}" == *"## Release 2.2 — staging 2026-10-11 · production at the next boundary"* ]] \
    && ok "…and its ROADMAP.md has a Release 2.2 section" || bad "no 2.2 section in v2.2: ${_rm}"
[[ "${_rm}" == *"The test release: the done thing."* ]] && ok "…summarised from Next release" || bad "the Next release text was not used"
[[ "$(sed -n '/^## Wave 1/,/^## Next release/p' <<< "${_rm}")" != *"the done thing"* && "${_rm}" == *"| #2 | the open thing"* ]] \
    && ok "the done row left the wave, the open one stayed" || bad "rows not moved: ${_rm}"
[[ "${_rm}" == *"### G1.1 A group — Ease L · Risk L · released: 1 · open: 1"* ]] \
    && ok "the group heading counts it as released" || bad "heading not recounted"
[[ "${_rm}" == *"## Release 2.1 — staging 2026-09-25 · production 2026-10-11"* ]] \
    && ok "2.1's section records it reached production" || bad "2.1 production date not written"
git -C "${TMP}/w" show origin/main:RELEASES.md | grep -q '^| 2.2 | `v2.2` |' \
    && ok "RELEASES.md names the tag while the commit cannot name itself" || bad "RELEASES.md 2.2 row: $(git -C "${TMP}/w" show origin/main:RELEASES.md | grep '^| 2.2')"
_st="${TMP}/cfg/release-train.json"
[[ "$(jq -r '.channels.staging.version, .channels.production.version, .lastBoundary.cut, .nextBoundary' "${_st}" | tr '\n' ' ')" \
   == "2.2 2.1 2.2 2026-10-25 " ]] && ok "the state file reads as versions and dates" || bad "state: $(jq -c . "${_st}")"
FAKE_NOW=$(( 1790000000 + 21*86400 )) run status
[[ "${OUT}" == *"cuts 2.3, 2.2 reaches production"* ]] && ok "status says what the next boundary will do" || bad "no next-boundary line: ${OUT}"
run releases
[[ "${OUT}" == *"2.2"*"2026-10-11"* && "${OUT}" == *"now: staging 2.2, production 2.1"* ]] \
    && ok "releases lists the history from main" || bad "releases: ${OUT}"

echo "── a resumed boundary numbers nothing twice ──"
jq '.boundary = {phasesDone: ["branch","prove","main","production","staging"], cut: "2.2", kind: "minor"}' "${_st}" > "${TMP}/x" && mv "${TMP}/x" "${_st}"
_main_before="$(git -C "${TMP}/w" rev-parse origin/main)"
FAKE_NOW=$(( 1790000000 + 34*86400 )) run boundary --resume
[[ "${RC}" -eq 0 ]] && ok "a resume after the tag runs" || bad "resume failed: ${OUT}"
[[ "$(tags_on origin/staging)" != *"v2.3"* ]] && ok "it does not cut another version" || bad "a resume cut v2.3"
[[ "$(git -C "${TMP}/w" rev-parse origin/main)" == "${_main_before}" ]] \
    && ok "…nor record the release again" || bad "the record was committed twice"

echo "── --major cuts the next major ──"
proven; jq '.boundary.cut = null | .boundary.kind = null' "${_st}" > "${TMP}/x" && mv "${TMP}/x" "${_st}"
echo more > "${TMP}/w/g"; git -C "${TMP}/w" add -A; git -C "${TMP}/w" commit -qm "c9"
git -C "${TMP}/w" push -q origin main; git -C "${TMP}/w" fetch -q origin
FAKE_NOW=$(( 1790000000 + 60*86400 )) run boundary --resume --major
[[ "$(tags_on origin/staging)" == *"v3.0"* ]] && ok "staging is cut as v3.0" || bad "no v3.0: ${OUT}"
[[ "$(releases_on_main | jq -r '.releases[] | select(.version=="3.0") | .kind')" == "major" ]] \
    && ok "…and recorded as a major" || bad "3.0 not recorded as major"
[[ "$(releases_on_main | jq -r '.releases[] | select(.version=="2.2") | .commit')" == "$(git -C "${TMP}/w" rev-parse --short=12 'v2.2^{commit}')" ]] \
    && ok "2.2's commit is filled in when it reaches production" || bad "2.2 commit: $(releases_on_main | jq -c '.releases[] | select(.version=="2.2")')"

echo "── a rehearsal numbers nothing ──"
make_train 3 2
git -C "${TMP}/w" tag -a v2.1 -m "TAPPaaS 2.1" origin/staging; git -C "${TMP}/w" push -q origin v2.1
FAKE_NOW=1790000000 run init; proven
_main_before="$(git -C "${TMP}/w" rev-parse origin/main)"
FAKE_NOW=$(( 1790000000 + 20*86400 )) run boundary --resume --staging-branch rehearse-staging --production-branch rehearse-prod
[[ "${RC}" -eq 0 && -z "$(git -C "${TMP}/w" tag -l 'v2.2')" ]] && ok "no tag from a rehearsal" || bad "a rehearsal tagged: ${OUT}"
[[ "$(git -C "${TMP}/w" rev-parse origin/main)" == "${_main_before}" ]] && ok "…and no record on main" || bad "a rehearsal wrote the record"

echo "── patch: an urgent fix is numbered MAJOR.MINOR.N (ADR-028 D12) ──"
make_train 3 2
git -C "${TMP}/w" tag -a v2.0 -m "TAPPaaS 2.0" origin/stable
git -C "${TMP}/w" tag -a v2.1 -m "TAPPaaS 2.1" origin/staging; git -C "${TMP}/w" push -q origin v2.0 v2.1
FAKE_NOW=1790000000 run init
# D12: the fix is authored off staging's tip, then merged into main.
git -C "${TMP}/w" checkout -q -b fix origin/staging
echo fixed > "${TMP}/w/fix"; git -C "${TMP}/w" add -A; git -C "${TMP}/w" commit -qm "fix: grafana can read its secrets"
_fix="$(git -C "${TMP}/w" rev-parse HEAD)"
git -C "${TMP}/w" checkout -q main
run patch staging "${_fix}" --why "service down: grafana"
[[ "${RC}" -ne 0 && "${OUT}" == *"not on main"* ]] && ok "a fix not yet on main is refused" || bad "accepted a fix off main: ${OUT}"
git -C "${TMP}/w" merge -q --no-edit "${_fix}"; git -C "${TMP}/w" push -q origin main; git -C "${TMP}/w" fetch -q origin
run patch staging "${_fix}"
[[ "${RC}" -ne 0 && "${OUT}" == *"--why"* ]] && ok "a patch without a reason is refused" || bad "no --why accepted: ${OUT}"
run patch staging "${_fix}" --why "it is finished"
[[ "${RC}" -ne 0 && "${OUT}" == *"must start with the D12 case"* ]] && ok "a reason that names no D12 case is refused (#746)" || bad "a reason without a clause accepted: ${OUT}"
run patch production "${_fix}" --why "service down: grafana"
[[ "${RC}" -ne 0 && "${OUT}" == *"ahead of staging"* ]] && ok "production may not get ahead of staging" || bad "production overtook staging: ${OUT}"
FAKE_NOW=$(( 1790000000 + 3*86400 )) run patch staging "${_fix}" --why "service down: grafana"
[[ "${RC}" -eq 0 ]] && ok "the staging patch runs" || bad "patch failed: ${OUT}"
[[ "$(git -C "${TMP}/w" rev-parse origin/staging)" == "${_fix}" ]] && ok "staging moved onto the fix, and only the fix" || bad "staging not at the fix"
[[ "$(tags_on "${_fix}")" == *"v2.1.1"* ]] && ok "the fix is v2.1.1" || bad "no v2.1.1: $(tags_on "${_fix}")"
[[ "$(releases_on_main | jq -r '.releases[] | select(.version=="2.1.1") | "\(.kind) \(.channel) \(.staging)"')" == "patch staging 2026-09-24" ]] \
    && ok "the record names it an urgent fix, with the date" || bad "patch not recorded: $(releases_on_main)"
[[ "$(jq -r '.expedited[0].why' "${TMP}/cfg/release-train.json")" == "service down: grafana" ]] \
    && ok "the site records that it carries an expedited fix (D12)" || bad "expedited not recorded"
FAKE_NOW=$(( 1790000000 + 3*86400 )) run status
[[ "${OUT}" == *"carrying an urgent fix: 2.1.1 on staging"* ]] && ok "status says so" || bad "status silent about the fix: ${OUT}"
run patch staging "${_fix}" --why "service down: again"
[[ "${RC}" -ne 0 && "${OUT}" == *"already at"* ]] && ok "the same patch twice is refused" || bad "re-patch accepted"
# A commit that does not build on the channel's tip would rewind or fork it.
run patch production "$(git -C "${TMP}/w" rev-parse origin/stable~1)" --why "security: x"
[[ "${RC}" -ne 0 && "${OUT}" == *"does not build on"* ]] && ok "a commit behind the channel is refused" || bad "accepted a commit behind stable: ${OUT}"
# D12: the site patched in place — a dirty checkout — is said by status (#746).
echo "patched in place" >> "${TMP}/w/fix"
FAKE_NOW=$(( 1790000000 + 3*86400 )) run status
[[ "${OUT}" == *"uncommitted changes in 1 file(s)"* ]] && ok "status reports a checkout patched in place" || bad "status silent about a dirty checkout: ${OUT}"
git -C "${TMP}/w" checkout -q -- fix
# The next boundary promotes the fix with everything else and says it supersedes it.
proven
FAKE_NOW=$(( 1790000000 + 20*86400 )) run boundary --resume
[[ "${OUT}" == *"supersedes the urgent fixes 2.1.1"* ]] && ok "the boundary says which urgent fixes it supersedes" || bad "boundary silent about 2.1.1: ${OUT}"
[[ "$(releases_on_main | jq -c '[.releases[] | select(.supersedes) | .supersedes[]]')" == '["2.1.1"]' ]] \
    && ok "…and its record names them" || bad "no supersedes in the record: $(releases_on_main)"
[[ "$(jq -c '.expedited // []' "${TMP}/cfg/release-train.json")" == "[]" ]] && ok "…and the site no longer carries them" || bad "expedited survived the boundary"

echo "── patch production: the documented route, staging first ──"
make_train 3 2
git -C "${TMP}/w" tag -a v2.0 -m "TAPPaaS 2.0" origin/stable
git -C "${TMP}/w" tag -a v2.1 -m "TAPPaaS 2.1" origin/staging; git -C "${TMP}/w" push -q origin v2.0 v2.1
FAKE_NOW=1790000000 run init
git -C "${TMP}/w" checkout -q -b hf origin/stable
echo cve > "${TMP}/w/cve"; git -C "${TMP}/w" add -A; git -C "${TMP}/w" commit -qm "fix: the CVE"
_F="$(git -C "${TMP}/w" rev-parse HEAD)"
git -C "${TMP}/w" checkout -q -b hf-staging origin/staging; git -C "${TMP}/w" merge -q --no-ff --no-edit hf
_M="$(git -C "${TMP}/w" rev-parse HEAD)"
git -C "${TMP}/w" checkout -q main; git -C "${TMP}/w" merge -q --no-ff --no-edit hf-staging
git -C "${TMP}/w" push -q origin main; git -C "${TMP}/w" fetch -q origin
FAKE_NOW=$(( 1790000000 + 2*86400 )) run patch staging "${_M}" --why "security: CVE-2026-0001"
[[ "${RC}" -eq 0 && "$(tags_on "${_M}")" == *"v2.1.1"* ]] && ok "staging takes the merge as v2.1.1" || bad "staging patch: ${OUT}"
FAKE_NOW=$(( 1790000000 + 2*86400 )) run patch production "${_F}" --why "security: CVE-2026-0001"
[[ "${RC}" -eq 0 && "$(tags_on "${_F}")" == *"v2.0.1"* ]] && ok "then production takes the fix alone as v2.0.1" || bad "production patch: ${OUT}"
[[ "$(git -C "${TMP}/w" rev-list --count "v2.0..origin/stable")" == "1" ]] && ok "production moved by exactly the fix" || bad "production moved by more"
git -C "${TMP}/w" merge-base --is-ancestor origin/stable origin/staging && git -C "${TMP}/w" merge-base --is-ancestor origin/staging origin/main \
    && ok "stable ⊆ staging ⊆ main still holds" || bad "the patch broke the ancestry"
[[ "$(releases_on_main | jq -r '.releases[] | select(.version=="2.0.1") | .production')" == "2026-09-23" ]] \
    && ok "the record dates production's fix" || bad "2.0.1 not recorded: $(releases_on_main)"

echo "── deployed drift: what runs against what the checkout declares (ADR-028 D12, #746) ──"
DD_LIB="${HERE}/../../lib/deployed-drift.sh"
if [[ ! -r "${DD_LIB}" ]]; then
    bad "deployed-drift.sh not found beside the suite"
else
    . "${DD_LIB}"
    D="${TMP}/dd"; mkdir -p "${D}/r/src/m" "${D}/bin"
    git -C "${D}/r" init -q; git -C "${D}/r" config user.email t@t; git -C "${D}/r" config user.name t
    echo 'echo v1' > "${D}/r/src/m/tool.sh"; git -C "${D}/r" add -A; git -C "${D}/r" commit -qm one
    cp "${D}/r/src/m/tool.sh" "${D}/bin/tool.sh"; ln -s "${D}/r/src/m/tool.sh" "${D}/bin/linked.sh"
    [[ -z "$(deployed_drift "${D}/r" "${D}/bin")" ]] && ok "a copy equal to its source and a link: nothing to say" || bad "clean state reported: $(deployed_drift "${D}/r" "${D}/bin")"
    echo 'echo hotfix' > "${D}/bin/tool.sh"
    [[ "$(deployed_drift "${D}/r" "${D}/bin")" == *"tool.sh differs from"* ]] && ok "a copy patched in ~/bin is reported" || bad "edited copy not reported"
    cp "${D}/r/src/m/tool.sh" "${D}/bin/tool.sh"; echo 'echo x' > "${D}/bin/orphan.sh"
    [[ "$(deployed_drift "${D}/r" "${D}/bin")" == *"orphan.sh is a plain file with no source"* ]] && ok "a plain file with no source is reported" || bad "orphan not reported"
    rm -f "${D}/bin/orphan.sh"; echo 'echo v2' > "${D}/r/src/m/tool.sh"
    [[ "$(deployed_drift "${D}/r" "${D}/bin")" == *"uncommitted changes in 1 file(s)"* ]] && ok "a checkout edited in place is reported" || bad "dirty checkout not reported"
    [[ "$(deployed_drift "${D}/r" "${D}/nobin"; echo "rc=$?")" == *"rc=0"* ]] && ok "it reports, never fails" || bad "deployed_drift failed"
fi

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
