#!/usr/bin/env bash
# shellcheck shell=bash
#
# ensure-authentik-creds.sh — shared helper for the identity module (issue #312).
#
# Materialises ~/.authentik-credentials.txt on the cicd host on demand by
# fetching AUTHENTIK_BOOTSTRAP_TOKEN from the identity VM. This is the single
# source of truth for the Authentik credential bootstrap: both identity/update.sh
# and identity/services/accessControl/install-service.sh call it, so a consuming
# module install self-heals when the cicd-side credential is missing or stale
# (e.g. after a cicd rebuild), instead of dying.
#
# Sourced AFTER common-install-routines.sh, so it relies on:
#   - CONFIG_DIR            standard config directory
#   - info/warn/die         logging functions
#
# Public function:
#   ensure_authentik_credentials   idempotent; (re)creates the credentials file
#                                   (mode 600) and verifies the token is accepted.
#                                   Returns 0 on success; die()s on unrecoverable
#                                   failure with an actionable remediation hint.

# Path to the cicd-side credentials file consumed by authentik-manager.
: "${AUTHENTIK_CRED_FILE:=${HOME}/.authentik-credentials.txt}"

# Resolve the identity VM's internal FQDN and API URL from the deployed
# identity.json (independent of whichever module triggered the call). Falls back
# to the documented defaults (vmname=identity, zone0=mgmt) when fields are unset.
_authentik_identity_endpoints() {
    local identity_cfg="${CONFIG_DIR}/identity.json"
    local vmname="identity" zone0="mgmt"
    if [[ -f "${identity_cfg}" ]]; then
        vmname="$(jq -r '.vmname // "identity"' "${identity_cfg}" 2>/dev/null)"
        zone0="$(jq -r '.zone0 // "mgmt"' "${identity_cfg}" 2>/dev/null)"
    fi
    AUTHENTIK_IDENTITY_FQDN="${vmname}.${zone0}.internal"
    AUTHENTIK_IDENTITY_API="http://${AUTHENTIK_IDENTITY_FQDN}:9000"
    # Host actually used to reach the VM (API + ssh). Defaults to the FQDN;
    # _authentik_resolve_identity_host() may swap it for an IP on a DNS race.
    AUTHENTIK_IDENTITY_HOST="${AUTHENTIK_IDENTITY_FQDN}"
}

# Guard against the DNS-registration race (#379): the identity VM's
# <vmname>.<zone0>.internal record is registered with OPNsense asynchronously, so
# this bootstrap can run before it resolves. Wait for the hostname to resolve;
# if it never does, fall back to a configured IP (identity.json .ip) so the
# install can proceed instead of failing on an unresolvable host.
_authentik_resolve_identity_host() {
    local fqdn="${AUTHENTIK_IDENTITY_FQDN}" i ip=""

    # 1) DNS readiness — give the OPNsense DNS registration time to propagate.
    for i in $(seq 1 24); do   # up to ~2 min at 5s intervals
        if getent hosts "${fqdn}" >/dev/null 2>&1; then
            [[ $i -gt 1 ]] && info "  ${GN}✓${CL} ${fqdn} resolved"
            AUTHENTIK_IDENTITY_HOST="${fqdn}"
            AUTHENTIK_IDENTITY_API="http://${fqdn}:9000"
            return 0
        fi
        [[ $i -eq 1 ]] && info "${BOLD}Waiting for ${fqdn} to resolve in DNS (up to 2 min)...${CL}"
        sleep 5
    done

    warn "${fqdn} did not resolve in DNS — attempting IP fallback (DNS-registration race, #379)"

    # 2) IP fallback — an explicit static IP from identity.json, if provided.
    local identity_cfg="${CONFIG_DIR}/identity.json"
    if [[ -f "${identity_cfg}" ]]; then
        ip="$(jq -r '.ip // empty' "${identity_cfg}" 2>/dev/null)"
    fi

    [[ -n "${ip}" ]] || die "${fqdn} is not resolvable and no fallback IP is available. Remediation: register the identity VM in OPNsense DNS ('dns-manager add ${fqdn%%.*} ${fqdn#*.} <ip>') or set .ip in identity.json, then re-run."

    info "  ${GN}✓${CL} Using identity VM IP ${ip} (DNS not yet propagated)"
    AUTHENTIK_IDENTITY_HOST="${ip}"
    AUTHENTIK_IDENTITY_API="http://${ip}:9000"
}

