#!/usr/bin/env bash
#
# TAPPaaS hass Config Service - Delete
#
# Removes the http: block from configuration.yaml.
# Does NOT remove the LLAT from secrets (may be used by other services).
#
# Usage: delete-service.sh <module-name>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
[[ -n "${MODULE}" ]] || { echo "Usage: $0 <module-name>"; exit 1; }

check_json "/home/tappaas/config/${MODULE}.json" || exit 1

VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
NODE_FQDN="${NODE}.mgmt.internal"
readonly HA_DATA_DIR="/mnt/data/supervisor/homeassistant"
readonly HA_CONFIG_YAML="${HA_DATA_DIR}/configuration.yaml"

info "hass:config delete-service for module: ${BL}${MODULE}${CL}"

ssh -o BatchMode=yes root@"${NODE_FQDN}" \
    "qm guest exec ${VMID} -- bash -c 'sed -i \"/^http:/,/^[^ #]/{ /^http:/d; /^  use_x_forwarded_for/d; /^  trusted_proxies/d; /^    - /d }\" ${HA_CONFIG_YAML} && echo done'" \
    2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('out-data',''))" 2>/dev/null

info "  ${GN}✓${CL} http: block removed from configuration.yaml"
info "  Note: HA_TOKEN in /etc/secrets/hass.env retained"
