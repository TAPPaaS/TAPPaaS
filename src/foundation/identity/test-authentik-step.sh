#!/usr/bin/env bash
#
# test-authentik-step.sh — an Authentik guest moves at most one step per build (#748).
#
# build-facts.sh says what the guest runs (its version file, or — before that file
# existed — the env file its first boot wrote; none for a fresh install, unknown
# for a database with no record), and ak-step.nix builds the next step along the
# release lines from those facts: an older patch goes to its line's latest, a
# line's latest to the next line, a fresh install straight to the target. Here
# the real collector runs against a fixture root and its facts are evaluated
# with nix-instantiate — the pair the mothership build uses (#797).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEP="${HERE}/ak-step.nix"
FACTS="${HERE}/build-facts.sh"
PASS=0; FAIL=0
ck()   { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
ckin() { if [[ "$3" == *"$2"* ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (missing '$2' in: $3)"; FAIL=$((FAIL+1)); fi; }
command -v nix-instantiate >/dev/null 2>&1 || { echo "nix-instantiate not available — skipped."; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/ak-step.XXXXXX")"; trap 'rm -rf "${T}"' EXIT

LINES='[ "2025.2.3" "2025.4.4" "2025.6.4" "2025.8.6" "2025.10.4" "2025.12.6" "2026.2.7" "2026.5.7" "2026.8.3" ]'
G="${T}/guest"   # the guest's filesystem, as the collector sees it
ev() {  # $1 = attribute; the guest's files under ${G}
    FACTS_ROOT="${G}" bash "${FACTS}" > "${T}/facts.env"
    nix-instantiate --eval --strict 2>&1 -E "(import ${STEP} {
        lines = ${LINES}; factsFile = \"${T}/facts.env\";
    }).$1" | tr -d '"'
}
reset() { rm -rf "${G}"; mkdir -p "${G}/var/lib/authentik" "${G}/etc/secrets"; }
# The old fixture names, now files on the fixture guest.

reset
ck "fresh install (no Authentik state at all): straight to the target" "2026.8.3" "$(ev step)"
ck "…the collector says so: none" "AUTHENTIK_INSTALLED=none" "$(head -1 "${T}/facts.env")"
ck "…which needs no Redis"                               "false"    "$(ev redis)"
ck "…and mounts /data"                                   "true"     "$(ev dataMount)"

reset; echo "AUTHENTIK_SECRET_KEY=x" > "${G}/etc/secrets/authentik.env"
ck "an install from before the version file runs 2025.2.1 → that line's last usable patch first" "2025.2.3" "$(ev step)"
ck "…still with Redis"   "true"  "$(ev redis)"
ck "…still on /media"    "false" "$(ev dataMount)"

reset; printf '2025.2.3\n' > "${G}/var/lib/authentik/tappaas-version"
ck "a line's step patch → the next line" "2025.4.4" "$(ev step)"
printf '2025.2.4\n' > "${G}/var/lib/authentik/tappaas-version"
ck "a newer patch than the line's step (2025.2.4 recorded) → the next line, not back" "2025.4.4" "$(ev step)"
printf '2025.8.6' > "${G}/var/lib/authentik/tappaas-version"
ck "2025.8 → 2025.10" "2025.10.4" "$(ev step)"
ck "2025.10 drops Redis" "false" "$(ev redis)"
printf '2025.10.4' > "${G}/var/lib/authentik/tappaas-version"
ck "2025.10 → 2025.12" "2025.12.6" "$(ev step)"
ck "2025.12 moves files to /data" "true" "$(ev dataMount)"
printf '2025.12.2' > "${G}/var/lib/authentik/tappaas-version"
ck "an older patch of 2025.12 → 2025.12's latest, not the next line" "2025.12.6" "$(ev step)"
printf '2026.8.3' > "${G}/var/lib/authentik/tappaas-version"
ck "on the target: stays" "2026.8.3" "$(ev step)"
ck "…and says so" "true" "$(ev onTarget)"
printf '2026.8.1' > "${G}/var/lib/authentik/tappaas-version"
ck "an older patch of the target line → the target" "2026.8.3" "$(ev step)"

printf '2026.11.1' > "${G}/var/lib/authentik/tappaas-version"
ckin "newer than the target: refused, never downgraded" "cannot go back" "$(ev step)"
printf '2024.12.3' > "${G}/var/lib/authentik/tappaas-version"
ckin "older than the first step: refused, not jumped" "older than the first step" "$(ev step)"
printf '2025.3.1' > "${G}/var/lib/authentik/tappaas-version"
ckin "a line the release does not know: refused" "does not know" "$(ev step)"

# The pre-check's blocker stops only a step into 2025.12 or later, before anything changes.
printf '2025.10.4' > "${G}/var/lib/authentik/tappaas-version"; echo "duplicate group names: admins" > "${G}/var/lib/authentik/tappaas-step-blocked"
ckin "a blocker stops the step into 2025.12, naming why" "duplicate group names: admins" "$(ev step)"
printf '2025.6.4' > "${G}/var/lib/authentik/tappaas-version"
ck "…but not a step that does not migrate groups" "2025.8.6" "$(ev step)"

# #797: what the mothership build saw — nothing — must never read as a fresh install.
reset; mkdir -p "${G}/var/lib/postgresql/16"; : > "${G}/var/lib/postgresql/16/PG_VERSION"
ckin "a database with no version record: refused, not jumped to the target" "no record of the Authentik version" "$(ev step)"
ck "…the collector says unknown" "AUTHENTIK_INSTALLED=unknown" "$(head -1 "${T}/facts.env")"
rm -f "${T}/facts.env"
ckin "no build facts at all: refused" "no build facts" "$(nix-instantiate --eval --strict 2>&1 -E "(import ${STEP} { lines = ${LINES}; factsFile = \"${T}/facts.env\"; }).step")"
printf 'SOMETHING_ELSE=1\n' > "${T}/facts.env"
ckin "facts that do not name the version: refused" "do not say what the guest runs" "$(nix-instantiate --eval --strict 2>&1 -E "(import ${STEP} { lines = ${LINES}; factsFile = \"${T}/facts.env\"; }).step")"
reset; printf '2025.10.4\n' > "${G}/var/lib/authentik/tappaas-version"; printf 'a = b; c\n' > "${G}/var/lib/authentik/tappaas-step-blocked"
ckin "a blocker with '=' in it survives the facts file" "a = b; c" "$(ev step)"

echo "── authentik step: ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