# Fetch the bootstrap token from the identity VM and (re)write the credentials
# file. die()s if the token cannot be read.
_authentik_write_credentials() {
    local cred_file="$1" api="$2" fqdn="$3" token

    info "${BOLD}Waiting for Authentik API at ${api}/api/v3/ (up to 5 min)...${CL}"
    local i
    for i in $(seq 1 60); do
        if curl -fsS -o /dev/null --max-time 4 "${api}/api/v3/" 2>/dev/null; then
            info "  ${GN}✓${CL} Authentik API responding"
            break
        fi
        [[ $i -eq 60 ]] && die "Authentik API never came up at ${api} — confirm the identity VM is running and finished first boot, then re-run."
        sleep 5
    done

    info "${BOLD}Fetching AUTHENTIK_BOOTSTRAP_TOKEN from ${fqdn}${CL}"
    # Clear any stale host key (the VM may have been re-created with a new
    # ed25519 key) so StrictHostKeyChecking=accept-new accepts the current one.
    ssh-keygen -R "${fqdn}" 2>/dev/null || true
    token="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" \
        "tappaas@${fqdn}" \
        "sudo grep '^AUTHENTIK_BOOTSTRAP_TOKEN=' /etc/secrets/authentik.env | cut -d= -f2-" 2>/dev/null || true)"
    [[ -n "${token}" ]] || die "could not read AUTHENTIK_BOOTSTRAP_TOKEN from ${fqdn}:/etc/secrets/authentik.env — is the identity VM finished its first boot? Remediation: cd src/foundation/identity && ./update.sh identity"

    (umask 077
     printf 'url=%s\ntoken=%s\n' "${api}" "${token}" > "${cred_file}")
    chmod 600 "${cred_file}"
    info "  ${GN}✓${CL} ${cred_file} written (mode 600)"
}

# Idempotently ensure ~/.authentik-credentials.txt exists and is accepted by
# Authentik. Fast-path returns immediately when the file is present and valid;
# otherwise the token is (re)fetched from the identity VM and verified.
ensure_authentik_credentials() {
    local cred_file="${AUTHENTIK_CRED_FILE}"

    command -v authentik-manager >/dev/null 2>&1 \
        || die "authentik-manager not in PATH (rebuild opnsense-controller)"

    _authentik_identity_endpoints

    # Fast path: file present and the token still works → nothing to do.
    if [[ -f "${cred_file}" ]] && authentik-manager test >/dev/null 2>&1; then
        return 0
    fi

    if [[ -f "${cred_file}" ]]; then
        warn "${cred_file} present but the token is not accepted (stale?) — refreshing from ${AUTHENTIK_IDENTITY_FQDN}"
    else
        warn "${cred_file} missing — bootstrapping from ${AUTHENTIK_IDENTITY_FQDN}"
    fi

    # Resolve the identity host (DNS-readiness wait + IP fallback) before the
    # API/ssh calls so a DNS-registration race doesn't fail the bootstrap (#379).
    _authentik_resolve_identity_host

    _authentik_write_credentials "${cred_file}" "${AUTHENTIK_IDENTITY_API}" "${AUTHENTIK_IDENTITY_HOST}"

    # Authentik's worker binds AUTHENTIK_BOOTSTRAP_TOKEN to akadmin asynchronously
    # on first boot — the API may be up before the token is valid. Poll up to 3 min.
    info "${BOLD}Waiting for the bootstrap token to be accepted by Authentik...${CL}"
    local i
    for i in $(seq 1 36); do
        if authentik-manager test >/dev/null 2>&1; then
            info "  ${GN}✓${CL} token accepted"
            return 0
        fi
        [[ $i -eq 36 ]] && die "authentik-manager test never succeeded after 3 min — token not bound to akadmin. Remediation: cd src/foundation/identity && ./update.sh identity"
        sleep 5
    done
}
