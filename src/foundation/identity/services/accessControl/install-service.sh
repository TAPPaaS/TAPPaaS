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
# oidc_public_domain — the shared "is this module published, and where?"
# predicate (#698); identity:identity and its test-service read the same one.
# shellcheck source=../../lib/oidc-consumer.sh disable=SC1091
. "${_ACCESSCONTROL_DIR}/../../lib/oidc-consumer.sh"
# shellcheck source=../../lib/app-tile.sh
. "${_ACCESSCONTROL_DIR}/../../lib/app-tile.sh"

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

ENVIRONMENT="$(get_config_value 'environment' '')"
# The same predicate identity:identity uses, from the same lib: a module that
# does not hardcode proxyDomain is still published at <vmname>.<environment
# domain>, and the forward-auth we layer on must name the domain the handler was
# actually created for. Deriving it is what keeps the skip below honest —
# without it a published module whose domain is only derived would look
# unpublished here and be left EXPOSED behind a handler with ForwardAuth off
# (#698).
MODULE_NORM="$(normalize_module_config < "${MODULE_JSON}")"
PROXY_DOMAIN="$(oidc_public_domain "${VMNAME}" "${ENVIRONMENT}" "${MODULE_NORM}")"
# The gate's Authentik slug: <module>, or <module>-gate when the module's own
# OIDC app (identity:identity) holds <module> (#806).
GATE_SLUG="$(accesscontrol_gate_slug "${MODULE}" "${MODULE_NORM}")"

[[ -n "${VMNAME}" && -n "${ZONE0}" ]] \
    || die "module ${MODULE} must set vmname and zone0"

# No domain anywhere means network:proxy published nothing (it skips on the same
# fact, #438) — an internal-only environment such as mgmt, reached at
# <vmname>.<zone>.internal. There is no handler to flip ForwardAuth on and
# nothing exposed to protect, so skip instead of failing the module update that
# dependsOn us (#698). A domain WITH no proxyPort is a real misconfiguration:
# the module says it is published but not where to forward, so that still dies.
if [[ -z "${PROXY_DOMAIN}" ]]; then
    warn "Environment '${ENVIRONMENT:-default}' publishes no domain, so '${MODULE}' is reachable only at ${VMNAME}.${ZONE0}.internal"
    warn "  Nothing is exposed through the proxy — skipping forward-auth for it."
    warn "  To protect a published instance, set proxyDomain on the module, or give the environment a domains.primary."
    exit 0
fi

# A name with no public DNS record is not published either (#778):
# network:proxy gives it no Caddy route, so there is no handler to put
# ForwardAuth on and nothing exposed to protect — the same verdict, from the same
# resolver, as identity:identity. Skip, and withdraw a proxy app left from when
# it was published, instead of dying on the missing handler (found by the
# identity deep test on hrossen, 2026-10-07).
if oidc_domain_unpublished "${PROXY_DOMAIN}"; then
    warn "${PROXY_DOMAIN} is not published (no public DNS record) — no route, so no forward-auth for '${MODULE}'"
    warn "  It is reachable only at ${VMNAME}.${ZONE0}.internal. Create the public record and re-run update to protect it."
    if command -v authentik-manager >/dev/null 2>&1 && [[ -f "${HOME}/.authentik-credentials.txt" ]]; then
        authentik-manager app-delete "${GATE_SLUG}" --only-proxy >/dev/null 2>&1 || true
    fi
    exit 0
fi
[[ -n "${PROXY_PORT}" ]] \
    || die "module ${MODULE} is published at ${PROXY_DOMAIN} but sets no proxyPort — forward-auth has no upstream to protect"

# The upstream is the consumer VM's internal DNS name in its primary zone.
UPSTREAM="${VMNAME}.${ZONE0}.internal"

debug "${BOLD}identity:accessControl: wiring forward-auth for ${BL}${MODULE}${CL}"
debug "  external: https://${PROXY_DOMAIN}    upstream: ${UPSTREAM}:${PROXY_PORT}"

# ── Step 1: Authentik application + provider, attached to embedded outpost ──

if ! command -v authentik-manager >/dev/null 2>&1; then
    die "authentik-manager not in PATH (rebuild opnsense-controller)"
fi
# Bootstrap the cicd-side Authentik credentials on demand (missing or stale
# token → re-fetch from the identity VM). die()s with remediation if the VM
# cannot supply the token (issue #312).
ensure_authentik_credentials

# Next to an OIDC app the gate moves to <module>-gate and is hidden: the OIDC
# app is the module's tile. A proxy app left under <module> from before the
# module had OIDC is removed, so identity:identity can create its app there.
# --only-proxy: never the OIDC app itself.
# The gate is the module's tile unless an OIDC app is: then it is hidden and
# keeps its slug as its name.
declare -a gate_args=(--name "${GATE_SLUG}")
if [[ "${GATE_SLUG}" == "${MODULE}" ]]; then
    _mjson="$(normalize_module_config < "${MODULE_JSON}")"
    gate_args=(--name "$(app_tile_name "${MODULE}" "${_mjson}")" --icon "$(app_tile_icon "${MODULE}" "${_mjson}")")
