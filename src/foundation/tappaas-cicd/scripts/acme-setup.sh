#!/usr/bin/env bash
#
# TAPPaaS — operator-driven setup of a wildcard TLS certificate via os-acme-client
# (issue #254). Run from the cicd mothership at INSTALL.md §2.3, after the install
# chain has set up Caddy but before installing the rest of the foundation.
#
# What it does (idempotent):
#   1. Reads tappaas.domain and tappaas.email from /home/tappaas/config/configuration.json
#   2. Asks for the DNS provider (default: cloudflare) and its API credential(s),
#      OR reads them from ~/.acme-dns-credentials.txt if present (chmod 600)
#   3. Provisions an ACME account, DNS-01 validation, caddy-reload action, and
#      a wildcard cert (*.<domain> + bare apex) on the OPNsense firewall via the
#      acme-manager CLI (drives os-acme-client end-to-end)
#   4. Captures the OPNsense Trust refid of the issued cert and writes it back
#      into configuration.json as tappaas.tlsCertRefid — this is what the per-
#      module proxy install reads so each domain binds the wildcard refid via
#      Caddy's CustomCertificate (no per-module ACME, no DNS-API needed at
#      module-install time)
#
# Re-running this script is safe — every step in the chain is idempotent.
# Adding a module with proxyTls=dns01 later just reuses the stored refid.
#
# Usage:
#   acme-setup.sh                       # interactive; uses LE production
#   acme-setup.sh --staging             # use Let's Encrypt staging CA (testing)
#   acme-setup.sh --provider hetzner    # pick a different DNS provider
#   acme-setup.sh --no-save-creds       # don't offer to save creds to disk
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

CONFIG_FILE="${CONFIG_DIR}/configuration.json"
CREDS_FILE="${HOME}/.acme-dns-credentials.txt"
FIREWALL="${OPNSENSE_HOST:-firewall.mgmt.internal}"
STAGING=0
PROVIDER_OVERRIDE=""
SAVE_CREDS=1
VARIANT=""

usage() {
    cat <<'EOF'
Usage: acme-setup.sh [OPTIONS]

Set up the TAPPaaS wildcard TLS certificate via OPNsense os-acme-client.

Options:
  --staging              Use Let's Encrypt staging (untrusted certs, no rate limits)
  --provider <name>      DNS provider (default: cloudflare; e.g. desec, hetzner,
                         ovh, route53, namecheap, ... — any of the 120 os-acme-client
                         supports; also accepts the raw key like dns_cf, dns_desec)
  --no-save-creds        Don't offer to persist provider credentials to
                         ~/.acme-dns-credentials.txt
  --variant <name>       Issue the cert for a registered variant's domain and
                         store the refid under tappaas.variants[<name>] (ADR-005).
                         Default: "" (the default variant).
  --help                 Show this help

Credentials file (~/.acme-dns-credentials.txt, chmod 600), one KEY=VALUE per line:
  provider=cloudflare
  dns_cf_token=YOUR-CLOUDFLARE-API-TOKEN
  # dns_cf_account_id=...     # optional

For other providers, set the matching dns_<provider>_<field> keys (see the
os-acme-client GUI: Services → ACME Client → Challenge Types).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --staging)         STAGING=1; shift ;;
        --provider)        PROVIDER_OVERRIDE="$2"; shift 2 ;;
        --no-save-creds)   SAVE_CREDS=0; shift ;;
        --variant)         VARIANT="$2"; shift 2 ;;
        --help|-h)         usage; exit 0 ;;
        *)                 die "Unknown option: $1 (try --help)" ;;
    esac
done

[[ -f "$CONFIG_FILE" ]] || die "configuration.json not found: $CONFIG_FILE"
# Domain comes from the variant registry (ADR-005). The default variant ""
# falls back to legacy tappaas.domain on un-migrated installs.
VCFG="$(get_variant_config "${VARIANT}")" \
    || die "Variant '${VARIANT:-<default>}' not registered. Run: variant-manager add ${VARIANT} --domain <domain>"
DOMAIN="$(jq -r '.domain // empty' <<<"$VCFG")"
EMAIL="$(jq -r '.tappaas.email // empty' "$CONFIG_FILE")"
[[ -n "$DOMAIN" && "$DOMAIN" != CHANGE* ]] || die "Variant '${VARIANT:-<default>}' has no domain set (run: variant-manager add ${VARIANT} --domain <yours>)"
[[ -n "$EMAIL"  && "$EMAIL"  != CHANGE* ]] || die "tappaas.email not set"

info "${BOLD}TAPPaaS ACME setup${CL}"
info "  domain        : ${BL}${DOMAIN}${CL}"
info "  email         : ${EMAIL}"
info "  CA            : $( [[ $STAGING -eq 1 ]] && echo 'Let'"'"'s Encrypt STAGING' || echo 'Let'"'"'s Encrypt PROD' )"
info "  firewall      : ${FIREWALL}"
info "  cert subject  : *.${DOMAIN}  (+ bare apex)"
echo

# ── Source credentials: file first, then prompt for anything missing ───────

