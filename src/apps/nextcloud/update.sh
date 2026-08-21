#!/usr/bin/env bash
#
# TAPPaaS Module: nextcloud — Update
#
# Nextcloud with PostgreSQL and Redis
#
# Module-specific update steps beyond the NixOS OS update (which is handled
# by the templates:nixos dependency service updater before this script runs).
#
# Usage: ./update.sh <vmname>
# Example: ./update.sh nextcloud
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

# shellcheck disable=SC2034  # kept for potential use by sourcing scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VMNAME="$(get_config_value 'vmname' "${1:-nextcloud}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'srv')"
HANODE="$(get_config_value 'HANode' "$(get_default_ha_node "$NODE")")"

NEXTCLOUD_HOST="${VMNAME}.${ZONE0NAME}.internal"
NEXTCLOUD_CONFIG_PHP="/var/lib/nextcloud/config/config.php"

# ── Public domain resolution ─────────────────────────────────────────────────
# proxyDomain is the declared public route (network:proxy). When absent, mirror
# the install-time derivation: <vmname>.<environment domain>.
resolve_proxy_domain() {
    local domain env tappaas_domain
    domain="$(get_config_value 'proxyDomain' '')"
    if [[ -n "${domain}" ]]; then
        printf '%s\n' "${domain}"
        return 0
    fi
    env="$(get_config_value 'environment' '')"
    tappaas_domain=$(jq -r '.domain // empty' \
        <<<"$(get_variant_config "${env}" 2>/dev/null || echo '{}')")
    if [[ -z "${tappaas_domain}" ]]; then
        tappaas_domain=$(jq -r '.tappaas.domain // empty' \
            "/home/tappaas/config/configuration.json" 2>/dev/null || true)
    fi
    if [[ -z "${tappaas_domain}" ]]; then
        return 0
    fi
    printf '%s\n' "${VMNAME}.${tappaas_domain}"
}

# Is the domain actually recorded in Nextcloud's config? Read config.php
# directly — `nextcloud-occ` runs `systemd-run --pty` internally and relays no
# output over a non-TTY SSH session, so its output cannot be trusted as proof.
trusted_domain_present() {
    local host="$1" domain="$2"
    ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no \
        "tappaas@${host}" \
        "sudo -u nextcloud sed -n \"/'trusted_domains'/,/^[[:space:]]*)/p\" \
            ${NEXTCLOUD_CONFIG_PHP} 2>/dev/null" 2>/dev/null \
        | grep -qF "'${domain}'"
}

apply_domain_config() {
    local host="$1" domain="$2"
    # Call nextcloud-occ DIRECTLY (it self-switches to the nextcloud user). Do NOT wrap it
    # in `systemd-run -p User=nextcloud` — nextcloud-occ runs systemd-run internally, so
    # wrapping it nests systemd-run as a non-root user, which polkit denies (exit 1).
    # Index 0 = hostName (auto-added by NixOS); we append the internal FQDN and the
    # public domain. Loopback is always trusted, so no localhost entry is needed.
    ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no \
        "tappaas@${host}" \
        "sudo nextcloud-occ config:system:set trusted_domains 1 --value='${host}' && \
         sudo nextcloud-occ config:system:set trusted_domains 2 --value='${domain}' && \
         sudo nextcloud-occ config:system:set overwrite.cli.url --value='https://${domain}' && \
         sudo nextcloud-occ config:system:set overwriteprotocol --value='https'" >/dev/null 2>&1 \
        || true
}

# Converge trusted domains + public URL. Idempotent: fixed indices, same values.
#
# This lives in update.sh, not install.sh, because install.sh sources this file
# ("all update actions is also needed at install time") and reconcile runs
# update.sh only. Keeping it install-only meant a proxyDomain added or changed
# after first install was never applied, and `reconcile` reported success while
# converging nothing.
#
# The write is VERIFIED by reading config.php back. `occ` exits 0 over a non-TTY
# SSH session while relaying no output at all, so a zero exit code is not
# evidence the value landed — trusting it is what let the original bug report
# success while writing nothing.
converge_nextcloud_domains() {
    local domain
    domain="$(resolve_proxy_domain)"

    if [[ -z "${domain}" ]]; then
        info "  No proxyDomain declared or derivable — skipping domain config."
        return 0
    fi

    # On a fresh install this file is sourced before the VM exists. Skip quietly;
    # install.sh calls this again once the VM is up.
    if ! ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "tappaas@${NEXTCLOUD_HOST}" true >/dev/null 2>&1; then
        info "  ${NEXTCLOUD_HOST} not reachable yet — deferring domain config."
        return 0
    fi

    info "${BOLD}Converging trusted domains + public URL…${CL}"

    if trusted_domain_present "${NEXTCLOUD_HOST}" "${domain}"; then
        info "  ${GN}✓${CL} ${domain} already trusted — nothing to change."
        return 0
    fi

    apply_domain_config "${NEXTCLOUD_HOST}" "${domain}"
    if trusted_domain_present "${NEXTCLOUD_HOST}" "${domain}"; then
        info "  ${GN}✓${CL} Trusted domains + public URL configured (https://${domain})"
        return 0
    fi

    error "Could not write trusted_domains on ${NEXTCLOUD_HOST}. Nextcloud will answer"
    error "HTTP 400 'Access through untrusted domain' on https://${domain}. Verify with:"
    error "  ssh tappaas@${NEXTCLOUD_HOST} \"sudo -u nextcloud grep -A6 trusted_domains ${NEXTCLOUD_CONFIG_PHP}\""
    return 1
}

echo ""
info "${BOLD}Module Update: nextcloud${CL}"
info "  VM:   ${VMNAME} (VMID: ${VMID})"
info "  Node: ${NODE}"
info "  Zone: ${ZONE0NAME}"

# NixOS OS update is handled by templates:nixos update-service.sh before this
# script runs. The domain converge below is the one module-specific step.
echo ""
converge_nextcloud_domains

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
info "${BOLD}Update Complete${CL}"
info "  VM:   ${VMNAME} (VMID: ${VMID})"
info "  Node: ${NODE}"
info "  Zone: ${ZONE0NAME}"
if [[ -n "${HANODE}" ]]; then
    info "  HA Node: ${HANODE}"
fi
