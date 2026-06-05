#!/usr/bin/env bash
#
# nat-common.sh — shared helpers for the firewall:nat service scripts.
#
# Sourced AFTER common-install-routines.sh, so it relies on:
#   - $JSON                 normalized module config (auto-loaded from $1)
#   - get_config_value()    flat config reader
#   - info/warn/error/die   logging functions
#
# A consuming module declares its port-forwards under the firewall:nat config
# block, which common-install-routines normalizes to a top-level `natRules`
# array:
#
#   "config": {
#     "firewall:nat": {
#       "natRules": [
#         { "externalPort": 2022, "internalPort": 22, "protocol": "TCP",
#           "description": "SSH" }
#       ]
#     }
#   }
#
# All rules for a module forward to that module's single internal target
# (its `ip`, or the DNS name <vmname>.<zone0>.internal).

# Emit each configured NAT rule as a compact JSON object, one per line.
nat_rules_json() {
    echo "${JSON}" | jq -c '(.natRules // [])[]'
}

# Count configured NAT rules.
nat_rule_count() {
    echo "${JSON}" | jq '(.natRules // []) | length'
}

# Resolve the internal target IP for the module:
#   1. explicit `ip` field (static reservation), else
#   2. DNS resolution of <vmname>.<zone0>.internal
# Echoes the IP on success; returns 1 if it cannot be resolved.
nat_resolve_target() {
    local module="$1" vmname zone ip host
    ip=$(get_config_value 'ip' '')
    if [[ -n "${ip}" && "${ip}" != "null" ]]; then
        echo "${ip}"
        return 0
    fi
    vmname=$(get_config_value 'vmname' '')
    [[ -z "${vmname}" ]] && vmname="${module}"
    zone=$(get_config_value 'zone0' '')
    [[ -z "${zone}" ]] && return 1
    host="${vmname}.${zone}.internal"
    if command -v dig &>/dev/null; then
        ip=$(dig +short A "${host}" 2>/dev/null | head -1)
    fi
    if [[ -n "${ip}" ]]; then
        echo "${ip}"
        return 0
    fi
    return 1
}

# Build the idempotency description for a rule (module + rule JSON object).
# Uses the rule's own `description` if present, else "<protocol> <externalPort>".
# Always prefixed with "TAPPaaS: <module> " so cleanup-by-prefix works.
nat_rule_description() {
    local module="$1" rule_json="$2" desc proto ext
    desc=$(echo "${rule_json}" | jq -r '.description // ""')
    if [[ -n "${desc}" ]]; then
        echo "TAPPaaS: ${module} - ${desc}"
        return 0
    fi
    proto=$(echo "${rule_json}" | jq -r '.protocol // "TCP"')
    ext=$(echo "${rule_json}" | jq -r '.externalPort')
    echo "TAPPaaS: ${module} ${proto} ${ext}"
}

# Field accessors for a single rule JSON object.
nat_rule_external_port() { echo "$1" | jq -r '.externalPort'; }
nat_rule_protocol()      { echo "$1" | jq -r '.protocol // "TCP"'; }
# internalPort defaults to externalPort when omitted.
nat_rule_internal_port() { echo "$1" | jq -r '.internalPort // .externalPort'; }

# Delete every port-forward whose description starts with "TAPPaaS: <module>".
# Best-effort; echoes the number of rules removed. Applies once at the end.
nat_purge_module_rules() {
    local module="$1" prefix uuids uuid count=0
    prefix="TAPPaaS: ${module}"
    uuids=$(nat-manager list-rules --no-ssl-verify --json --search "${prefix}" 2>/dev/null \
        | jq -r --arg p "${prefix}" '.[] | select(.description | startswith($p)) | .uuid') || return 0
    for uuid in ${uuids}; do
        if nat-manager delete-rule --no-ssl-verify --uuid "${uuid}" --no-apply >/dev/null 2>&1; then
            count=$((count + 1))
        fi
    done
    if [[ "${count}" -gt 0 ]]; then
        nat-manager apply --no-ssl-verify >/dev/null 2>&1 || true
    fi
    echo "${count}"
}