PROVIDER=""
declare -a CRED_FIELDS=()   # list of "dns_*=value" entries to pass to acme-manager

if [[ -f "$CREDS_FILE" ]]; then
    info "Reading credentials from ${CREDS_FILE}"
    # Trim, drop comments + blank lines.
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        [[ -z "$line" || "$line" != *=* ]] && continue
        key="${line%%=*}"; val="${line#*=}"
        case "$key" in
            provider) PROVIDER="$val" ;;
            dns_*)    CRED_FIELDS+=("${key}=${val}") ;;
        esac
    done < "$CREDS_FILE"
fi

# CLI --provider overrides the file
[[ -n "$PROVIDER_OVERRIDE" ]] && PROVIDER="$PROVIDER_OVERRIDE"
[[ -z "$PROVIDER" ]] && PROVIDER="cloudflare"

info "  DNS provider  : ${PROVIDER}"

if [[ ${#CRED_FIELDS[@]} -eq 0 ]]; then
    case "$PROVIDER" in
        cloudflare|dns_cf)
            read -rsp "  Cloudflare API token (Zone:DNS:Edit + Zone:Read on ${DOMAIN}): " CF_TOKEN; echo
            [[ -n "$CF_TOKEN" ]] || die "Cloudflare token is required"
            CRED_FIELDS+=("dns_cf_token=${CF_TOKEN}")
            read -rp "  Cloudflare Account ID (optional, blank to skip): " CF_ACCT
            [[ -n "$CF_ACCT" ]] && CRED_FIELDS+=("dns_cf_account_id=${CF_ACCT}")
            ;;
        *)
            warn "  No interactive prompt for provider '${PROVIDER}'."
            warn "  Add the required fields to ${CREDS_FILE} (format: dns_<provider>_<field>=value,"
            warn "  one per line; chmod 600). See os-acme-client GUI for field names."
            die "missing provider credentials"
            ;;
    esac

    if [[ $SAVE_CREDS -eq 1 ]]; then
        echo
        read -rp "  Save these credentials to ${CREDS_FILE} for future re-runs? [y/N] " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            (umask 077
             {
                 printf 'provider=%s\n' "$PROVIDER"
                 printf '%s\n' "${CRED_FIELDS[@]}"
             } > "$CREDS_FILE")
            chmod 600 "$CREDS_FILE"
            info "  saved to ${CREDS_FILE} (chmod 600)"
        fi
    fi
fi

# ── Provision + sign via acme-manager ──────────────────────────────────────

STAGING_ARG=()
[[ $STAGING -eq 1 ]] && STAGING_ARG=(--staging)

PROV_ARGS=()
for f in "${CRED_FIELDS[@]}"; do
    PROV_ARGS+=(--provider-field "$f")
done

echo
info "${BOLD}Running acme-manager setup${CL}"
LOG_FILE="$(mktemp /tmp/acme-setup.XXXXXX.log)"
trap 'rm -f "$LOG_FILE"' EXIT

if ! acme-manager --firewall "$FIREWALL" --no-ssl-verify setup \
        --domain "$DOMAIN" --email "$EMAIL" \
        --provider "$PROVIDER" \
        "${PROV_ARGS[@]}" \
        "${STAGING_ARG[@]}" 2>&1 | tee "$LOG_FILE"; then
    die "acme-manager setup failed (see ${LOG_FILE})"
fi

# Capture the refid from the script's terminal output (last "refid: ..." line).
REFID="$(awk '/^[[:space:]]+refid:[[:space:]]/ {print $2}' "$LOG_FILE" | tail -1)"
[[ -n "$REFID" ]] || die "could not capture certificate refid from acme-manager output"

# ── Persist refid into configuration.json ──────────────────────────────────

echo
info "${BOLD}Recording refid in configuration.json${CL}"
# Write the refid into the variant registry (ADR-005). For the default variant
# also mirror it to the legacy tappaas.tlsCertRefid so un-migrated readers keep
# working (backwards compatibility — Sprint 3.3).
TMP="$(mktemp)"
jq --arg refid "$REFID" --arg v "$VARIANT" '
    .tappaas.variants = (.tappaas.variants // {})
    | .tappaas.variants[$v] = ((.tappaas.variants[$v] // {}) + { tlsCertRefid: $refid })
    | (if $v == "" then .tappaas.tlsCertRefid = $refid else . end)' \
    "$CONFIG_FILE" > "$TMP"
mv "$TMP" "$CONFIG_FILE"
info "  ${GN}✓${CL} variants[\"${VARIANT}\"].tlsCertRefid = ${REFID}"
[[ -z "$VARIANT" ]] && info "  ${GN}✓${CL} tappaas.tlsCertRefid = ${REFID} (legacy alias)"

echo
info "${BOLD}${GN}✓${CL} ACME setup complete${BOLD}.${CL}"
info "  • Wildcard *.${DOMAIN} is issued and lives in OPNsense Trust (refid ${REFID})"
info "  • The 'caddy-reload' action will reload Caddy automatically on renewal"
info "  • From here, ${BL}rest-of-foundation.sh${CL} will install modules whose"
info "    proxyTls=dns01 binds this refid via Caddy's CustomCertificate"
