#!/usr/bin/env bash
# TAPPaaS CICD Module Update
#

set -euo pipefail

. /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/lib/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "$1")"

# Rebuild the NixOS configuration through the privileged helper unit
# tappaas-rebuild@<vm>.service (declared in tappaas-cicd.nix).
#
# Calling `sudo nixos-rebuild` directly CANNOT work when update-tappaas runs
# from its systemd timer: update-tappaas.service sets NoNewPrivileges=true, and
# that kernel latch is inherited by every descendant and cannot be cleared, so
# setuid binaries stop conferring privilege and sudo refuses outright. This
# failed every scheduled run (2026-08-04, 08-11, 08-17, 08-18) while every
# manual run passed, because a login shell carries no such latch — so the
# repair reflex (`update-tappaas --force`) was exactly the path that could not
# reproduce the fault. `systemctl start` is authorised by polkit on the
# caller's uid instead, which the latch does not affect, so this single path
# behaves identically from the timer and from a shell.
#
# Interim fix for #471; ADR-017 hoists the rebuild into an `ExecStartPre=+`
# line on update-tappaas.service and retires this indirection entirely.
#
# The NixOS version is pinned in ./flake.lock (declared in git), not the
# imperative root nix-channel; --impure is required only because
# tappaas-cicd.nix imports the machine-specific
# /etc/nixos/hardware-configuration.nix (root/boot by-uuid). Both now live on
# the unit's ExecStart.
_unit="tappaas-rebuild@${VMNAME}.service"
# Bound the failure dump to THIS invocation so an earlier run's errors can
# never be reported as this one's.
_since="$(date '+%Y-%m-%d %H:%M:%S')"
info "  Rebuilding NixOS configuration..."
if [[ "${OPT_DEBUG:-0}" -eq 1 ]]; then
    journalctl -u "${_unit}" --since "${_since}" -f --no-pager -o cat &
    _follow=$!
    set +e
    systemctl start --wait "${_unit}"
    rc=$?
    set -e
    kill "${_follow}" 2>/dev/null || true
    [[ "${rc}" -eq 0 ]] || die "nixos-rebuild failed (exit ${rc}); see journalctl -u ${_unit}"
else
    # Dots while the unit runs. `systemctl start --wait` exits with the unit's
    # own result, so the real status is preserved directly — issue #201's
    # PIPESTATUS problem cannot arise here because there is no pipe.
    set +e
    systemctl start --wait "${_unit}" &
    _pid=$!
    while kill -0 "${_pid}" 2>/dev/null; do printf "."; sleep 2; done
    wait "${_pid}"
    rc=$?
    set -e
    echo ""
    if [[ "${rc}" -ne 0 ]]; then
        # Same diagnostic contract as 3c6379a — name the cause, never report a
        # bare exit code. The output is in the journal now rather than a temp
        # file, which PrivateTmp=true destroyed with the namespace anyway (the
        # 2026-08-18 failure pointed at a log that no longer existed). This
        # module updates the controller VM itself, which #352 excludes from
        # pre-update snapshots, so a failure here is unrecoverable without the
        # error text.
        error "nixos-rebuild failed (exit ${rc}) — last 20 lines:"
        journalctl -u "${_unit}" --since "${_since}" -n 20 --no-pager -o cat \
            | sed 's/^/    /' >&2
        die "nixos-rebuild failed (exit ${rc}); full output: journalctl -u ${_unit}"
    fi
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
# failure does NOT abort the loop (every component still gets its chance to
# rebuild), but it MUST NOT be masked: if any dispatcher fails, this update did
# not fully succeed and the final status has to say so (#519 — a build break
# left 7 managers on stale binaries while the run reported success).
_cicd_dir="/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd"
_failed_disp=()
for _disp in manager controller; do
    if [[ -x "${_cicd_dir}/${_disp}/update.sh" ]]; then
        "${_cicd_dir}/${_disp}/update.sh" \
            || { _failed_disp+=("${_disp}"); warn "  ${_disp}/update.sh reported non-zero rc — some components kept their previous binaries"; }
    fi
done

if [[ ${#_failed_disp[@]} -gt 0 ]]; then
    die "VM rebuilt, but component group(s) failed to refresh: ${_failed_disp[*]} — shared managers may be stale (see warnings above). NOT reporting success."
fi

info "  ${GN}✓${CL} VM update completed successfully"
