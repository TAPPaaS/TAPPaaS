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
    set +e
    sudo nixos-rebuild switch --flake ".#${VMNAME}" --impure 2>&1 | while IFS= read -r _; do printf "."; done
    rc=${PIPESTATUS[0]}
    set -e
    echo ""
    [[ "${rc}" -eq 0 ]] || die "nixos-rebuild failed (exit ${rc})"
fi

# update-tappaas is scheduled declaratively via systemd.timers.update-tappaas
# in tappaas-cicd.nix (output → journald → Promtail → Loki). The legacy hourly
# crontab entry was retired — re-adding it here caused a dual scheduler where
# both the cron and the timer fired hourly (issue: weekly timer run failed with
# "env: 'bash'" while the cron run masked it). Do NOT call update-cron.sh.

# Retrofit OPNsense plugins on existing systems (issue #254). New installs get
# these via setup-caddy.sh; this idempotent ensure brings already-deployed
# systems up to date on the next update cycle so acme-setup.sh works without
# the operator needing to re-run setup-caddy.sh by hand.
FIREWALL_FQDN="firewall.mgmt.internal"
if ssh -o ConnectTimeout=5 -o BatchMode=yes root@"$FIREWALL_FQDN" echo ok >/dev/null 2>&1; then
    for pkg in os-acme-client os-ddclient; do
        if ! ssh root@"$FIREWALL_FQDN" "/bin/sh -c 'pkg info $pkg'" &>/dev/null; then
            info "  Installing missing OPNsense plugin: $pkg"
            ssh root@"$FIREWALL_FQDN" "/bin/sh -c 'pkg install -y $pkg'" 2>&1 \
                | while IFS= read -r _; do printf "."; done || \
                warn "  $pkg install returned non-zero"
            echo ""
        fi
    done
else
    debug "  firewall unreachable — skipping plugin ensure (will retry next update)"
fi

info "  ${GN}✓${CL} VM update completed successfully"
