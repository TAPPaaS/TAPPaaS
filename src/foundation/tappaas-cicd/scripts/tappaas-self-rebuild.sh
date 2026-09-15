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

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CICD_DIR="$(dirname "${_here}")"
RUN_DIR="${RUNTIME_DIRECTORY:-/run/update-tappaas}"
VMNAME="$(jq -r '(.config // .).vmname // "tappaas-cicd"' /home/tappaas/config/tappaas-cicd.json 2>/dev/null || echo tappaas-cicd)"
[[ "${VMNAME}" =~ ^[A-Za-z0-9-]+$ ]] || { echo "tappaas-self-rebuild: bad vmname '${VMNAME}'" >&2; exit 1; }

cd "${CICD_DIR}"
echo "tappaas-self-rebuild: nixos-rebuild switch --flake .#${VMNAME} --impure"
# --impure only for the machine's /etc/nixos/hardware-configuration.nix;
# nixpkgs stays pinned by flake.lock.
HOME=/var/lib/tappaas-rebuild nixos-rebuild switch --flake ".#${VMNAME}" --impure

systemctl start update-tappaas-schedule.service \
    || echo "tappaas-self-rebuild: WARNING: could not re-render the update timer" >&2
: > "${RUN_DIR}/rebuilt"
echo "tappaas-self-rebuild: generation $(readlink /nix/var/nix/profiles/system) active"
