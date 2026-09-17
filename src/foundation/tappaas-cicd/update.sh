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
# ADR-017 D3 moved the rebuild into update-tappaas.service's ExecStartPre
# (tappaas-self-rebuild.sh), which leaves /run/update-tappaas/rebuilt: then
# there is nothing to do here. The helper-unit path below remains for the first
# activation (ADR-017 Bootstrap: the old unit runs this update before its own
# replacement exists) and for a `module modify tappaas-cicd` outside the unit.
#
# The NixOS version is pinned in ./flake.lock (declared in git), not the
# imperative root nix-channel; --impure is required only because
# tappaas-cicd.nix imports the machine-specific
# /etc/nixos/hardware-configuration.nix (root/boot by-uuid). Both now live on
# the unit's ExecStart.
if [[ -f /run/update-tappaas/rebuilt ]]; then
    info "  NixOS already rebuilt by update-tappaas.service — skipping"
    info "  ${GN}✓${CL} VM update completed successfully"
    exit 0
fi
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

# The first activation of ADR-017 D2 happens in the rebuild above: start the
# timer renderer so the new schedule is live before the next run.
systemctl start update-tappaas-schedule.service 2>/dev/null \
    || warn "  could not start update-tappaas-schedule.service (it runs at next boot)"

# The OPNsense plugin retrofit (#254) is `opnsense-ensure-patches`, run by
# pre-update.sh. The manager/controller builds are refresh-control-plane.sh's,
# run before this by the unit's prepare step (ADR-017 D3) or by pre-update.sh —
# the second refresh that used to follow the rebuild here is gone.

info "  ${GN}✓${CL} VM update completed successfully"
