#!/usr/bin/env bash
#
# build-facts.sh — what this Authentik guest runs, for the build that picks its
# next step (#797). Runs ON the guest as root; update-os.sh feeds it over ssh
# (`sudo bash -s`) and writes the output to /etc/nixos/tappaas-build-facts.env,
# which ak-step.nix reads. The build happens on the mothership (#774), where the
# guest's own files do not exist — so it gets these facts, never the files.
#
# Prints KEY=value lines, never a secret:
#   AUTHENTIK_INSTALLED     the version authentik-version-record wrote after the
#                           last successful start; without it, the version of the
#                           server container this guest has (running or not);
#                           none    — no record, no container, no database: a fresh install,
#                           unknown — a database but neither a record nor a container.
#   AUTHENTIK_RUNNING       the server container's version, or none — the floor
#                           ak-step.nix will not go below, whatever the record says.
#   AUTHENTIK_STEP_BLOCKED  the pre-check's finding, one line; empty = nothing blocks.
#
# The env file (/etc/secrets/authentik.env) says nothing about the version: every
# guest has one. Taking it for "2025.2.1" stepped a 2026.8.3 guest whose record
# was missing DOWN to 2025.2.3 (hrossen, 2026-10-08) — the container is asked instead.
#
# FACTS_ROOT prefixes every path, FACTS_IMAGE stands in for the container's image
# ("" = no container) — both for tests.
set -uo pipefail
R="${FACTS_ROOT:-}"

image() {
    if [[ -n "${FACTS_IMAGE+x}" ]]; then printf '%s' "${FACTS_IMAGE}"; return; fi
    command -v podman >/dev/null 2>&1 || return 0
    podman inspect authentik-server --format '{{.ImageName}}' 2>/dev/null || true
}
running="$(image | sed -nE 's#^.*/server:([0-9]{4}\.[0-9]+\.[0-9]+)$#\1#p')"

v=""
[[ -r "${R}/var/lib/authentik/tappaas-version" ]] \
    && v="$(head -n1 "${R}/var/lib/authentik/tappaas-version" | tr -d '[:space:]')"
if [[ -n "${v}" ]]; then
    installed="${v}"
elif [[ -n "${running}" ]]; then
    installed="${running}"            # no record: the container this guest has
elif [[ -n "$(ls -A "${R}/var/lib/postgresql" 2>/dev/null)" ]]; then
    installed="unknown"               # Authentik's database is here; what runs on it is not known
else
    installed="none"
fi
blocked=""
[[ -r "${R}/var/lib/authentik/tappaas-step-blocked" ]] \
    && blocked="$(head -n1 "${R}/var/lib/authentik/tappaas-step-blocked" | tr -d '\r')"

echo "AUTHENTIK_INSTALLED=${installed}"
echo "AUTHENTIK_RUNNING=${running:-none}"
echo "AUTHENTIK_STEP_BLOCKED=${blocked}"
