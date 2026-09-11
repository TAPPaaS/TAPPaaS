#!/usr/bin/env bash
#
# TAPPaaS Rules Service - Install
#
# Compiles `ports`, `ingress`, `egress`, and `aliases` from a consuming module's
# JSON declaration and applies the resulting firewall rules and aliases to
# OPNsense via the rules-manager CLI.
#
# When firewallType is "NONE" (no OPNsense deployed), rules-manager prints the
# manual configuration the deployer needs to apply on their own firewall and
# exits successfully — no OPNsense connection is attempted.
#
# Usage: install-service.sh <module-name>
#
# Arguments:
#   module-name   Name of the consuming module (e.g., vaultwarden)
#

set -euo pipefail

# ── Logging ──────────────────────────────────────────────────────────

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

# ── Arguments ────────────────────────────────────────────────────────

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: install-service.sh <module-name>"
    exit 1
fi

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
# ADR-007 P8: deployed config is network.json (fresh) or firewall.json (legacy, not
# yet migrated). Resolve network first, fall back to firewall. The OPNsense HOST
# (FIREWALL_FQDN) is intentionally unchanged — the host rename is deferred.
if [[ -f "${CONFIG_DIR}/network.json" ]]; then
    readonly FIREWALL_JSON="${CONFIG_DIR}/network.json"
else
    readonly FIREWALL_JSON="${CONFIG_DIR}/firewall.json"
fi

debug "network:rules install-service for module: ${BL}${MODULE}${CL}"

# ── Validate inputs ─────────────────────────────────────────────────

if [[ ! -f "${MODULE_JSON}" ]]; then
    die "Module config not found: ${MODULE_JSON}"
fi

# ── Determine firewallType (system-wide, from firewall.json) ────────

FIREWALL_TYPE="opnsense"
if [[ -f "${FIREWALL_JSON}" ]]; then
    FIREWALL_TYPE=$(jq -r '.firewallType // "opnsense"' "${FIREWALL_JSON}")
fi

# ── Short-circuit when the module has no network:rules content ─────

INGRESS_COUNT=$(read_module_config "${MODULE}" | jq -r '(.ingress // []) | length')
EGRESS_COUNT=$(read_module_config "${MODULE}" | jq -r '(.egress // []) | length')
ALIAS_COUNT=$(read_module_config "${MODULE}" | jq -r '(.aliases // {}) | length')

# Auto-pinholes (#173): even if the module has no manual ingress/egress/
# aliases, rules-manager may still need to run when a declared coordinate points
# to a provider that ships a services/<svc>/pinhole.json. Detect that here so we
# don't skip the apply step in the pinhole-only case.
#
# BOTH lists, and the installer's own provider resolution (#632). This gate read
# `.dependsOn` alone and looked the provider up as `${provider}.json`, so it
# disagreed with rules-manager twice over: a module whose only pinhole need came
# from `integratesWith` skipped the apply entirely, and so did one whose provider
# is deployed into an environment as `<provider>-<env>.json`. A gate that is
# narrower than the compiler silently withholds rules the compiler would emit.
MODULE_ENVIRONMENT=$(read_module_config "${MODULE}" | jq -r '.environment // empty')
HAS_AUTO_PINHOLE=0
while read -r dep; do
    [[ -z "$dep" ]] && continue
    provider="${dep%%:*}"
    service="${dep#*:}"
    [[ -z "$provider" || -z "$service" || "$provider" == "$service" ]] && continue
    provider_module="$(resolve_provider_module "${provider}" "${MODULE_ENVIRONMENT}")"
    PROVIDER_JSON="${CONFIG_DIR}/${provider_module}.json"
    [[ -f "$PROVIDER_JSON" ]] || continue
    location=$(jq -r '.location // empty' "$PROVIDER_JSON")
    [[ -n "$location" ]] || continue
    if [[ -f "${location}/services/${service}/pinhole.json" ]]; then
        HAS_AUTO_PINHOLE=1
        break
    fi
done < <(read_module_config "${MODULE}" | jq -r '((.dependsOn // []) + (.integratesWith // []))[]')

if (( INGRESS_COUNT == 0 && EGRESS_COUNT == 0 && ALIAS_COUNT == 0 && HAS_AUTO_PINHOLE == 0 )); then
    debug "  No ports/ingress/egress/aliases declared and no declared pinholes — nothing to apply."
    debug "${GN}network:rules install-service completed for ${MODULE} (no-op)${CL}"
    exit 0
fi

# ── Validate rules-manager availability ─────────────────────────────

if ! command -v rules-manager &>/dev/null; then
    die "rules-manager CLI not found in PATH. Rebuild opnsense-controller package."
fi

# ── Apply ────────────────────────────────────────────────────────────

debug "  ingress=${INGRESS_COUNT} egress=${EGRESS_COUNT} aliases=${ALIAS_COUNT} firewallType=${FIREWALL_TYPE}"

rules-manager add-rules "${MODULE}" \
    --firewall-type "${FIREWALL_TYPE}" \
    --no-ssl-verify \
    || die "rules-manager add-rules failed for ${MODULE}"

debug "${GN}network:rules install-service completed for ${MODULE}${CL}"
