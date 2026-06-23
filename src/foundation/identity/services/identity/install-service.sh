#!/usr/bin/env bash
#
# TAPPaaS Identity Service — Install (ADR-006 Phase 4, issue #56).
#
# Runs when a module declares `dependsOn: ["identity:identity"]` — i.e. an app
# with NATIVE OIDC (e.g. Nextcloud user_oidc), as opposed to the header/forward-
# auth path (identity:accessControl). It is the OIDC counterpart of
# accessControl/install-service.sh and does NOT layer forward-auth (never stack
# the two — ADR-006 §4).
#
# Steps (all idempotent):
#   1. If the module opts in (identity.providesAdminRole), ensure the opt-in
#      <module>-admins group exists (group-ensure). The baseline role groups
#      (user/admin/root) are owned + reconciled by people-manager (run at
#      foundation install and on update); this script no longer ensures them.
#   2. Authentik: oidc-app-ensure — create/update an OAuth2/OpenID Provider +
#      Application for the module; read back client_id/client_secret.
#   3. Access gate: bind the allowed groups to the Application (app-bind-groups)
#      — MANDATORY (Authentik is allow-all without a binding; ADR-006 §5).
#   4. Write OIDC_CLIENT_ID / OIDC_CLIENT_SECRET / OIDC_DISCOVERY_URI into the
#      module VM's secrets env file, and (if declared) restart its configure
#      service so the app registers the provider.
#
# Access gate (ALLOW_GROUPS): the people-manager role groups user/admin/root
# (root = the platform superuser). A module that opts into its own admin role
# adds <module>-admins on top.
#
# Module JSON contract (object `identity`, all optional — defaults suit Nextcloud):
#   identity.providesAdminRole   bool   create <module>-admins (default false)
#   identity.oidcRedirectPaths   [str]  callback paths (default ["/apps/user_oidc/code"])
#   identity.scopes              [str]  OIDC scope-mapping names (default openid/email/profile)
#   identity.secretsEnv          str    path on the VM (default /etc/secrets/<base>.env)
#   identity.configureService    str    systemd unit to restart after writing env (default "")
#
# Usage: install-service.sh <effective-module-name> [--dry-run]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

# Shared Authentik credential bootstrap helper (issue #312).
_IDENTITY_SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/ensure-authentik-creds.sh disable=SC1091
. "${_IDENTITY_SVC_DIR}/../../lib/ensure-authentik-creds.sh"

AUTHENTIK_MANAGER="${AUTHENTIK_MANAGER:-authentik-manager}"
DRY_RUN=0

MODULE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        -*) die "unknown option: $1" ;;
        *) if [[ -z "${MODULE}" ]]; then MODULE="$1"; shift; else die "unexpected arg: $1"; fi ;;
    esac
done
[[ -n "${MODULE}" ]] || die "Usage: $0 <effective-module-name> [--dry-run]"

MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
[[ -f "${MODULE_JSON}" ]] || die "module config not found: ${MODULE_JSON}"
# Load this module's config explicitly (normalized flat) — robust to arg order,
# since common-install-routines only auto-loads $1 which may be a flag.
JSON="$(normalize_module_config < "${MODULE_JSON}")"

VMNAME="$(get_config_value 'vmname' '')"
ZONE0="$(get_config_value 'zone0' '')"
PROXY_DOMAIN="$(get_config_value 'proxyDomain' '')"
VARIANT="$(get_config_value 'variant' '')"
# Derive proxyDomain when a module doesn't hardcode it — the Nextcloud pattern
# ("no proxyDomain is hardcoded"; the public domain is <vmname>.<domain>). Mirror
# network:proxy's derivation so the OIDC redirect URIs match the reverse proxy's
# domain, taking <domain> from the module's variant registry (default variant for
# unsuffixed installs) to stay correct under ADR-005.
if [[ -z "${PROXY_DOMAIN}" ]]; then
    _DERIVED_DOMAIN="$(get_variant_config "${VARIANT}" 2>/dev/null | jq -r '.domain // empty')"
    [[ -n "${_DERIVED_DOMAIN}" && -n "${VMNAME}" ]] && PROXY_DOMAIN="${VMNAME}.${_DERIVED_DOMAIN}"
fi
[[ -n "${VMNAME}" && -n "${ZONE0}" && -n "${PROXY_DOMAIN}" ]] \
    || die "module ${MODULE} must set vmname, zone0, proxyDomain (or set the variant domain so it derives as <vmname>.<domain>)"

# identity.* contract (with Nextcloud-friendly defaults).
PROVIDES_ADMIN="$(echo "${JSON}" | jq -r '.identity.providesAdminRole // false')"
mapfile -t REDIRECT_PATHS < <(echo "${JSON}" | jq -r '(.identity.oidcRedirectPaths // ["/apps/user_oidc/code"])[]')
mapfile -t OIDC_SCOPES   < <(echo "${JSON}" | jq -r '(.identity.scopes // [])[]')
CONFIGURE_SERVICE="$(echo "${JSON}" | jq -r '.identity.configureService // ""')"