fi
if [[ "${GATE_SLUG}" != "${MODULE}" ]]; then
    authentik-manager app-delete "${MODULE}" --only-proxy >/dev/null \
        || die "could not remove the old forward-auth app '${MODULE}'"
    gate_args+=(--launch-url "blank://blank")
fi

debug "  Authentik: ensuring Proxy app/provider '${GATE_SLUG}' (attached to embedded outpost)"
authentik-manager proxy-app-ensure "${GATE_SLUG}" \
    --external-host "https://${PROXY_DOMAIN}" \
    --description "TAPPaaS forward-auth for ${MODULE} (#45)" \
    "${gate_args[@]}" \
    --attach-outpost || die "authentik-manager proxy-app-ensure failed for ${GATE_SLUG}"

# ── Step 1b: access gate (MANDATORY — an unbound app is allow-all) ───────────
# Authentik lets every user through an application with no policy binding
# (ADR-006 §5), so without this any account on the identity provider passes the
# forward-auth gate. Bind the org membership group `users`, as identity:identity
# does for OIDC apps (#805). group-ensure is the same idempotent safety net.
authentik-manager group-ensure users >/dev/null 2>&1 \
    || warn "group-ensure users failed; assuming identity-manager already created it"
_bind_out="$(authentik-manager app-bind-groups "${GATE_SLUG}" --group users)" \
    || die "app-bind-groups failed for ${GATE_SLUG} — the app would be open to every Authentik user"
debug "  ${_bind_out}"

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

debug "  Caddy: looking up existing handler for ${PROXY_DOMAIN}"
HANDLE_UUID="$(curl -ksS -u "$OPNSENSE_AUTH" "${CADDY_API}/ReverseProxy/searchHandle" \
    | jq -r --arg d "$DESCRIPTION" '.rows[] | select(.description==$d) | .uuid' | head -1)"
[[ -n "$HANDLE_UUID" ]] \
    || die "no Caddy handler with description '${DESCRIPTION}' (network:proxy install-service.sh runs first?)"

debug "  Caddy: enabling ForwardAuth=1 on handler ${HANDLE_UUID:0:8}..."
curl -ksS -u "$OPNSENSE_AUTH" -X POST "${CADDY_API}/ReverseProxy/setHandle/${HANDLE_UUID}" \
    -H 'Content-Type: application/json' \
    -d '{"handle":{"ForwardAuth":"1"}}' | jq -r .result >/dev/null \
    || die "Failed to set ForwardAuth on handler for ${MODULE}"

# The route's path handles (ADR-023) are gated like the route, except the paths
# of a rule with identityGate false — those serve machine callers that cannot
# log in. network:proxy copies the gate onto them too, but on a first install it
# runs before this, while the catch-all is not gated yet.
mapfile -t GATED_PATHS < <(normalize_module_config < "${MODULE_JSON}" \
    | jq -r '(.proxyAccess // [])[] | select(.identityGate != false) | .paths[]?')
for _p in "${GATED_PATHS[@]+"${GATED_PATHS[@]}"}"; do
    _u="$(curl -ksS -u "$OPNSENSE_AUTH" "${CADDY_API}/ReverseProxy/searchHandle" \
        | jq -r --arg d "${DESCRIPTION} ${_p}" '.rows[] | select(.description==$d) | .uuid' | head -1)"
    [[ -n "${_u}" ]] || { warn "  no path handle for ${_p} — network:proxy has not created it yet"; continue; }
    curl -ksS -u "$OPNSENSE_AUTH" -X POST "${CADDY_API}/ReverseProxy/setHandle/${_u}" \
        -H 'Content-Type: application/json' -d '{"handle":{"ForwardAuth":"1"}}' | jq -r .result >/dev/null \
        || die "Failed to set ForwardAuth on the path handle ${_p} of ${MODULE}"
done

debug "  Caddy: reconfiguring + reloading"
curl -ksS -u "$OPNSENSE_AUTH" -X POST "${CADDY_API}/service/reconfigure" | jq -r .status >/dev/null
ssh -o StrictHostKeyChecking=accept-new "root@firewall.mgmt.internal" \
    "/bin/sh -c 'configctl caddy reload'" >/dev/null 2>&1 || true

debug "  ${GN}✓${CL} identity:accessControl wired for ${MODULE}"
debug "      log in at https://${PROXY_DOMAIN}/ — Authentik gates the request,"
debug "      then Caddy proxies to ${UPSTREAM}:${PROXY_PORT} with X-Authentik-* headers"
