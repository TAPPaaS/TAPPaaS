#!/usr/bin/env bash
#
# build-facts.sh — what this Authentik guest runs, for the build that picks its
# next step (#797). Runs ON the guest as root; update-os.sh feeds it over ssh
# (`sudo bash -s`) and writes the output to /etc/nixos/tappaas-build-facts.env,
# which ak-step.nix reads. The build happens on the mothership (#774), where the
# guest's own files do not exist — so it gets these facts, never the files.
#
# Prints KEY=value lines, never a secret:
#   AUTHENTIK_INSTALLED     the version (recorded by authentik-version-record),
#                           2025.2.1 for an install from before that record,
#                           none    — no Authentik state at all: a fresh install,
#                           unknown — a database but no record of its version.
#   AUTHENTIK_STEP_BLOCKED  the pre-check's finding, one line; empty = nothing blocks.
#
# FACTS_ROOT prefixes every path (tests).
set -uo pipefail
R="${FACTS_ROOT:-}"

v=""
[[ -r "${R}/var/lib/authentik/tappaas-version" ]] \
    && v="$(head -n1 "${R}/var/lib/authentik/tappaas-version" | tr -d '[:space:]')"
if [[ -n "${v}" ]]; then
    installed="${v}"
elif [[ -e "${R}/etc/secrets/authentik.env" ]]; then
    installed="2025.2.1"              # the one version pinned before the record existed
elif [[ -n "$(ls -A "${R}/var/lib/postgresql" 2>/dev/null)" ]]; then
    installed="unknown"               # Authentik's database is here; what runs on it is not known
else
    installed="none"
fi
blocked=""
[[ -r "${R}/var/lib/authentik/tappaas-step-blocked" ]] \
    && blocked="$(head -n1 "${R}/var/lib/authentik/tappaas-step-blocked" | tr -d '\r')"

echo "AUTHENTIK_INSTALLED=${installed}"
echo "AUTHENTIK_STEP_BLOCKED=${blocked}"
