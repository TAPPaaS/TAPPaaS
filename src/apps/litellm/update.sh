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

# install.sh sources this file and wants its summary; an update (run as a
# script) says it started and keeps the summary as detail.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    summary() { debug "$@"; }
    info "${BOLD}*** Starting litellm update${CL}"
else
    summary() { info "$@"; }
fi
summary "${BOLD}Post-Install Configuration${CL}"
summary "  VM: ${VMNAME} (VMID: ${VMID})"

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
debug "Environment owner + public URL"

_VM_HOST="${VMNAME}.${ZONE0NAME}.internal"
_SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes"

_env="$(get_config_value 'environment' '')"
_owner_org="$(get_variant_config "${_env}" 2>/dev/null | jq -r '.ownerOrg // empty' 2>/dev/null || true)"
[[ -z "${_owner_org}" ]] && _owner_org="$(jq -r '.owner // empty' /home/tappaas/config/site.json 2>/dev/null || true)"

_owner_user=""
if [[ -n "${_owner_org}" ]]; then
    _owner_user="$(identity-manager org show "${_owner_org}" 2>/dev/null \
        | awk -F': *' '/^[[:space:]]*owner:/{print $2; exit}' | tr -d '[:space:]')"
fi

_owner_email=""
if [[ -n "${_owner_user}" ]]; then
    _owner_email="$(identity-manager user show "${_owner_user}" 2>/dev/null \
        | awk -F': *' '/^[[:space:]]*primaryEmail:/{print $2; exit}' | tr -d '[:space:]')"
fi

# Public URL: the platform's one derivation of the module's public name (#715).
_proxy_domain="$(module_public_domain "${VMNAME}" "${_env}" \
    "$(read_module_config "${VMNAME}" 2>/dev/null || echo '{}')")"

if [[ -z "${_owner_email}" && -z "${_proxy_domain}" ]]; then
    warn "  Neither an environment owner nor a public URL could be resolved — skipping"
else
    [[ -n "${_owner_email}" ]] && debug "  Owner: ${BL}${_owner_user}${CL} <${_owner_email}>"
    [[ -n "${_proxy_domain}" ]] && debug "  Public URL: ${BL}https://${_proxy_domain}${CL}"

    # `restart`, NOT `start`: these are Type=oneshot with RemainAfterExit, so once
    # they have run at boot `start` is a silent no-op and nothing re-applies.
    if printf 'LITELLM_OWNER_EMAIL=%s\nLITELLM_PUBLIC_URL=%s\n' \
            "${_owner_email}" "${_proxy_domain:+https://${_proxy_domain}}" \
        | ssh ${_SSH_OPTS} "tappaas@${_VM_HOST}" \
            "{ [ -d /etc/secrets ] || sudo install -d -m 700 /etc/secrets; } && \
             sudo install -m600 -o root -g root /dev/stdin /etc/secrets/litellm-owner.env && \
             sudo systemctl restart litellm-integrations.service && \
             sudo systemctl restart litellm-register-vllm.service && \
             sudo systemctl restart litellm-seed-admin.service" 2>/dev/null
    then
        debug "  ${GN}✓${CL} owner + public URL applied (admin promoted, vLLM model registered)"
    else
        warn "  Could not apply owner/public URL on ${_VM_HOST} (is the VM up?)"
    fi
fi

summary "${BOLD}Installation Complete${CL}"
summary "  VM: ${VMNAME} (VMID: ${VMID})"
summary "  Node: ${NODE}"
summary "  Zone: ${ZONE0NAME}"
if [[ -n "${HANODE}" ]]; then
    summary "  HA Node: ${HANODE}"
fi