# The base module name (strip the -<variant> suffix) — used for the VM secrets
# path and the module-admin group, so a variant install shares the base name.
MODULE_BASE="${MODULE}"
[[ -n "${VARIANT}" && "${MODULE}" == *"-${VARIANT}" ]] && MODULE_BASE="${MODULE%-"${VARIANT}"}"
SECRETS_ENV="$(echo "${JSON}" | jq -r --arg d "/etc/secrets/${MODULE_BASE}.env" '.identity.secretsEnv // $d')"
# Default the configure unit to the convention <base>-configure-oidc.service so a
# module needn't declare it (Nextcloud ships nextcloud-configure-oidc.service).
# Restart is best-effort (warns if absent → applies on next rebuild/boot).
[[ -z "${CONFIGURE_SERVICE}" ]] && CONFIGURE_SERVICE="${MODULE_BASE}-configure-oidc.service"

SLUG="${MODULE}"                                  # unique per variant
UPSTREAM="${VMNAME}.${ZONE0}.internal"

# The OIDC issuer/discovery lives on the single identity instance, at the
# DEFAULT variant's domain (one Authentik for the whole cluster).
DEFAULT_DOMAIN="$(get_variant_config '' | jq -r '.domain')"
[[ -n "${DEFAULT_DOMAIN}" && "${DEFAULT_DOMAIN}" != "null" ]] || die "default environment domain not set (config/environments/<env>.json)"
DISCOVERY_URI="https://identity.${DEFAULT_DOMAIN}/application/o/${SLUG}/.well-known/openid-configuration"

info "${BOLD}identity:identity (OIDC): wiring ${BL}${MODULE}${CL}"
info "  scope '${VARIANT:-<default>}'  app/slug '${SLUG}'  upstream ${UPSTREAM}"

command -v "${AUTHENTIK_MANAGER%% *}" >/dev/null 2>&1 || [[ -x "${AUTHENTIK_MANAGER}" ]] \
    || die "authentik-manager not available (rebuild opnsense-controller)"
ensure_authentik_credentials

# ── Step 1: access groups (+ opt-in module-admin) ───────────────────────────
# The baseline role groups user/admin/root are reconciled by people-manager
# (foundation install + update) — NOT here. As a safety net we ensure they exist
# via group-ensure (idempotent), with no dependency on configuration.json.
# `root` is the platform superuser (replaces the old tappaas-installers group).
declare -a ALLOW_GROUPS=("user" "admin" "root")
if [[ "${DRY_RUN}" -eq 0 ]]; then
    for g in "${ALLOW_GROUPS[@]}"; do
        ${AUTHENTIK_MANAGER} group-ensure "${g}" >/dev/null 2>&1 \
            || warn "group-ensure ${g} failed; assuming people-manager already created it"
    done
fi
if [[ "${PROVIDES_ADMIN}" == "true" ]]; then
    ADMIN_GROUP="${MODULE_BASE}-admins"
    info "  module declares an admin role → ensuring group ${ADMIN_GROUP}"
    [[ "${DRY_RUN}" -eq 0 ]] && ${AUTHENTIK_MANAGER} group-ensure "${ADMIN_GROUP}" \
        --attr "tappaas.role=module-admin" --attr "tappaas.module=${MODULE_BASE}" >/dev/null
    ALLOW_GROUPS=("user" "admin" "${ADMIN_GROUP}" "root")
fi

# ── Step 3: OIDC provider + application ──────────────────────────────────────
declare -a oidc_args=("oidc-app-ensure" "${SLUG}" "--name" "${MODULE}" \
    "--description" "TAPPaaS OIDC for ${MODULE} (ADR-006)" "--show-secret")
for p in "${REDIRECT_PATHS[@]}"; do oidc_args+=("--redirect-uri" "https://${PROXY_DOMAIN}${p}"); done
for s in "${OIDC_SCOPES[@]}"; do oidc_args+=("--scope" "${s}"); done

if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "  ${YW}[dry-run]${CL} oidc: ${AUTHENTIK_MANAGER} ${oidc_args[*]}"
    info "  ${YW}[dry-run]${CL} bind groups: ${ALLOW_GROUPS[*]}"
    info "  ${YW}[dry-run]${CL} write ${SECRETS_ENV} on ${UPSTREAM} (OIDC_CLIENT_ID/SECRET/DISCOVERY_URI)"
    info "  ${YW}[dry-run]${CL} discovery: ${DISCOVERY_URI}"
    [[ -n "${CONFIGURE_SERVICE}" ]] && info "  ${YW}[dry-run]${CL} restart ${CONFIGURE_SERVICE} on ${UPSTREAM}"
    exit 0
