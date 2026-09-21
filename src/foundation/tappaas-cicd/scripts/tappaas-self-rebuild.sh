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

# The site's own time and locale, written before the build that reads it
# (#408, #472): tappaas-cicd.nix imports /etc/nixos/tappaas-site.nix when it
# exists. Sourced from the CHECKOUT, not ~tappaas/bin — root already builds this
# system from that tree, so it is no new trust, while ~tappaas/bin is a path root
# must not read code from.
_sl="${CICD_DIR}/lib/site-locale.sh"
if [[ -f "${_sl}" ]]; then
    # shellcheck source=../lib/site-locale.sh
    if . "${_sl}" 2>/dev/null && declare -F render_site_nix >/dev/null 2>&1; then
        _mgmt_zone="$(jq -r '(.zone0 // "mgmt")' /home/tappaas/config/tappaas-cicd.json 2>/dev/null || echo mgmt)"
        if render_site_nix "${_mgmt_zone}" > /etc/nixos/tappaas-site.nix.new 2>/dev/null; then
            mv -f /etc/nixos/tappaas-site.nix.new /etc/nixos/tappaas-site.nix
            debug "wrote /etc/nixos/tappaas-site.nix from site.json"
        else
            rm -f /etc/nixos/tappaas-site.nix.new
            warn "could not render the site's time/locale — the mothership keeps what it has"
        fi
    fi
fi

# ── what this rebuild pins, and whether that moves the system BACK (#680) ──
#
# Since ADR-017 D3 this script builds from the checkout's flake, so
# src/foundation/tappaas-cicd/flake.lock decides the nixpkgs revision for every
# site on the sanctioned path — an authority it acquired by accident, when it
# was one VM's business. A host that used to build from its own, newer flake
# moves BACKWARDS on its first rebuild here: packages downgrade immediately and
# the kernel at the next boot, with the rebuild reporting plain success.
#
# So say it. The switch still happens — every site is behind this lock today and
# refusing would stop the update path itself — but a downgrade is never silent
# again, and the pin's age is on the record at every rebuild.
_lock="${CICD_DIR}/flake.lock"
if [[ -r "${_lock}" ]]; then
    _lock_rev="$(jq -r '.nodes.nixpkgs.locked.rev // empty' "${_lock}" 2>/dev/null)"
    _lock_epoch="$(jq -r '.nodes.nixpkgs.locked.lastModified // empty' "${_lock}" 2>/dev/null)"
    _run_ver="$(nixos-version 2>/dev/null)"            # e.g. 25.11.20260522.b77b3de
    _run_rev="$(nixos-version --json 2>/dev/null | jq -r '.nixpkgsRevision // empty' 2>/dev/null)"
    _run_date="$(sed -n 's/^[0-9]*\.[0-9]*\.\([0-9]\{8\}\)\..*/\1/p' <<<"${_run_ver}")"
    if [[ -n "${_lock_epoch}" ]]; then
        # GNU date on the mothership, BSD date where a developer runs the test.
        _lock_date="$(date -u -d "@${_lock_epoch}" +%Y%m%d 2>/dev/null \
                      || date -u -r "${_lock_epoch}" +%Y%m%d 2>/dev/null || true)"
        _age_days=$(( ( $(date -u +%s) - _lock_epoch ) / 86400 ))
        info "nixpkgs pin: ${_lock_rev:0:12} (${_lock_date:-?}, ${_age_days}d old) — from ${_lock}"
        if [[ -n "${_run_date}" && -n "${_lock_date}" && -n "${_run_rev}" \
              && "${_run_rev}" != "${_lock_rev}" && "${_lock_date}" < "${_run_date}" ]]; then
            warn "This rebuild moves nixpkgs BACKWARDS (#680):"
            warn "  running now : ${_run_rev:0:12} (${_run_date})"
            warn "  this flake  : ${_lock_rev:0:12} (${_lock_date})"
            warn "  Packages downgrade on switch and the kernel at the next boot — security-relevant"
            warn "  ones included. Update the baseline lock, or pin this host deliberately."
        fi
    fi
fi

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
