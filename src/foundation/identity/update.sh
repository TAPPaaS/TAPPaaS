#!/usr/bin/env bash
#
# TAPPaaS Identity VM update / install (idempotent).
#
# Beyond reading config, this script does Phase B of issue #45 — the one-time
# Authentik+Caddy "global" wiring needed before any module's identity:
# accessControl can attach a forward-auth app to the embedded outpost:
#
#   1. Wait for Authentik's API to come up on the identity VM
#   2. Read AUTHENTIK_BOOTSTRAP_TOKEN from /etc/secrets/authentik.env (created
#      on first boot by identity.nix's generate-authentik-secrets service)
#   3. Persist it to ~/.authentik-credentials.txt on the cicd (mode 600) so
#      authentik-manager can talk to Authentik
#   4. Configure Caddy's global AuthProvider = Authentik, point it at the
#      identity outpost, and register the 12 X-Authentik-* copy-headers
#      operators previously added by hand in the GUI
#   5. Set the embedded outpost's authentik_host to the public identity URL
#   6. Create/update the identity self-application + Proxy Provider and attach
#      it to the embedded outpost (so https://identity.<domain>/outpost.* works)
#
# Re-running is safe: every step is reconcile-in-place.
#
# Usage: ./update.sh <vmname>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

# Shared Authentik credential bootstrap helper (issue #312) — single source of
# truth for materialising ~/.authentik-credentials.txt from the identity VM.
IDENTITY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ensure-authentik-creds.sh disable=SC1091
. "${IDENTITY_DIR}/lib/ensure-authentik-creds.sh"

VMNAME="$(get_config_value 'vmname' "$1")"
# F5 (defensive): vmid is display-only here; on a first install it may not be
# written back to the module config yet, so default it rather than abort under
# set -e (mirrors logging/update.sh).
VMID="$(get_config_value 'vmid' 'unknown')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
HANODE="$(get_config_value 'HANode' "$(get_default_ha_node "$NODE")")"

CONFIG_FILE="${CONFIG_DIR}/configuration.json"
# Domain from the default environment (config/environments/<env>.json via
# get_variant_config), falling back to legacy configuration.json .tappaas.domain.
DOMAIN="$(jq -r '.domain // empty' <<<"$(get_variant_config "" 2>/dev/null || echo '{}')")"
[[ -z "$DOMAIN" ]] && DOMAIN="$(jq -r '.tappaas.domain // empty' "$CONFIG_FILE" 2>/dev/null)"
[[ -n "$DOMAIN" && "$DOMAIN" != CHANGE* ]] || die "No domain resolved (config/environments/ or configuration.json .tappaas.domain)"

IDENTITY_FQDN="${VMNAME}.${ZONE0NAME}.internal"
IDENTITY_PUBLIC="https://identity.${DOMAIN}"
# ~/.authentik-credentials.txt (url=http://${IDENTITY_FQDN}:9000 + token=) is
# materialised by ensure_authentik_credentials below (shared helper, #312).
FIREWALL_FQDN="firewall.mgmt.internal"
OPNSENSE_CREDS="${HOME}/.opnsense-credentials.txt"

info "${BOLD}Post-Install / Update Configuration${CL}"
info "  VM: ${VMNAME} (VMID: ${VMID})  Node: ${NODE}  Zone: ${ZONE0NAME}"
[[ -n "${HANODE}" ]] && info "  HA Node: ${HANODE}"

# ── Phase B step 1-4: bootstrap + verify the cicd-side Authentik credentials ─
# Waits for the Authentik API, fetches AUTHENTIK_BOOTSTRAP_TOKEN from the
# identity VM, writes ~/.authentik-credentials.txt (mode 600), and polls until
# the token is accepted. Shared with accessControl/install-service.sh so a
# consumer install self-heals when the credential is missing/stale (#312).
ensure_authentik_credentials

# ── Phase B step 5-6: Caddy global AuthProvider + 12 X-Authentik-* headers ──

[[ -f "$OPNSENSE_CREDS" ]] || die "OPNsense credentials file missing: $OPNSENSE_CREDS"
OPNSENSE_KEY="$(grep '^key=' "$OPNSENSE_CREDS" | cut -d= -f2-)"
OPNSENSE_SECRET="$(grep '^secret=' "$OPNSENSE_CREDS" | cut -d= -f2-)"
OPNSENSE_AUTH="${OPNSENSE_KEY}:${OPNSENSE_SECRET}"
OPNSENSE_API="https://${FIREWALL_FQDN}:8443/api/caddy"

