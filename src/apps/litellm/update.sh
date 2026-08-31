#!/usr/bin/env bash
#
# TAPPaaS Identity VM update
#
# Update VM and applies module specific updates
#
# Usage: ./update.sh <vmname>
# Example: ./update.sh test-nixos
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get imageType to determine post-install steps
VMNAME="$(get_config_value 'vmname' "$1")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
HANODE="$(get_config_value 'HANode' "$(get_default_ha_node "$NODE")")"

echo ""
info "${BOLD}Post-Install Configuration${CL}"
info "  VM: ${VMNAME} (VMID: ${VMID})"

# ── Environment owner + public URL → LiteLLM (#503) ──────────────────────────
#
# Two values the VM cannot work out for itself:
#   * the environment owner, who becomes the LiteLLM proxy_admin (the VM has no
#     access to people data)
#   * the module's public URL, which LiteLLM needs as PROXY_BASE_URL so the SSO
#     redirect_uri points at the real host instead of localhost
#
# Chain: <module>.environment -> environments/<env>.json .ownerOrg
#        -> people org .owner -> user .primaryEmail
echo ""
info "${BOLD}Environment owner + public URL${CL}"

_VM_HOST="${VMNAME}.${ZONE0NAME}.internal"
_SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes"

_env="$(get_config_value 'environment' '')"
_owner_org="$(get_variant_config "${_env}" 2>/dev/null | jq -r '.ownerOrg // empty' 2>/dev/null || true)"
[[ -z "${_owner_org}" ]] && _owner_org="$(jq -r '.owner // empty' /home/tappaas/config/site.json 2>/dev/null || true)"

_owner_user=""
if [[ -n "${_owner_org}" ]]; then
    _owner_user="$(people-manager org show "${_owner_org}" 2>/dev/null \
        | awk -F': *' '/^[[:space:]]*owner:/{print $2; exit}' | tr -d '[:space:]')"
fi

_owner_email=""
if [[ -n "${_owner_user}" ]]; then
    _owner_email="$(people-manager user show "${_owner_user}" 2>/dev/null \
        | awk -F': *' '/^[[:space:]]*primaryEmail:/{print $2; exit}' | tr -d '[:space:]')"
fi

# Public URL: the module's resolved proxyDomain, else <vmname>.<env domain>.
_proxy_domain="$(read_module_config "${VMNAME}" 2>/dev/null \
    | jq -r '.config["network:proxy"].proxyDomain // .proxyDomain // empty' 2>/dev/null || true)"
if [[ -z "${_proxy_domain}" ]]; then
    _base_domain="$(get_variant_config "${_env}" 2>/dev/null | jq -r '.domain // empty' 2>/dev/null || true)"
    [[ -n "${_base_domain}" ]] && _proxy_domain="${VMNAME}.${_base_domain}"
fi

if [[ -z "${_owner_email}" && -z "${_proxy_domain}" ]]; then
    warn "  Neither an environment owner nor a public URL could be resolved — skipping"
else
    [[ -n "${_owner_email}" ]] && info "  Owner: ${BL}${_owner_user}${CL} <${_owner_email}>"
    [[ -n "${_proxy_domain}" ]] && info "  Public URL: ${BL}https://${_proxy_domain}${CL}"

    # `restart`, NOT `start`: these are Type=oneshot with RemainAfterExit, so once
    # they have run at boot `start` is a silent no-op and nothing re-applies.
    if printf 'LITELLM_OWNER_EMAIL=%s\nLITELLM_PUBLIC_URL=%s\n' \
            "${_owner_email}" "${_proxy_domain:+https://${_proxy_domain}}" \
        | ssh ${_SSH_OPTS} "tappaas@${_VM_HOST}" \
            "sudo install -d -m 700 /etc/secrets && \
             sudo install -m600 -o root -g root /dev/stdin /etc/secrets/litellm-owner.env && \
             sudo systemctl restart litellm-integrations.service && \
             sudo systemctl restart litellm-register-vllm.service && \
             sudo systemctl restart litellm-seed-admin.service" 2>/dev/null
    then
        info "  ${GN}✓${CL} owner + public URL applied (admin promoted, vLLM model registered)"
    else
        warn "  Could not apply owner/public URL on ${_VM_HOST} (is the VM up?)"
    fi
fi

# ── Narrow the Authentik access gate (LiteLLM's 5-seat SSO cap) ──────────────
# identity:identity binds `users` — every org member — to every app it wires,
# and app-bind-groups is additive, so it comes back on EVERY reconcile. LiteLLM
# is the one module where that is actively harmful: its open-source SSO path
# allows five user rows, and a row is created the first time someone logs in.
# Anyone who opens the UI once out of curiosity permanently spends a seat.
#
# This runs here, not in identity:identity, because the cap is LiteLLM's alone
# and the shared foundation should not carry one app's licence quirk. It must
# run AFTER dependency services are re-applied (update-module.sh Step 2), which
# is precisely where this script sits — running it any earlier would be undone.
if [[ -x "${SCRIPT_DIR}/scripts/narrow-access-gate.sh" ]]; then
    info "${BOLD}Narrowing Authentik access gate to litellm-admins${CL}"
    if ! "${SCRIPT_DIR}/scripts/narrow-access-gate.sh" "${VMNAME}" users; then
        # Non-fatal: a too-wide gate is a seat-consumption problem, not an
        # outage, and must not fail an otherwise good deployment. It is loud
        # because the symptom (seats quietly exhausted weeks later) is not.
        warn "  Could not narrow the access gate — 'users' may still be bound;"
        warn "  check Authentik → Applications → ${VMNAME} → Policy bindings"
    fi
fi

echo ""
info "${BOLD}Installation Complete${CL}"
info "  VM: ${VMNAME} (VMID: ${VMID})"
info "  Node: ${NODE}"
info "  Zone: ${ZONE0NAME}"
if [[ -n "${HANODE}" ]]; then
    info "  HA Node: ${HANODE}"
fi
