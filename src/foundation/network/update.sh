#!/usr/bin/env bash
# TAPPaaS Firewall Module Update
#
# Updates the OPNsense firewall software via SSH and applies zone configuration.
#
# Order of operations:
# 1. OPNsense software update (base, kernel, packages)
# 2. Unconditional reboot to apply updates and regenerate configs
# 3. Wait for firewall to come back online
# 4. Verify DNS is working (Unbound health check)
# 5. Apply zone configuration via zone-manager
# 6. Remaining configuration (proxy, net0 trunks, etc.)
#
# This order ensures OPNsense updates are applied BEFORE zone-manager runs,
# which triggers Unbound config regeneration. See ISSUES.md for background.
#
# When firewallType is "NONE" (no OPNsense deployed), this script skips all
# OPNsense-specific operations and prints a reminder.
#
# Note: Connectivity checks (ping, SSH) are handled by update-module.sh
# via the pre-update test-module.sh call before this script runs.
#
# Note: OPNsense presents a menu when logging in interactively (option 8 = shell).
# When SSH is used with a command argument, it bypasses the menu and runs directly.

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

readonly CONFIG_DIR="/home/tappaas/config"
# ADR-007 P8: the module is renamed firewall → network. A fresh install deploys
# config/network.json; a not-yet-migrated live system still has config/firewall.json.
# Resolve whichever exists (network first, legacy firewall fallback) so the update
# works on both without any live change. NOTE: FIREWALL_FQDN below is the OPNsense
# HOST (firewall.mgmt.internal) — that is the cicd's lifeline and is intentionally
# NOT renamed here (the host rename is the deferred supervised migration, step 3).
if [[ -f "${CONFIG_DIR}/network.json" ]]; then
    readonly FIREWALL_JSON="${CONFIG_DIR}/network.json"
    readonly NETWORK_MODULE_NAME="network"
else
    readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"
    readonly NETWORK_MODULE_NAME="firewall"
fi
FIREWALL_FQDN="firewall.mgmt.internal"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# ── Check firewallType ───────────────────────────────────────────────

FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi

if [[ "${FIREWALL_TYPE}" == "NONE" ]]; then
    warn "firewallType=NONE — OPNsense is not managed by TAPPaaS."
    warn "Skipping firewall update. Manage your firewall manually."
    exit 0
fi

# ── OPNsense update ─────────────────────────────────────────────────
#
# Run OPNsense update FIRST, before zone-manager. This ensures any
# package updates (including potential dnspython/unbound fixes) are
# applied before we trigger config regeneration via zone-manager.

info "Updating OPNsense (base, kernel, and packages)..."
if [[ "${OPT_DEBUG:-0}" -eq 1 ]]; then
    ssh root@"$FIREWALL_FQDN" "opnsense-update -bkp" || {
        warn "OPNsense update returned non-zero exit code"
    }
else
    ssh root@"$FIREWALL_FQDN" "opnsense-update -bkp" 2>&1 | while IFS= read -r _; do
        printf "."
    done || {
        echo ""
        warn "OPNsense update returned non-zero exit code"
    }
    echo ""
fi

# ── Reboot firewall ─────────────────────────────────────────────────
#
# Reboot after OPNsense update during the install/update phase. This ensures:
# - Any kernel updates are applied
# - Unbound config is regenerated with current OPNsense state
# - We catch any Unbound/DNSBL issues BEFORE zone-manager runs
# - It serves as a clean slate for zone configuration.
#
# Gated by tappaas.automaticReboot (issue #275): when false the operator
# performs the disruptive firewall reboot manually under supervision, so we
# only warn that it is pending and skip the reboot/wait.

if automatic_reboot_enabled; then
    info "Rebooting firewall to apply updates..."
    ssh root@"$FIREWALL_FQDN" "shutdown -r now" 2>/dev/null || true

    # Wait for SSH to go down (firewall is rebooting)
    info "Waiting for firewall to reboot..."
    sleep 10

    # Wait for SSH to come back (max 5 minutes)
    WAIT_MAX=300
    WAIT_COUNT=0
    while ! ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            root@"$FIREWALL_FQDN" "echo ok" >/dev/null 2>&1; do
        sleep 5
        WAIT_COUNT=$((WAIT_COUNT + 5))
        if [[ $WAIT_COUNT -ge $WAIT_MAX ]]; then
            error "Firewall did not come back after reboot within ${WAIT_MAX}s"
            exit 1
        fi
        printf "."
    done
    echo ""
    info "${GN}✓${CL} Firewall is back online"
else
    warn "${BOLD}automaticReboot=false${CL} — skipping firewall reboot."
    warn "  A reboot is needed to apply OPNsense updates and regenerate Unbound config."
    warn "  Reboot manually under supervision: ssh root@${FIREWALL_FQDN} 'shutdown -r now'"
fi

# ── Verify Unbound DNS is working ────────────────────────────────────
#
# After reboot, OPNsense regenerates Unbound config. If there's a
# Python/dnspython version mismatch (see ISSUES.md), Unbound may fail
# to start. We check DNS here to catch the problem early.

info "Verifying Unbound DNS is responding..."
DNS_CHECK_RETRIES=6
DNS_CHECK_COUNT=0
while ! dig @10.0.0.1 firewall.mgmt.internal +short +timeout=5 >/dev/null 2>&1; do
    DNS_CHECK_COUNT=$((DNS_CHECK_COUNT + 1))
    if [[ $DNS_CHECK_COUNT -ge $DNS_CHECK_RETRIES ]]; then
        warn "Unbound DNS not responding on 10.0.0.1 after ${DNS_CHECK_RETRIES} attempts"
        warn "This may indicate a Python/dnspython version mismatch in OPNsense."
        warn "See src/foundation/network/ISSUES.md for recovery steps."
        warn "Attempting to continue, but zone-manager may fail..."
        break
    fi
    sleep 5
    printf "."