info "${BOLD}Configuring Caddy global AuthProvider = Authentik${CL}"
# NB: AuthToTls (OptionField) rejects every value form I tried — "http://",
# "http", "1" all → "Option [] not in list" (caddy/general/set bug?). The
# default is "http://" which is what we want for the Authentik outpost on the
# internal mgmt network anyway. Skip it; leave the default.
# `general/set` is partial-replace (doesn't wipe missing fields), so a second
# call below for CopyHeaders won't clobber what we set here.
curl -ksS -u "$OPNSENSE_AUTH" -X POST "${OPNSENSE_API}/general/set" \
    -H 'Content-Type: application/json' \
    -d "{\"caddy\":{\"general\":{\
\"AuthProvider\":\"authentik\",\
\"AuthToDomain\":\"${IDENTITY_FQDN}\",\
\"AuthToPort\":\"9000\",\
\"AuthToUri\":\"/outpost.goauthentik.io/auth/caddy\"\
}}}" | jq -r .result >/dev/null || die "Failed to set Caddy AuthProvider"
info "  ${GN}✓${CL} AuthProvider set → ${IDENTITY_FQDN}:9000 /outpost.goauthentik.io/auth/caddy"

# The 12 X-Authentik-* headers per the issue. We add each only if absent
# (HeaderType is the natural key — case-sensitive, must match Authentik's).
AUTHENTIK_HEADERS=(
    X-Authentik-Username X-Authentik-Groups X-Authentik-Entitlements
    X-Authentik-Email X-Authentik-Name X-Authentik-Uid X-Authentik-Jwt
    X-Authentik-Meta-Jwks X-Authentik-Meta-Outpost X-Authentik-Meta-Provider
    X-Authentik-Meta-App X-Authentik-Meta-Version
)
info "${BOLD}Ensuring 12 X-Authentik-* copy-headers (Caddy header model)${CL}"
# Snapshot existing rows once
EXISTING_HEADERS="$(curl -ksS -u "$OPNSENSE_AUTH" "${OPNSENSE_API}/ReverseProxy/searchHeader")"
declare -a HEADER_UUIDS=()
for h in "${AUTHENTIK_HEADERS[@]}"; do
    uuid="$(echo "$EXISTING_HEADERS" | jq -r --arg h "$h" '.rows[] | select(.HeaderType==$h) | .uuid' | head -1)"
    if [[ -z "$uuid" || "$uuid" == "null" ]]; then
        body="$(printf '{"header":{"enabled":"1","HeaderUpDown":"header_up","HeaderType":"%s","HeaderValue":"","HeaderReplace":"","description":"TAPPaaS forward-auth header (#45)"}}' "$h")"
        uuid="$(curl -ksS -u "$OPNSENSE_AUTH" -X POST "${OPNSENSE_API}/ReverseProxy/addHeader" \
            -H 'Content-Type: application/json' -d "$body" | jq -r '.uuid // empty')"
        [[ -n "$uuid" ]] || die "Failed to create Caddy header ${h}"
        info "    + ${h} (new uuid=${uuid:0:8})"
    fi
    HEADER_UUIDS+=("$uuid")
done

# Attach all 12 UUIDs to general.CopyHeaders (comma-separated; idempotent set).
COPY_HEADERS_CSV="$(IFS=,; echo "${HEADER_UUIDS[*]}")"
curl -ksS -u "$OPNSENSE_AUTH" -X POST "${OPNSENSE_API}/general/set" \
    -H 'Content-Type: application/json' \
    -d "{\"caddy\":{\"general\":{\"CopyHeaders\":\"${COPY_HEADERS_CSV}\"}}}" | jq -r .result >/dev/null \
    || die "Failed to attach CopyHeaders"
info "  ${GN}✓${CL} CopyHeaders attached (${#HEADER_UUIDS[@]} headers)"

info "${BOLD}Applying Caddy config${CL}"
curl -ksS -u "$OPNSENSE_AUTH" -X POST "${OPNSENSE_API}/service/reconfigure" | jq -r .status >/dev/null
ssh -o StrictHostKeyChecking=accept-new "root@${FIREWALL_FQDN}" "/bin/sh -c 'configctl caddy reload'" >/dev/null 2>&1 || true

# ── Phase B step 7-8: outpost + identity self-app ───────────────────────────

# Report any drift of the identity self-config (app launch URL, proxy
# external_host, oauth2 redirect_uris, outpost authentik_host) against the
# expected public host BEFORE converging it, so a reconcile surfaces what a
# domain change left stale (#474). Non-fatal: the ensures below fix it.
info "${BOLD}Checking identity self-config for drift (expected ${IDENTITY_PUBLIC})${CL}"
authentik-manager check-self-config --external-host "${IDENTITY_PUBLIC}" \
    || info "  drift detected — the steps below converge it to ${IDENTITY_PUBLIC}"

info "${BOLD}Configuring the Authentik embedded outpost (authentik_host=${IDENTITY_PUBLIC})${CL}"
authentik-manager outpost-set-authentik-host "${IDENTITY_PUBLIC}"

info "${BOLD}Registering the identity self-app (so the outpost endpoint works on identity.<domain>)${CL}"
authentik-manager proxy-app-ensure identity \
    --name identity \
    --external-host "${IDENTITY_PUBLIC}" \
    --description "TAPPaaS identity self-app (#45)" \
    --attach-outpost

# ── ADR-007: role groups are owned by people-manager ────────────────────────
# The role groups (user/admin/root) and the team group `users` are reconciled
# into Authentik by `people-manager sync` (run at foundation install and on
# update from config/people/). This script no longer ensures them here.

# ── Authentik admin rights for the site owner (issue #476) ──────────────────
# The ONLY thing that grants the Authentik admin UI is membership in a group
# with is_superuser — TAPPaaS's own `admin`/`root` ROLES are labels passed to
# apps and confer nothing here. So adopt Authentik's built-in "authentik Admins"
# group and put the site owner in it, and day-2 user administration stops
# needing the akadmin break-glass login.
#
# Two halves, both idempotent and both safe to re-run:
#   Authentik side  — group-ensure --superuser ADOPTS the built-in group, and
#                     re-creates it WITH is_superuser if it was deleted. Without
#                     this, people-manager's ensure-group would recreate a plain
#                     group of the same name and the grant would silently become
#                     a no-op.
#   config/people   — a FRESH install inherits the group + membership from
#                     people-manager's minimal-org bootstrap (which runs later,
#                     in rest-of-foundation.sh). An EXISTING install has neither,
#                     so add them here through the manager verbs and converge the
#                     membership now.
AK_ADMIN_GROUP="authentik Admins"

info "${BOLD}Ensuring the Authentik admin group '${AK_ADMIN_GROUP}' (is_superuser)${CL}"
authentik-manager group-ensure "${AK_ADMIN_GROUP}" --superuser >/dev/null \
    || warn "  group-ensure '${AK_ADMIN_GROUP}' failed — the site owner will not get Authentik admin rights"

# Site owner = the owner USER of the organization that owns the default
# environment (site.json .owner is that same organization). People files are the
# source of truth; an empty/absent people tree means a fresh install, where the
# bootstrap does this instead — so skip quietly rather than guess.
PEOPLE_DIR="${TAPPAAS_CONFIG:-${CONFIG_DIR}}/people"
if [[ -d "${PEOPLE_DIR}/organizations" ]]; then
    # NB: every read is `|| true`-guarded — under `set -e` a jq that finds no
    # file, or a `[[ ]] && assign` whose test is false, would abort the install.
    OWNER_ORG="$(get_site_value '.owner' || true)"
    if [[ -z "${OWNER_ORG}" ]]; then
        DEFAULT_ENV="$(get_site_value '.defaultEnvironment' || true)"
        OWNER_ORG="$(jq -r '.ownerOrg // empty' \
            "${CONFIG_DIR}/environments/${DEFAULT_ENV}.json" 2>/dev/null || true)"
    fi
    OWNER_USER=""
    if [[ -n "${OWNER_ORG}" ]]; then
        OWNER_USER="$(jq -r '.owner // empty' \
            "${PEOPLE_DIR}/organizations/${OWNER_ORG}.json" 2>/dev/null || true)"
    fi

    if [[ -z "${OWNER_USER}" ]]; then
        warn "  no site-owner user resolved (site.json .owner → organizations/<org>.json .owner) — skipping the ${AK_ADMIN_GROUP} grant"
    else
        info "${BOLD}Granting Authentik admin to the site owner '${OWNER_USER}'${CL}"
        # Config first, so the membership survives every later reconcile.
        if [[ ! -f "${PEOPLE_DIR}/groups/${AK_ADMIN_GROUP}.json" ]]; then
            people-manager group add "${AK_ADMIN_GROUP}" \
                --displayName "Authentik Admins" --type access-set --ownerOrg "${OWNER_ORG}" \
                || warn "  people-manager group add '${AK_ADMIN_GROUP}' failed"
        fi
        people-manager user modify "${OWNER_USER}" --add-groups "${AK_ADMIN_GROUP}" \
            || warn "  people-manager user modify ${OWNER_USER} --add-groups failed"
        # Then converge just this membership in Authentik. A targeted call, not a
        # full `reconcile --apply`: a module update must not push whatever else an
        # operator has staged in config/people.
        if authentik-manager get-user --name "${OWNER_USER}" | jq -e '. != null' >/dev/null 2>&1; then
            authentik-manager add-member --user "${OWNER_USER}" --group "${AK_ADMIN_GROUP}" >/dev/null \
                && info "  ${GN}✓${CL} ${OWNER_USER} ∈ ${AK_ADMIN_GROUP}" \
                || warn "  add-member ${OWNER_USER} → ${AK_ADMIN_GROUP} failed"
        else
            info "  ${OWNER_USER} not in Authentik yet — 'people-manager reconcile --apply' will create it and apply the membership"
        fi
    fi
fi

echo
info "${BOLD}Installation Complete${CL}"
info "  VM: ${VMNAME} (VMID: ${VMID})  Node: ${NODE}  Zone: ${ZONE0NAME}"
[[ -n "${HANODE}" ]] && info "  HA Node: ${HANODE}"
info "  Authentik UI : ${IDENTITY_PUBLIC}"
info "  Admin login  : the site owner (member of '${AK_ADMIN_GROUP}') — break-glass: akadmin / (see /etc/secrets/authentik.env on ${IDENTITY_FQDN}: AUTHENTIK_BOOTSTRAP_PASSWORD)"
info "  Per-app SSO  : every consumer with dependsOn: identity:accessControl gets forward-auth wired automatically"
