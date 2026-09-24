#!/usr/bin/env bash
# TAPPaaS Firewall Module Update
#
# Updates the OPNsense firewall software via SSH and applies zone configuration.
#
# Order of operations:
# 1. OPNsense software update (base, kernel, packages)
# 2. Reboot to apply updates + regenerate configs — ONLY when the update actually
#    installed a new base/kernel (skipped on a no-op re-run; see the fingerprint)
# 3. Wait for firewall to come back online
# 4. Verify DNS is working (Unbound health check)
# 5. Apply zone configuration via zone-manager
# 6. Remaining configuration (proxy, net0 trunks, etc.)
#
# This order ensures OPNsense updates are applied BEFORE zone-manager runs,
# which triggers Unbound config regeneration. See DESIGN.md
# ("Troubleshooting: Unbound / DNSBL") for background.
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
# Fingerprint the installed base+kernel first, so we can tell whether this run
# actually applies a firmware update (→ reboot) vs. a no-op re-run (→ no reboot).
# NOTE: OPNsense's root login shell is csh (opnsense-shell) — it CANNOT parse
# `$(...)`, so run the two version commands plain (csh handles `;`) and join the
# lines locally.
_fw_ver_before="$(ssh root@"$FIREWALL_FQDN" 'freebsd-version -k; freebsd-version -u' 2>/dev/null | tr '\n' '|' || true)"
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

# Did the update actually install a new base/kernel? If the fingerprint is
# unchanged, nothing that needs a reboot was applied (package-only updates don't
# need one), so we skip the disruptive firewall reboot on a no-op re-run. If we
# could not read the versions, assume a reboot is needed (safe default).
_fw_ver_after="$(ssh root@"$FIREWALL_FQDN" 'freebsd-version -k; freebsd-version -u' 2>/dev/null | tr '\n' '|' || true)"
_fw_reboot_needed=1
if [[ -n "$_fw_ver_before" && "$_fw_ver_before" == "$_fw_ver_after" ]]; then
    _fw_reboot_needed=0
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

if [[ "$_fw_reboot_needed" -eq 0 ]]; then
    debug "${GN}✓${CL} OPNsense already current (${_fw_ver_after%%|*}) — no base/kernel update, skipping reboot."
elif automatic_reboot_enabled; then
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
# Python/dnspython version mismatch (see DESIGN.md, "Troubleshooting:
# Unbound / DNSBL"), Unbound may fail to start. We check DNS here to
# catch the problem early.

debug "Verifying Unbound DNS is responding..."
DNS_CHECK_RETRIES=6
DNS_CHECK_COUNT=0
while ! dig @10.0.0.1 firewall.mgmt.internal +short +timeout=5 >/dev/null 2>&1; do
    DNS_CHECK_COUNT=$((DNS_CHECK_COUNT + 1))
    if [[ $DNS_CHECK_COUNT -ge $DNS_CHECK_RETRIES ]]; then
        warn "Unbound DNS not responding on 10.0.0.1 after ${DNS_CHECK_RETRIES} attempts"
        warn "This may indicate a Python/dnspython version mismatch in OPNsense."
        warn "See src/foundation/network/DESIGN.md (Troubleshooting: Unbound / DNSBL) for recovery steps."
        warn "Quick recovery on the firewall: pluginctl -c unbound_start"
        warn "Attempting to continue, but zone-manager may fail..."
        break
    fi
    sleep 5
    printf "."
done
if [[ $DNS_CHECK_COUNT -lt $DNS_CHECK_RETRIES ]]; then
    # Only emit the newline when progress dots were actually printed (retry path);
    # in the normal first-try case this avoids a spurious blank line.
    [[ $DNS_CHECK_COUNT -gt 0 ]] && echo ""
    debug "${GN}✓${CL} Unbound DNS is responding"
fi

# ── Output levels ───────────────────────────────────────────────────
#
# relog_steps — a filter for a sub-command's stream. Warnings and errors pass
# through as they are; zone-manager's "Step N:" headers and its zone table stay
# [Info] (they say what the update is doing, and what the site looks like);
# everything else — the serves edges, "All planes converged" — is detail, [Debug]. The caller keeps the
# sub-command's exit code (PIPESTATUS), so a failure is never masked.
relog_steps() {
    local line plain table=0
    while IFS= read -r line; do
        plain="$(printf '%s' "${line}" | sed 's/\x1b\[[0-9;]*m//g')"
        # The zone table stays [Info] (operator decision): "Zone Summary:" through
        # its "N zones · …" totals line.
        if [[ "${plain}" == "[Info] Zone Summary:"* ]]; then table=1; fi
        if [[ ${table} -eq 1 ]]; then
            printf '%s\n' "${line}"
            [[ "${plain}" == *" zones · "* ]] && table=0
            continue
        fi
        case "${plain}" in
            "[Warning]"*|"[Error]"*|"[Fatal]"*) printf '%s\n' "${line}" ;;
            "[Info] Step "[0-9]*) printf '%s\n' "${line}" ;;
            "") ;;
            *) debug "  ${plain#\[Info\] }" ;;
        esac
    done
}

# quiet_on_success <label> <command...> — run it with its output captured:
# [Debug] when it succeeds, printed in full (then a warning) when it does not.
quiet_on_success() {
    local label="$1" out rc=0 line
    shift
    out="$("$@" 2>&1)" || rc=$?
    if [[ ${rc} -eq 0 ]]; then
        while IFS= read -r line; do [[ -n "${line}" ]] && debug "  ${line}"; done <<< "${out}"
    else
        printf '%s\n' "${out}"
        warn "${label} returned non-zero (continuing)"
    fi
    return 0
}