done
if [[ $DNS_CHECK_COUNT -lt $DNS_CHECK_RETRIES ]]; then
    echo ""
    info "${GN}✓${CL} Unbound DNS is responding"
fi

# ── Apply zone configuration ────────────────────────────────────────

info "Applying zone configuration..."
/home/tappaas/bin/zone-manager --no-ssl-verify --zones-file /home/tappaas/config/zones.json --execute

# When zone-manager creates new opt interfaces (e.g. activating testAllowA/testAllowB),
# OPNsense's auto-generated anti-lockout and bootp pass rules for those
# interfaces are NOT regenerated by /api/firewall/filter/apply. Without those
# rules, DHCP DISCOVER from a fresh VM is silently dropped on the new VLAN.
# `configctl filter reload` re-renders the full ruleset, including auto rules.
info "Reloading OPNsense filter to regenerate auto-rules for any new interfaces..."
ssh root@"$FIREWALL_FQDN" "configctl filter reload" >/dev/null 2>&1 \
    || warn "configctl filter reload returned non-zero (continuing)"

# Compile-check the generated ruleset (#307). OPNsense renders the active filter
# spec to /tmp/rules.debug; `pfctl -nf` parses it WITHOUT loading, so a non-zero
# rc means the ruleset is broken (a malformed rule a reload accepted silently).
# Fail the update here so the deploy stops (and update-module.sh rolls the
# firewall snapshot back) before a broken ruleset is declared healthy.
# Reachability note: the firewall is addressed by FQDN, kept DNS-independent via
# the cicd's static /etc/hosts pin (networking.hosts in tappaas-cicd.nix) so this
# check — and the rollback that may follow — work even if Unbound is down.
info "Compile-checking the firewall ruleset (pfctl -nf /tmp/rules.debug)..."
if ssh root@"$FIREWALL_FQDN" "pfctl -nf /tmp/rules.debug" >/dev/null 2>&1; then
    info "${GN}✓${CL} Firewall ruleset compiles cleanly"
else
    error "pfctl ruleset compile-check FAILED — /tmp/rules.debug does not parse."
    error "The firewall ruleset is broken; aborting the update (deploy should roll back)."
    exit 1
fi

# ── Reconcile the firewall's own reverse-proxy entry ────────────────
#
# The firewall is installed in two phases: a bare OPNsense install, then a
# full update once tappaas-cicd exists. The proxy entry that exposes the
# OPNsense GUI (e.g. firewall.<domain>, mgmt-restricted, DNS-01 cert) can only
# be created in the second phase, because it needs caddy-manager and the
# os-caddy plugin — neither present during the bare install. We therefore
# reconcile it here on every update: network:proxy update-service is
# idempotent (creates the domain + handler if missing, re-applies the access
# list / upstream / TLS strategy otherwise), so this is a no-op once converged.
#
# Guarded on the module declaring its self-proxy in its own dependsOn — i.e.
# the operator has opted the GUI in to the reverse proxy. Accept both the new
# network:proxy and the legacy network:proxy (ADR-007 P8 back-compat). The proxy
# details (proxyDomain, proxyPort, proxyUpstreamTls, proxyTls, proxyAllowedZones)
# are read from the deployed module JSON by the service script itself.
if jq -e '(.dependsOn // []) | (index("network:proxy") // index("network:proxy"))' "${FIREWALL_JSON}" >/dev/null 2>&1; then
    info "Reconciling the network module's own reverse-proxy entry (network:proxy)..."
    if [[ -x "${SCRIPT_DIR}/services/proxy/update-service.sh" ]]; then
        "${SCRIPT_DIR}/services/proxy/update-service.sh" "${NETWORK_MODULE_NAME}" \
            || warn "network:proxy update-service for the network module returned non-zero (continuing)"
    else
        warn "  network:proxy update-service.sh not found — skipping self-proxy reconcile"
    fi
fi

# ── Sync Proxmox VM trunks with active VLAN zones (proxmox-manager) ──
#
# A VM's Proxmox netN trunks= list controls which VLAN tags the host's
# vlan-aware bridge forwards to the VM. It is set ONCE at VM creation and never
# updated, so a zone activated afterwards is unreachable: the vlan0.<tag>
# interface exists on OPNsense and dnsmasq listens, but Proxmox's bridge drops
# the VM's tagged frames (the VLAN isn't in the NIC's trunk allowlist) and DHCP
# DISCOVER never arrives. See #194, #335.
#
# `proxmox-manager` (ADR-008) reconciles trunks for EVERY trunk-bearing VM
# (firewall.json carries trunks0="ALL", resolved from zones.json), preserving
# MAC/tag/queues — a trunks-only `qm set` that never recreates the NIC. queues
# is deliberately NOT changed here: changing it on a running VM hot-replugs the
# virtio NIC and drops OPNsense's LAN + VLAN parents until reboot.
info "Syncing Proxmox VM trunks with active VLAN zones (proxmox-manager)..."
if command -v proxmox-manager >/dev/null 2>&1; then
    proxmox-manager trunks --apply \
        || warn "  proxmox-manager reported drift/errors — new VLANs may not receive traffic"
else
    warn "  proxmox-manager not on PATH — skipping VM trunk sync"
fi

info "${GN}✓${CL} Firewall update completed"
