#!/usr/bin/env bash
#
# Shared helpers for the network:snat service hooks.
#
# Every hook is a thin wrapper over `snat-manager <verb>-module`, which owns
# the zone gate, the desired/live diff and the outbound-mode prerequisite. The
# hooks deliberately hold no policy of their own: a second implementation of
# the gate in bash is a second answer waiting to disagree with the first.
#
# shellcheck shell=bash

# Resolve the firewall type the same way the sibling services do. ADR-007 P8:
# deployed config is network.json (fresh) or firewall.json (legacy).
snat_firewall_type() {
    local json="${CONFIG_DIR}/network.json"
    [[ -f "${json}" ]] || json="${CONFIG_DIR}/firewall.json"
    [[ -f "${json}" ]] || { printf 'opnsense'; return 0; }
    jq -r '.firewallType // "opnsense"' "${json}"
}

# True when the module declares any source-NAT request at all. A module may
# carry the dependency without asking for anything yet, which is a no-op and
# not an error.
snat_requested() {
    local module_json="$1"
    local count
    count=$(jq '[(.config."network:snat".snatFrom // .snatFrom // [])[]] | length' \
        "${module_json}" 2>/dev/null || echo 0)
    [[ "${count}" -gt 0 ]]
}

# Print the declared source zones, one per line (for NONE-firewall reporting).
snat_declared_zones() {
    local module_json="$1"
    jq -r '(.config."network:snat".snatFrom // .snatFrom // [])[]' "${module_json}" 2>/dev/null || true
}

snat_declared_reason() {
    local module_json="$1"
    jq -r '.config."network:snat".snatReason // .snatReason // ""' "${module_json}" 2>/dev/null || true
}

# Report what a NONE-firewall deployer must arrange by hand, then succeed.
snat_report_manual() {
    local module="$1" module_json="$2" zone0
    zone0=$(jq -r '.zone0 // "?"' "${module_json}")
    warn "${BOLD}OPNsense firewall is not deployed (firewallType=NONE).${CL}"
    warn "The module '${module}' requires source NAT (masquerade) into '${zone0}':"
    while IFS= read -r zone; do
        [[ -z "${zone}" ]] && continue
        warn "  ${zone} -> ${zone0}, translated to the ${zone0} gateway address"
    done < <(snat_declared_zones "${module_json}")
    warn "  Reason: $(snat_declared_reason "${module_json}")"
    warn "Without it, devices in '${zone0}' that filter by source subnet stay unreachable."
}
