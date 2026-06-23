#!/usr/bin/env bash
#
# TAPPaaS hass VM update
#
# HAOS manages its own updates via the Home Assistant web UI.
# This script verifies the VM is running and reports access info.
#
# Usage: ./update.sh <vmname>
# Example: ./update.sh hass
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VMNAME="$(get_config_value 'vmname' "$1")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
HANODE="$(get_config_value 'HANode' "$(get_default_ha_node "$NODE")")"

readonly ZONES_FILE="/home/tappaas/config/zones.json"
readonly HA_DATA_DIR="/mnt/data/supervisor/homeassistant"
readonly HA_CONFIG_YAML="${HA_DATA_DIR}/configuration.yaml"

# ── Configure reverse-proxy trust ────────────────────────────────────
#
# Home Assistant rejects proxied requests with HTTP 400 unless the proxy's
# source IP is listed in http.trusted_proxies (with use_x_forwarded_for).
# When this module is fronted by network:proxy, Caddy reaches HA from the
# firewall's gateway IP on the VM's own zone (e.g. srv-home -> 10.2.10.1), so
# that address must be trusted. HAOS keeps its config inside the VM (not nix),
# so we inject the block via the qemu guest agent and restart Core.
#
# Idempotent and non-fatal: on a fresh install HA Core may still be pulling
# its container (configuration.yaml absent) — we warn and let the next update
# apply it, rather than failing the install.
configure_ha_trusted_proxy() {
    # Only relevant when this module is actually proxied.
    if ! jq -e '(.dependsOn // []) | index("network:proxy")' \
            <<<"${JSON}" >/dev/null 2>&1; then
        return 0
    fi

    # Trusted proxy = the firewall's gateway IP on the VM's zone (TAPPaaS
    # gateways are always .1 of the zone network, e.g. 10.2.10.0/24 -> 10.2.10.1).
    local zone_net gw
    zone_net=$(jq -r --arg z "${ZONE0NAME}" '.[$z].ip // empty' "${ZONES_FILE}" 2>/dev/null)
    if [[ -z "${zone_net}" ]]; then
        warn "  trusted_proxies: cannot resolve zone '${ZONE0NAME}' network — skipping"
        return 0
    fi
    gw="$(awk -F. '{print $1"."$2"."$3".1"}' <<<"${zone_net%/*}")"

    # Find the node currently hosting the VM (HA may have migrated it).
    local primary host_node node_fqdn
    primary="$(get_primary_node_fqdn 2>/dev/null || echo "$(get_node_hostname 0).mgmt.internal")"
    host_node=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@"${primary}" \
        "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
         | jq -r --arg id \"${VMID}\" '.[]|select(.vmid==(\$id|tonumber))|.node'" \
        2>/dev/null | head -1)
    [[ -z "${host_node}" ]] && host_node="${NODE}"
    node_fqdn="${host_node}.mgmt.internal"

    info "  Ensuring HA trusts reverse proxy ${BL}${gw}${CL} (use_x_forwarded_for)..."

    # Remote POSIX-sh run inside HAOS via the guest agent. Exit codes:
    #   0  http: block already present and trusts ${gw} (no change)
    #   10 block appended (Core restart needed)
    #   7  configuration.yaml not present yet (Core still installing)
    #   8  an http: block exists but does not list ${gw} (manual review)
    local remote_script ge ec
    remote_script="F=${HA_CONFIG_YAML}
[ -f \"\$F\" ] || exit 7
if grep -q '^http:' \"\$F\"; then
    grep -q '${gw}' \"\$F\" && exit 0
    exit 8
fi
cp \"\$F\" \"\${F}.bak\" 2>/dev/null || true
printf '\nhttp:\n  use_x_forwarded_for: true\n  trusted_proxies:\n    - ${gw}\n' >> \"\$F\"
exit 10"

    ge=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@"${node_fqdn}" \
        "qm guest exec ${VMID} --timeout 30 -- /bin/sh -c $(printf '%q' "${remote_script}")" \
        2>/dev/null) || true
    ec=$(jq -r '.["exitcode"] // empty' <<<"${ge}" 2>/dev/null)

    case "${ec}" in
        0)  info "  ${GN}✓${CL} HA already trusts ${gw}" ;;
        10)
            info "  ${GN}✓${CL} Added trusted_proxies (${gw}); restarting HA Core..."
            ssh -o BatchMode=yes root@"${node_fqdn}" \
                "qm guest exec ${VMID} -- /bin/sh -c 'nohup ha core restart >/dev/null 2>&1 &'" \
                >/dev/null 2>&1 || warn "  Could not trigger HA Core restart (restart it manually)"
            ;;
        7|"")
            warn "  HA Core not ready yet (configuration.yaml absent) — re-run update once Core is installed to apply trusted_proxies for ${gw}"
            ;;
        8)
            warn "  HA already has an http: block that does not list ${gw} — review ${HA_CONFIG_YAML} manually"
            ;;
        *)
            warn "  trusted_proxies: unexpected guest-exec result (exit ${ec}) — verify ${HA_CONFIG_YAML}"
            ;;
    esac
}

echo ""
info "${BOLD}Post-Install Configuration${CL}"
info "  VM: ${VMNAME} (VMID: ${VMID})"

configure_ha_trusted_proxy

echo ""
info "${BOLD}Installation Complete${CL}"
info "  VM: ${VMNAME} (VMID: ${VMID})"
info "  Node: ${NODE}"
info "  Zone: ${ZONE0NAME}"
if [[ -n "${HANODE}" ]]; then
    info "  HA Node: ${HANODE}"
fi
info "  Access: http://${VMNAME}:8123 (HAOS handles updates via web UI)"
