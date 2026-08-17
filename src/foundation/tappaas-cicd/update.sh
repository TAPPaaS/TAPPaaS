#!/usr/bin/env bash
# TAPPaaS CICD Module Update
#

set -euo pipefail

. /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/lib/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "$1")"

# Rebuild the NixOS configuration. The NixOS version is pinned in ./flake.lock
# (declared in git), not the imperative root nix-channel. --impure is required
# only because tappaas-cicd.nix imports the machine-specific
# /etc/nixos/hardware-configuration.nix (root/boot by-uuid).
info "  Rebuilding NixOS configuration..."
if [[ "${OPT_DEBUG:-0}" -eq 1 ]]; then
    sudo nixos-rebuild switch --flake ".#${VMNAME}" --impure || die "nixos-rebuild failed"
else
    # Pipe to dots but preserve nixos-rebuild's real exit code via PIPESTATUS —
    # a bare `cmd | while read` reports the while-loop's status, masking a
    # failed rebuild (issue #201). set +e keeps the pipe from aborting first.
    #
    # Tee to a log as well: the dots alone discarded stderr entirely, so a failed
    # rebuild surfaced only as "exit 1" with no cause. That hid this step twice
    # (2026-08-04 and 2026-08-17) — and this module updates the controller VM
    # itself, which #352 excludes from pre-update snapshots, so a failure here is
    # already unrecoverable without the error text. Same fix as update-os.sh's
    # run_quiet (issue #309 ask 1).
    _log="$(mktemp /tmp/tappaas-rebuild-"${VMNAME}".XXXXXX.log)"
    set +e
    sudo nixos-rebuild switch --flake ".#${VMNAME}" --impure 2>&1 \
        | tee "${_log}" | while IFS= read -r _; do printf "."; done
    rc=${PIPESTATUS[0]}
    set -e
    echo ""
    if [[ "${rc}" -ne 0 ]]; then
        error "nixos-rebuild failed (exit ${rc}) — last 20 lines:"
        tail -n 20 "${_log}" | sed 's/^/    /' >&2
        die "nixos-rebuild failed (exit ${rc}); full output in ${_log}"
    fi
    rm -f "${_log}"
fi

# update-tappaas is scheduled declaratively via systemd.timers.update-tappaas
# in tappaas-cicd.nix (output → journald → Promtail → Loki). The legacy hourly
# crontab entry was retired — re-adding it here caused a dual scheduler where
# both the cron and the timer fired hourly (issue: weekly timer run failed with
# "env: 'bash'" while the cron run masked it). Do NOT call update-cron.sh.

# The OPNsense plugin retrofit (#254: os-acme-client/os-ddclient) moved into
# `opnsense-ensure-patches` (controller/opnsense-controller/), which
# pre-update.sh runs earlier in this same update cycle — the firewall's local
# patch/plugin state is the opnsense controller's job, not the VM update's
# (ADR-007 post-implementation refactor, Phase 5 / D5).

# ADR-007 S0 (P4 3d, option A — additive): besides the cicd VM's own rebuild
# above, refresh the manager/ + controller/ components by running each parent
# dispatcher's update verb (idempotent rebuild + bin relink — every component,
# compiled ones included, now ships its own install/update.sh). A component
# failure warns, it does not abort the cicd update.
_cicd_dir="/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd"
for _disp in manager controller; do
    if [[ -x "${_cicd_dir}/${_disp}/update.sh" ]]; then
        "${_cicd_dir}/${_disp}/update.sh" || warn "  ${_disp}/update.sh reported non-zero rc"
    fi
done

info "  ${GN}✓${CL} VM update completed successfully"