fi

info "  Authentik: ensuring OIDC app/provider '${SLUG}'"
OIDC_OUT="$(${AUTHENTIK_MANAGER} "${oidc_args[@]}")" || die "oidc-app-ensure failed for ${SLUG}"
CLIENT_ID="$(echo "${OIDC_OUT}" | awk -F'client_id=' '/client_id=/{print $2; exit}' | tr -d '[:space:]')"
CLIENT_SECRET="$(echo "${OIDC_OUT}" | awk -F'client_secret=' '/client_secret=/{print $2; exit}' | tr -d '[:space:]')"
[[ -n "${CLIENT_ID}" && -n "${CLIENT_SECRET}" ]] || die "could not read client_id/secret from oidc-app-ensure output"

# ── Step 4: access gate (MANDATORY — allow-all without it) ────────────────────
info "  Authentik: binding access groups (${ALLOW_GROUPS[*]})"
declare -a bind_args=("app-bind-groups" "${SLUG}")
for g in "${ALLOW_GROUPS[@]}"; do bind_args+=("--group" "${g}"); done
${AUTHENTIK_MANAGER} "${bind_args[@]}" || die "app-bind-groups failed for ${SLUG}"

# ── Step 5: write the OIDC client config onto the module VM ──────────────────
# 5a — verify the discovery URI is reachable from the module VM before writing.
# Writing unreachable OIDC vars causes silent worker crash loops in apps that
# eagerly initialise SSO on startup. Fail here rather than produce a broken
# deployment (issue #369).
info "  VM: verifying OIDC discovery URI reachable from ${UPSTREAM}"
if ! ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${UPSTREAM}" \
    "curl --silent --max-time 5 --output /dev/null --fail '${DISCOVERY_URI}' 2>/dev/null"; then
    die "OIDC discovery URI unreachable from ${UPSTREAM}: ${DISCOVERY_URI} — add a firewall rule allowing ${VMNAME} to reach Authentik, then re-run"
fi

# 5b — merge-write: strip any prior OIDC_ lines, append new values. Preserves
# co-managed keys (e.g. LITELLM_MASTER_KEY) that other services write to the
# same secrets file (issue #369).
# Stage through a temp file in the same dir and atomically mv into place: never
# read and truncate the secrets file in one pipeline (a `grep file | tee file`
# race could let tee truncate before grep reads, silently dropping the very
# co-managed keys we mean to preserve). The merge runs in a single `sudo sh -c`.
# A freshly (re)created VM reuses the hostname with a NEW host key; clear any
# stale known_hosts entry first so StrictHostKeyChecking=accept-new doesn't reject
# the CHANGED key (same approach as update-os.sh update_ssh_known_hosts).
ssh-keygen -R "${UPSTREAM}" >/dev/null 2>&1 || true
info "  VM: merging OIDC vars into ${SECRETS_ENV} on ${UPSTREAM} (mode 600)"
ENV_CONTENT="$(printf 'OIDC_CLIENT_ID=%s\nOIDC_CLIENT_SECRET=%s\nOIDC_DISCOVERY_URI=%s\n' \
    "${CLIENT_ID}" "${CLIENT_SECRET}" "${DISCOVERY_URI}")"
if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${UPSTREAM}" \
    "sudo install -d -m 700 \"\$(dirname '${SECRETS_ENV}')\" && \
     sudo sh -c 'umask 077; t=\$(mktemp \"\$(dirname \"${SECRETS_ENV}\")/.oidc.XXXXXX\") || exit 1; \
       { [ -f \"${SECRETS_ENV}\" ] && grep -v \"^OIDC_\" \"${SECRETS_ENV}\"; \
         printf \"%s\" \"${ENV_CONTENT}\"; } > \"\$t\" && \
       chmod 600 \"\$t\" && mv -f \"\$t\" \"${SECRETS_ENV}\"'"; then
    info "  ${GN}✓${CL} merged OIDC vars into ${SECRETS_ENV}"
else
    die "failed to write ${SECRETS_ENV} on ${UPSTREAM} (is the VM up and SSH reachable?)"
fi

if [[ -n "${CONFIGURE_SERVICE}" ]]; then
    info "  VM: restarting ${CONFIGURE_SERVICE}"
    ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${UPSTREAM}" \
        "sudo systemctl restart '${CONFIGURE_SERVICE}'" \
        || warn "could not restart ${CONFIGURE_SERVICE} — it applies on next nixos-rebuild/boot"
fi

info "  ${GN}✓${CL} identity:identity (OIDC) wired for ${MODULE}"
info "      users in ${ALLOW_GROUPS[*]} can log in at https://${PROXY_DOMAIN}/ via Authentik;"
info "      accounts are provisioned in ${MODULE} on first login (JIT)"
