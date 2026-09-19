#!/usr/bin/env bash
# tappaas-self-rebuild.sh — the mothership's nixos-rebuild, as root, before the sweep (ADR-017 D3).
#
# Third ExecStartPre line of update-tappaas.service, prefixed `+`: it runs as
# root outside the unit's sandbox, the one step that needs privilege — no sudo,
# no polkit, no helper unit. It runs the same command as the interim
# tappaas-rebuild@ helper, then re-renders the update timer (D2) from the new
# generation and leaves $RUNTIME_DIRECTORY/rebuilt, which tells the
# tappaas-cicd module's update.sh that its rebuild is already done.
#
# HOME=/var/lib/tappaas-rebuild holds root's safe.directory grant for the
# operator's checkout (nix's libgit2 reads it from $HOME/.gitconfig only).

set -euo pipefail
# Root must not resolve its tools from the unit's PATH, which starts with
# tappaas-writable directories (~/bin, ~/.nix-profile).
export PATH=/run/wrappers/bin:/run/current-system/sw/bin

# The sweep's log levels, inlined rather than sourced: common-install-routines.sh
# sources from ~tappaas/bin, which root must never read code from.
info()  { echo -e "\033[32m[Info]\033[m $*"; }
debug() { [[ "${TAPPAAS_DEBUG:-0}" == "1" ]] || return 0; echo -e "\033[36m[Debug]\033[m $*"; }
warn()  { echo -e "\033[33m[Warning]\033[m $*"; }
error() { echo -e "\033[01;31m[Error]\033[m $*" >&2; }

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CICD_DIR="$(dirname "${_here}")"
RUN_DIR="${RUNTIME_DIRECTORY:-/run/update-tappaas}"
# Root's own directory, not the tappaas-owned run dir: the full build output.
REBUILD_LOG=/var/lib/tappaas-rebuild/nixos-rebuild.log
VMNAME="$(jq -r '(.config // .).vmname // "tappaas-cicd"' /home/tappaas/config/tappaas-cicd.json 2>/dev/null || echo tappaas-cicd)"
[[ "${VMNAME}" =~ ^[A-Za-z0-9-]+$ ]] || { error "tappaas-self-rebuild: bad vmname '${VMNAME}'"; exit 1; }

cd "${CICD_DIR}"
info "Rebuilding NixOS (${VMNAME}) — one dot per build line"
debug "nixos-rebuild switch --flake .#${VMNAME} --impure (full output: ${REBUILD_LOG})"
# --impure only for the machine's /etc/nixos/hardware-configuration.nix;
# nixpkgs stays pinned by flake.lock. A dot never swallows an error: on failure
# the tail of the log is shown and the unit stops (set -e).
set +e
HOME=/var/lib/tappaas-rebuild nixos-rebuild switch --flake ".#${VMNAME}" --impure 2>&1 \
    | tee "${REBUILD_LOG}" \
    | { dots=0; while IFS= read -r _; do printf '.'; dots=1; done; (( dots )) && printf '\n'; true; }
rc="${PIPESTATUS[0]}"
set -e
if (( rc != 0 )); then
    error "nixos-rebuild failed (rc ${rc}) — last lines of ${REBUILD_LOG}:"
    tail -15 "${REBUILD_LOG}" >&2 || true
    exit "${rc}"
fi

systemctl start update-tappaas-schedule.service \
    || warn "tappaas-self-rebuild: could not re-render the update timer"
# The run directory belongs to tappaas: never follow a link planted there.
rm -f "${RUN_DIR}/rebuilt"
( set -C; : > "${RUN_DIR}/rebuilt" )
info "✓ NixOS rebuilt: generation $(readlink /nix/var/nix/profiles/system) active"