# ── Apply zone configuration ────────────────────────────────────────

info "Applying zone configuration..."
# Via network-manager: it renders zones.effective.json (the `serves`-derived
# edges) and hands THAT to zone-manager. The authored zones.json lacks those
# edges, so the stale-rule reaper would delete them on every update.
_nm_log="$(mktemp "${TMPDIR:-/tmp}/network-reconcile.XXXXXX.log")"
set +e
/home/tappaas/bin/network-manager reconcile --only opnsense --apply 2>&1 | tee "${_nm_log}" | relog_steps
_nm_rc=${PIPESTATUS[0]}
set -e
if [[ ${_nm_rc} -ne 0 ]]; then
    # The filter sent the unlabelled lines to [Debug]; a failure shows them all.
    error "network-manager reconcile --only opnsense --apply failed (rc ${_nm_rc}) — its output:"
    tail -n 60 "${_nm_log}" >&2
    rm -f "${_nm_log}"
    exit "${_nm_rc}"
fi
rm -f "${_nm_log}"

# When zone-manager creates new opt interfaces (e.g. activating testAllowA/testAllowB),
# OPNsense's auto-generated anti-lockout and bootp pass rules for those
# interfaces are NOT regenerated by /api/firewall/filter/apply. Without those
# rules, DHCP DISCOVER from a fresh VM is silently dropped on the new VLAN.
# `configctl filter reload` re-renders the full ruleset, including auto rules.
debug "Reloading OPNsense filter to regenerate auto-rules for any new interfaces..."
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
debug "Compile-checking the firewall ruleset (pfctl -nf /tmp/rules.debug)..."
if ssh root@"$FIREWALL_FQDN" "pfctl -nf /tmp/rules.debug" >/dev/null 2>&1; then
    debug "${GN}✓${CL} Firewall ruleset compiles cleanly"
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
    debug "Reconciling the network module's own reverse-proxy entry (network:proxy)..."
    if [[ -x "${SCRIPT_DIR}/services/proxy/update-service.sh" ]]; then
        # Reconcile Step 2 already ran this service and reported its warnings;
        # this second pass only matters when it changes something or fails.
        quiet_on_success "network:proxy update-service for the network module" \
            "${SCRIPT_DIR}/services/proxy/update-service.sh" "${NETWORK_MODULE_NAME}"
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
debug "Syncing Proxmox VM trunks with active VLAN zones (proxmox-manager)..."
if command -v proxmox-manager >/dev/null 2>&1; then
    # In sync ("0 change(s) applied") is detail; a change or a failure is shown.
    _pm_rc=0
    _pm_out="$(proxmox-manager trunks --apply 2>&1)" || _pm_rc=$?
    if [[ ${_pm_rc} -eq 0 && "${_pm_out}" == *"(0 change(s) applied)"* ]]; then
        while IFS= read -r _l; do [[ -n "${_l}" ]] && debug "  ${_l}"; done <<< "${_pm_out}"
    else
        printf '%s\n' "${_pm_out}"
        [[ ${_pm_rc} -eq 0 ]] || warn "  proxmox-manager reported drift/errors — new VLANs may not receive traffic"
    fi
else
    warn "  proxmox-manager not on PATH — skipping VM trunk sync"
fi

# ── Time service (#716) ─────────────────────────────────────────────
#
# The firewall's ntpd is every guest's first time source, and this update is
# what knocks it over: while the steps above reconfigure OPNsense, its NTP
# replies are held for seconds, the delayed samples poison ntpd's clock filter,
# and it drops to orphan mode for up to an hour (measured on hrossen, 2026-09-24:
# three unrelated servers at an identical −4246.9 ms). Two settings and a
# restart keep guests on real time through that:
#   orphan mode off — an unsynchronised ntpd then says so, and guests move on
#                     to the public servers after their gateway (7f0a23df);
#   iburst + a restart now — the poisoned samples are discarded and the
#                     firewall is disciplined again within seconds.
# Converged on every update (idempotent), so a site gets it at its next sweep.
debug "Converging the firewall's time service (ntpd)..."
_ntp_php="${SCRIPT_DIR}/scripts/ntpd-converge.php"
if [[ -f "${_ntp_php}" ]]; then
    _ntp_out="$(ssh root@"$FIREWALL_FQDN" /bin/sh -c 'php /dev/stdin' < "${_ntp_php}" 2>&1)" || true
    case "${_ntp_out}" in
        CHANGED*)   info "  firewall ntpd: ${_ntp_out#CHANGED }" ;;
        UNCHANGED*) debug "  firewall ntpd settings already converged" ;;
        *)          warn "  could not converge the firewall's ntpd settings: ${_ntp_out:-no output}" ;;
    esac
    if ssh root@"$FIREWALL_FQDN" "pluginctl -s ntpd restart" >/dev/null 2>&1; then
        debug "  ntpd restarted (fresh associations after the reconfiguration)"
    else
        warn "  could not restart ntpd on the firewall — it recovers by itself within the hour"
    fi
else
    warn "  ${_ntp_php} missing — firewall ntpd not converged"
fi

info "${GN}✓${CL} Firewall update completed"
