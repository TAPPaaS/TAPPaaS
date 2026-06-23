#!/usr/bin/env bash
#
# TAPPaaS Identity Access Control Service — Install (issue #45).
#
# Runs when a module declares `dependsOn: ["identity:accessControl"]`. The
# module's network:proxy install-service must have run first (in dependsOn
# order) so the Caddy reverse + handler already exist; this script then layers
# Authentik forward-auth on top:
#
#   1. Authentik: create/update a Proxy Provider + Application for the module
#      and attach the Provider to the embedded outpost (idempotent).
#   2. Caddy: flip the existing handler's ForwardAuth to 1 so unauthenticated
#      requests get redirected through the global Authentik outpost endpoint
#      (the global AuthProvider + 12 X-Authentik-* headers are configured
#      once by identity/install.sh).
#
# Pre-requirements (set up by identity/install.sh):
#   • Caddy global AuthProvider configured (AuthToDomain/Port/Uri/Tls + CopyHeaders)
#
# ~/.authentik-credentials.txt (url= + token=) is bootstrapped on demand: if it
# is missing or its token is stale, ensure_authentik_credentials re-fetches it
# from the identity VM, so this install self-heals on a fresh cicd (issue #312).
#
# Usage: install-service.sh <module-name>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

# Shared Authentik credential bootstrap helper (issue #312).
_ACCESSCONTROL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/ensure-authentik-creds.sh disable=SC1091
. "${_ACCESSCONTROL_DIR}/../../lib/ensure-authentik-creds.sh"

MODULE="${1:-}"
[[ -n "${MODULE}" ]] || die "Usage: $0 <module-name>"

MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
[[ -f "${MODULE_JSON}" ]] || die "module config not found: ${MODULE_JSON}"

VMNAME="$(get_config_value 'vmname' '')"
ZONE0="$(get_config_value 'zone0' '')"
PROXY_DOMAIN="$(get_config_value 'proxyDomain' '')"
PROXY_PORT="$(get_config_value 'proxyPort' '')"
# Must match the description network:proxy/install-service.sh sets on the
# handler — that's the natural key we use to locate the row.
DESCRIPTION="TAPPaaS: ${MODULE}"

[[ -n "${VMNAME}" && -n "${ZONE0}" && -n "${PROXY_DOMAIN}" && -n "${PROXY_PORT}" ]] \
    || die "module ${MODULE} must set vmname, zone0, proxyDomain, proxyPort"

# The upstream is the consumer VM's internal DNS name in its primary zone.
UPSTREAM="${VMNAME}.${ZONE0}.internal"

info "${BOLD}identity:accessControl: wiring forward-auth for ${BL}${MODULE}${CL}"
info "  external: https://${PROXY_DOMAIN}    upstream: ${UPSTREAM}:${PROXY_PORT}"

# ── Step 1: Authentik application + provider, attached to embedded outpost ──

if ! command -v authentik-manager >/dev/null 2>&1; then
    die "authentik-manager not in PATH (rebuild opnsense-controller)"
fi
# Bootstrap the cicd-side Authentik credentials on demand (missing or stale
# token → re-fetch from the identity VM). die()s with remediation if the VM
# cannot supply the token (issue #312).
ensure_authentik_credentials

info "  Authentik: ensuring Proxy app/provider '${MODULE}' (attached to embedded outpost)"
authentik-manager proxy-app-ensure "${MODULE}" \
    --name "${MODULE}" \
    --external-host "https://${PROXY_DOMAIN}" \
    --description "TAPPaaS forward-auth for ${MODULE} (#45)" \
    --attach-outpost || die "authentik-manager proxy-app-ensure failed for ${MODULE}"

# ── Step 2: Flip ForwardAuth on the existing Caddy handler ──────────────────

# Flip ForwardAuth on the existing handler directly via the OPNsense API.
# (caddy-manager hits the oxl-client port-probe SSL quirk now that Caddy
# serves *.test.tapaas.org wildcards on :443 — same issue noted under #254
# Phase G. Direct curl bypasses the probe.)
OPNSENSE_CREDS="${HOME}/.opnsense-credentials.txt"
[[ -f "$OPNSENSE_CREDS" ]] || die "OPNsense credentials file missing: $OPNSENSE_CREDS"
OPNSENSE_KEY="$(grep '^key=' "$OPNSENSE_CREDS" | cut -d= -f2-)"
OPNSENSE_SECRET="$(grep '^secret=' "$OPNSENSE_CREDS" | cut -d= -f2-)"
OPNSENSE_AUTH="${OPNSENSE_KEY}:${OPNSENSE_SECRET}"
CADDY_API="https://firewall.mgmt.internal:8443/api/caddy"

info "  Caddy: looking up existing handler for ${PROXY_DOMAIN}"
HANDLE_UUID="$(curl -ksS -u "$OPNSENSE_AUTH" "${CADDY_API}/ReverseProxy/searchHandle" \
    | jq -r --arg d "$DESCRIPTION" '.rows[] | select(.description==$d) | .uuid' | head -1)"
[[ -n "$HANDLE_UUID" ]] \
    || die "no Caddy handler with description '${DESCRIPTION}' (network:proxy install-service.sh runs first?)"

info "  Caddy: enabling ForwardAuth=1 on handler ${HANDLE_UUID:0:8}..."
curl -ksS -u "$OPNSENSE_AUTH" -X POST "${CADDY_API}/ReverseProxy/setHandle/${HANDLE_UUID}" \
    -H 'Content-Type: application/json' \
    -d '{"handle":{"ForwardAuth":"1"}}' | jq -r .result >/dev/null \
    || die "Failed to set ForwardAuth on handler for ${MODULE}"

info "  Caddy: reconfiguring + reloading"
curl -ksS -u "$OPNSENSE_AUTH" -X POST "${CADDY_API}/service/reconfigure" | jq -r .status >/dev/null
ssh -o StrictHostKeyChecking=accept-new "root@firewall.mgmt.internal" \
    "/bin/sh -c 'configctl caddy reload'" >/dev/null 2>&1 || true

info "  ${GN}✓${CL} identity:accessControl wired for ${MODULE}"
info "      log in at https://${PROXY_DOMAIN}/ — Authentik gates the request,"
info "      then Caddy proxies to ${UPSTREAM}:${PROXY_PORT} with X-Authentik-* headers"
