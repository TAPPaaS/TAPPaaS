#!/usr/bin/env bash
#
# test-authentik-step.sh — an Authentik guest moves at most one step per build (#748).
#
# ak-step.nix reads the version the guest runs (its version file, or — before that
# file existed — the env file its first boot wrote) and builds the next step along
# the release lines: an older patch goes to its line's latest, a line's latest to
# the next line, a fresh install straight to the target. Evaluated here with
# nix-instantiate against fixture files.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEP="${HERE}/ak-step.nix"
PASS=0; FAIL=0
ck()   { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
ckin() { if [[ "$3" == *"$2"* ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (missing '$2' in: $3)"; FAIL=$((FAIL+1)); fi; }
command -v nix-instantiate >/dev/null 2>&1 || { echo "nix-instantiate not available — skipped."; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/ak-step.XXXXXX")"; trap 'rm -rf "${T}"' EXIT

LINES='[ "2025.2.4" "2025.4.4" "2025.6.4" "2025.8.6" "2025.10.4" "2025.12.6" "2026.2.7" "2026.5.7" "2026.8.3" ]'
ev() {  # $1 = attribute; files in ${T}: version, env, blocked
    nix-instantiate --eval --strict 2>&1 -E "(import ${STEP} {
        lines = ${LINES};
        versionFile = \"${T}/version\"; legacyMarker = \"${T}/env\"; blockerFile = \"${T}/blocked\";
    }).$1" | tr -d '"'
}
reset() { rm -f "${T}/version" "${T}/env" "${T}/blocked"; }

reset
ck "fresh install (no database): straight to the target" "2026.8.3" "$(ev step)"
ck "…which needs no Redis"                               "false"    "$(ev redis)"
ck "…and mounts /data"                                   "true"     "$(ev dataMount)"

reset; echo "AUTHENTIK_SECRET_KEY=x" > "${T}/env"
ck "an install from before the version file runs 2025.2.1 → that line's latest patch first" "2025.2.4" "$(ev step)"
ck "…still with Redis"   "true"  "$(ev redis)"
ck "…still on /media"    "false" "$(ev dataMount)"

reset; printf '2025.2.4\n' > "${T}/version"
ck "a line's latest patch → the next line" "2025.4.4" "$(ev step)"
printf '2025.8.6' > "${T}/version"
ck "2025.8 → 2025.10" "2025.10.4" "$(ev step)"
ck "2025.10 drops Redis" "false" "$(ev redis)"
printf '2025.10.4' > "${T}/version"
ck "2025.10 → 2025.12" "2025.12.6" "$(ev step)"
ck "2025.12 moves files to /data" "true" "$(ev dataMount)"
printf '2025.12.2' > "${T}/version"
ck "an older patch of 2025.12 → 2025.12's latest, not the next line" "2025.12.6" "$(ev step)"
printf '2026.8.3' > "${T}/version"
ck "on the target: stays" "2026.8.3" "$(ev step)"
ck "…and says so" "true" "$(ev onTarget)"
printf '2026.8.1' > "${T}/version"
ck "an older patch of the target line → the target" "2026.8.3" "$(ev step)"

printf '2026.11.1' > "${T}/version"
ckin "newer than the target: refused, never downgraded" "cannot go back" "$(ev step)"
printf '2024.12.3' > "${T}/version"
ckin "older than the first step: refused, not jumped" "older than the first step" "$(ev step)"
printf '2025.3.1' > "${T}/version"
ckin "a line the release does not know: refused" "does not know" "$(ev step)"

# The pre-check's blocker stops only a step into 2025.12 or later, before anything changes.
printf '2025.10.4' > "${T}/version"; echo "duplicate group names: admins" > "${T}/blocked"
ckin "a blocker stops the step into 2025.12, naming why" "duplicate group names: admins" "$(ev step)"
printf '2025.6.4' > "${T}/version"
ck "…but not a step that does not migrate groups" "2025.8.6" "$(ev step)"

echo "── authentik step: ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
