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

# ── The way back, captured BEFORE the switch (#713, ADR-028 D10) ─────
#
# Every other machine in the estate has a net: update-module.sh snapshots a
# guest, rebuilds it, runs its tests and rolls the guest back when they fail.
# The mothership had none — and it rebuilds FIRST, so it is the machine most
# exposed to a new nixpkgs revision. A `switch` that returns 0 into a control
# plane that cannot resolve a config was simply not noticed.
#
# NixOS makes the net nearly free: the previous generation is already on disk,
# and its own switch-to-configuration can put it back. Capture it by its real
# path, not by "--rollback", so this rolls back to the generation WE replaced
# even if something else has touched the profile since.
SELFCHECK="${_here}/tappaas-selfcheck.sh"
GEN_BEFORE="$(readlink -f /nix/var/nix/profiles/system 2>/dev/null || true)"
UNITS_BEFORE="$(mktemp /var/lib/tappaas-rebuild/failed-units.XXXXXX 2>/dev/null \
                || mktemp /tmp/tappaas-failed-units.XXXXXX)"
if [[ -x "${SELFCHECK}" ]]; then
    "${SELFCHECK}" --record "${UNITS_BEFORE}" || : > "${UNITS_BEFORE}"
else
    warn "no tappaas-selfcheck.sh beside this script — the rebuild will not be verified"
fi

# Put the machine back on the generation we replaced.
#
# Two things must move, and only doing the first is a trap (#713, proven on
# hrossen 2026-09-23): `switch-to-configuration switch` activates a
# configuration and updates the bootloader, but it does NOT move
# /nix/var/nix/profiles/system. Leave the profile naming the bad build and the
# NEXT rebuild captures that as its way back — one bad night poisons the one
# after it. `nix-env --set` is what moves the pointer, and it is why
# `nixos-rebuild --rollback` does both.
roll_back_to() {
    local gen="$1" why="$2"
    if [[ -z "${gen}" || ! -x "${gen}/bin/switch-to-configuration" ]]; then
        error "No previous generation to roll back to (${gen:-none recorded})."
        return 1
    fi
    error "${why} — rolling back to ${gen##*/}."
    # A rollback that cannot finish is worse than no rollback: it holds
    # /run/nixos/switch-to-configuration.lock and the operator gets a hang
    # instead of a verdict. Measured on hrossen 2026-09-23 rolling 26.05 back
    # to 25.11: the OLD generation's switch-to-configuration spun at 100% CPU
    # and never returned. So it gets a deadline, and a hard kill after it.
    local rb_rc=0
    timeout -k 30 "${ROLLBACK_TIMEOUT:-300}" \
        "${gen}/bin/switch-to-configuration" switch >>"${REBUILD_LOG}" 2>&1 || rb_rc=$?
    if (( rb_rc == 124 || rb_rc == 137 )); then
        error "ROLLBACK TIMED OUT after ${ROLLBACK_TIMEOUT:-300}s and was killed."
        error "This mothership runs an unverified generation and the rollback did"
        error "not finish — a switch ACROSS a nixpkgs release can live-lock."
        error "Recover by hand: boot the previous generation from the boot menu."
        return 1
    fi
    if (( rb_rc != 0 )); then
        error "ROLLBACK FAILED — this mothership is running an unverified generation."
        error "Recover by hand: boot the previous generation from the boot menu, or"
        error "  ${gen}/bin/switch-to-configuration switch"
        return 1
    fi
    # The pointer, not just the running system.
    if ! nix-env --profile /nix/var/nix/profiles/system --set "${gen}" >>"${REBUILD_LOG}" 2>&1; then
        warn "Rolled back, but the system profile still names the bad generation."
        warn "  Fix before the next sweep: nix-env --profile /nix/var/nix/profiles/system --set ${gen}"
    fi
    error "Rolled back. The sweep is ABORTED: the estate is not updated from a"
    error "control plane that just failed. The kernel follows at the next boot."
    return 0
}

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
    # A failed switch is NOT an unchanged machine. `switch-to-configuration`
    # activates first and reports failure after, so a unit that fails to start
    # leaves the new generation live and the profile pointing at it (observed on
    # hrossen 2026-09-23: rc 4, and the machine had moved). The clean failure
    # deserves the same way back as the subtle one.
    if [[ "$(readlink -f /nix/var/nix/profiles/system 2>/dev/null)" != "${GEN_BEFORE}" ]]; then
        # The machine moved. Before undoing that, ASK — the self-check is the
        # instrument for "did the new control plane come up?", and rolling back
        # is the more dangerous of the two operations. rc 4 means some unit
        # failed, NOT that the switch did not happen: on a release move
        # (25.11 -> 26.05) dbus-broker cannot be reloaded in place, the switch
        # applies correctly, and rc 4 is reported over it — observed on hrossen
        # 2026-09-23, where undoing a generation that passed its own check was
        # the wrong call, and the rollback then live-locked attempting it.
        if [[ -x "${SELFCHECK}" ]] && "${SELFCHECK}" --baseline "${UNITS_BEFORE}"; then
            warn "The rebuild reported rc ${rc}, but the new control plane passes its own check."
            warn "  NOT rolling back: the generation is live and verified."
            warn "  The sweep still stops — a unit failed and a person should read why:"
            warn "    ${REBUILD_LOG}"
        else
            roll_back_to "${GEN_BEFORE}" "The rebuild failed after it had already switched" || true
        fi
    else
        info "The machine did not switch — it is still on ${GEN_BEFORE##*/}."
    fi
    rm -f "${UNITS_BEFORE}"
    exit "${rc}"
fi

# ── Verify the generation we just switched to, and undo it if it is bad ──
#
# The check is deliberately small and local (managers run, the catalogue
# resolves, nothing newly failed): it must be cheap enough for every rebuild and
# must not depend on the network, which would turn an outage into a rollback.
if [[ -x "${SELFCHECK}" ]]; then
    info "Verifying the new generation"
    if ! "${SELFCHECK}" --baseline "${UNITS_BEFORE}"; then
        roll_back_to "${GEN_BEFORE}" "The rebuilt control plane failed its own check" || true
        rm -f "${UNITS_BEFORE}"
        exit 1
    fi
fi
rm -f "${UNITS_BEFORE}"

systemctl start update-tappaas-schedule.service \
    || warn "tappaas-self-rebuild: could not re-render the update timer"
# The marker tells the tappaas-cicd module's update.sh, later in the SAME sweep,
# that the rebuild is already done. Run by hand there is no sweep to tell and
# $RUNTIME_DIRECTORY does not exist — so skip it rather than creating the
# directory: a marker left lying outside a sweep would make the next one skip a
# rebuild it has not performed. Without this the script died here under `set -e`,
# after a successful rebuild, on a redirect into a directory that was never
# supposed to exist yet.
if [[ -d "${RUN_DIR}" ]]; then
    # The run directory belongs to tappaas: never follow a link planted there.
    rm -f "${RUN_DIR}/rebuilt"
    ( set -C; : > "${RUN_DIR}/rebuilt" )
else
    info "  (not part of a sweep — leaving no rebuilt marker)"
fi
info "✓ NixOS rebuilt: generation $(readlink /nix/var/nix/profiles/system) active"
