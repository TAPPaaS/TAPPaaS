#!/usr/bin/env bash
#
# TAPPaaS — operator-driven setup of a wildcard TLS certificate via os-acme-client
# (issue #254). Run from the cicd mothership at INSTALL.md §2.3, after the install
# chain has set up Caddy but before installing the rest of the foundation.
#
# DEPRECATED (ADR-043 D7): ca-manager now holds the DNS providers and issues the
# certificate (`ca-manager provider add`, `ca-manager acme`). This script is a
# shim for one release: it asks for a credential at a terminal when ca-manager has
# none for the domain, registers it there, and lets ca-manager issue. Then, as
# before, it registers the split-horizon wildcard DNS.
#
# What it does (idempotent):
#   1. Reads the environment's domain (config/environments/<env>.json, via
#      get_variant_config) and the installer email (site.json .email, via
#      installer_email)
#   2. Asks for the DNS provider (default: cloudflare) and its API credential(s),
#      OR reads them from ~/.acme-dns-credentials.txt if present (chmod 600)
#   3. Provisions an ACME account, DNS-01 validation, caddy-reload action, and
#      a wildcard cert (*.<domain> + bare apex) on the OPNsense firewall via the
#      acme-manager CLI (drives os-acme-client end-to-end)
#   4. Captures the OPNsense Trust refid of the issued cert and writes it into
#      the runtime cert-refids.json keyed by environment (ADR-007c) — this is
#      what the per-module proxy install reads so each domain binds the wildcard
#      refid via Caddy's CustomCertificate (no per-module ACME, no DNS-API needed
#      at install time)
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

CREDS_FILE="${HOME}/.acme-dns-credentials.txt"
FIREWALL="${OPNSENSE_HOST:-firewall.mgmt.internal}"
STAGING=0
PROVIDER_OVERRIDE=""
SAVE_CREDS=1
VARIANT=""
DNS_SLEEP=150

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
  --environment <name>   Issue the cert for the named environment's domain
                         (config/environments/<name>.json) and store the refid
                         in cert-refids.json[<name>]. Default: "" (the default
                         environment = site.json .name).
  --variant <name>       DEPRECATED alias for --environment (compat period).
  --dns-sleep <secs>     Seconds to wait for DNS-01 TXT propagation before LE
                         validation (default 150; raise for slow providers).
                         45 was enough until Let's Encrypt widened its
                         multi-perspective validation; secondary perspectives
                         then began failing with "No TXT record found". #328
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
        --environment)     VARIANT="$2"; shift 2 ;;
        --variant)         VARIANT="$2"; shift 2 ;;  # deprecated alias
        --dns-sleep)       DNS_SLEEP="$2"; shift 2 ;;
        --help|-h)         usage; exit 0 ;;
        *)                 die "Unknown option: $1 (try --help)" ;;
    esac
done

# Domain comes from the environment file (config/environments/<env>.json). The
# default environment "" resolves to site.json .name.
VCFG="$(get_variant_config "${VARIANT}")" \
    || die "Environment '${VARIANT:-<default>}' not found. Create it with environment-manager (config/environments/<env>.json)."
DOMAIN="$(jq -r '.domain // empty' <<<"$VCFG")"
EMAIL="$(installer_email)"
[[ -n "$DOMAIN" && "$DOMAIN" != CHANGE* ]] || die "Environment '${VARIANT:-<default>}' has no domain set (set domains.primary in its environment file)"
[[ -n "$EMAIL"  && "$EMAIL"  != CHANGE* ]] || die "site.json .email not set"

info "${BOLD}TAPPaaS ACME setup${CL}"
info "  domain        : ${BL}${DOMAIN}${CL}"
info "  email         : ${EMAIL}"
info "  CA            : $( [[ $STAGING -eq 1 ]] && echo 'Let'"'"'s Encrypt STAGING' || echo 'Let'"'"'s Encrypt PROD' )"
info "  firewall      : ${FIREWALL}"
info "  cert subject  : *.${DOMAIN}  (+ bare apex)"
echo

# ── Source credentials: ca-manager's provider, the file, then a prompt ──────

PROVIDER=""
declare -a CRED_FIELDS=()   # list of "dns_*=value" entries to pass to acme-manager
REGISTERED="$(ca-manager provider for "$DOMAIN" 2>/dev/null || true)"

if [[ -n "$REGISTERED" && -z "$PROVIDER_OVERRIDE" ]]; then
    info "Using ca-manager's DNS provider for ${DOMAIN}: ${REGISTERED}"
elif [[ -f "$CREDS_FILE" ]]; then
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

[[ -z "$REGISTERED" || -n "$PROVIDER_OVERRIDE" ]] && info "  DNS provider  : ${PROVIDER}"

if [[ ( -z "$REGISTERED" || -n "$PROVIDER_OVERRIDE" ) && ${#CRED_FIELDS[@]} -eq 0 ]]; then
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

fi

# The credential goes to ca-manager (ADR-043 D6), which keeps it in its key dir;
# --no-save-creds is accepted and has nothing left to decline.
if [[ ${#CRED_FIELDS[@]} -gt 0 ]]; then
    PROVIDER_NAME="$(printf '%s' "${PROVIDER#dns_}" | tr '[:upper:]_' '[:lower:]-')"
    printf '%s\n' "${CRED_FIELDS[@]}" | ca-manager provider add "$PROVIDER_NAME" --type "$PROVIDER" --domain "$DOMAIN" \
        || die "ca-manager provider add ${PROVIDER_NAME} failed"
fi

ENV_NAME="$VARIANT"
[[ -z "$ENV_NAME" ]] && ENV_NAME="$(default_environment_name)"

echo
info "${BOLD}ca-manager acme ${ENV_NAME}${CL}  (drives os-acme-client end-to-end; a few minutes)"
ACME_ARGS=(acme "$ENV_NAME" --domain "$DOMAIN" --dns-sleep "$DNS_SLEEP")
[[ $STAGING -eq 1 ]] && ACME_ARGS+=(--staging)
ca-manager "${ACME_ARGS[@]}" || die "ca-manager acme failed for ${DOMAIN}"
REFID="$(jq -r --arg e "$ENV_NAME" '.[$e] // empty' "$(cert_refids_path)")"
[[ -n "$REFID" ]] || die "ca-manager reported success but cert-refids.json has no refid for ${ENV_NAME}"

# ── Split-horizon wildcard DNS (ADR-005 §6, #269) ──────────────────────────
# In wildcard mode, point *.<domain> at the DMZ gateway (where os-caddy listens)
# via an UNBOUND host override, so internal clients reach Caddy over the DMZ
# instead of resolving the public WAN IP and tripping Caddy's zone ACL (HTTP 403).
# Must be Unbound (the resolver on 10.0.0.1:53) — Dnsmasq host entries are not
# served for public domains and cannot express a wildcard. Unbound supports a "*"
# wildcard host override.
DNS_MODE="$(jq -r '.dnsMode // "per-service"' <<<"$VCFG")"
if [[ "$DNS_MODE" == "wildcard" ]]; then
    echo
    info "${BOLD}Registering split-horizon wildcard DNS (Unbound)${CL}"
    # ADR-021 D2/D5: the wildcard resolves to the DMZ gateway, like every other
    # split-horizon record, and the address comes from the ONE resolver rather
    # than being derived here. This file used to derive it from the environment's
    # SERVICE zone (falling back to dmz) while network:proxy derived it from a
    # CLIENT zone — two of the three transcriptions #577 found disagreeing.
    #
    # Under D2 the one-apex-target problem disappears: a wildcard is a single
    # Unbound "redirect" zone with one target, and one target is now all that is
    # ever correct, for every client zone at once.
    WC_ZONE="dmz"
    WC_GW=""
    WC_RC=0
    # --assume-published, because the certificate above IS the evidence (#703).
    #
    # The probe behind this verb is an A-record lookup on the name it is given,
    # and this call used to hand it the bare apex. A DNS-01 wildcard is proven
    # by a TXT record at _acme-challenge.<domain> and needs no A record on the
    # apex at all, so an environment whose wildcard resolves publicly was read
    # as UNPUBLISHED, the record was skipped, and every name the wildcard covers
    # then resolved to the WAN address from inside — while Caddy held a valid
    # certificate and a live handler for it.
    #
    # ADR-021 R3 asks "can a certificate exist for this name": by this line the
    # script has already died unless acme-manager issued *.${DOMAIN} and a refid
    # was captured, so the question is answered, and answered by a stronger
    # source than a DNS probe. The flag's own contract — "never a way to publish
    # a name that has no cert" — is satisfied, not bypassed.
    WC_ERR="$(mktemp)"
    WC_GW="$(network-manager split-horizon-target "${DOMAIN}" --assume-published 2>"${WC_ERR}")" || WC_RC=$?
    if [[ -n "$WC_GW" ]]; then
        # The wildcard installs `local-zone: "<domain>" redirect`, and Unbound
        # then rejects any per-name local-data in that zone (it must sit at the
        # apex). Pre-existing per-service overrides for this domain (e.g.
        # logging.<domain>, authored before wildcard mode) therefore make
        # unbound-checkconf fatal and stop the resolver — taking cluster DNS
        # down. Drop them first; the wildcard supersedes them. That includes
        # records deeper down (svc.demo.<domain>), not only <host>.<domain> (#649).
        unbound-manager --no-ssl-verify list 2>/dev/null \
            | awk -v d="$(tr '[:upper:]' '[:lower:]' <<<"${DOMAIN}")" '
                NR>1 && $1!="*" {
                    z = tolower($2)
                    if (z == d || substr(z, length(z) - length(d)) == "." d) print $1, $2
                }' \
            | while read -r _h _z; do
                info "  removing per-service override ${_h}.${_z} (wildcard supersedes)"
                unbound-manager --no-ssl-verify delete "${_h}" "${_z}" >/dev/null 2>&1 || true
            done
        if unbound-manager --no-ssl-verify add "*" "${DOMAIN}" "${WC_GW}" \
                --description "TAPPaaS: ${VARIANT:-default} wildcard -> Caddy (${WC_ZONE})"; then
            info "  ${GN}✓${CL} *.${DOMAIN} -> ${WC_GW} (${WC_ZONE} gateway, Unbound)"
        else
            warn "  Could not register *.${DOMAIN} in Unbound — register manually:"
            warn "    unbound-manager --no-ssl-verify add '*' '${DOMAIN}' '${WC_GW}'"
        fi
    else
        # Say the reason the resolver gave, rather than a guess. With the probe
        # answered above, the only ways to land here are the resolver's own
        # errors — no dmz zone, or one with no usable ip — and the old wording
        # ("could not derive a gateway from zones.json") was printed for every
        # cause including the one that actually fired, pointing diagnosis at the
        # wrong file (#703).
        WC_SKIPPED=1
        warn "  Skipped wildcard DNS — split-horizon-target gave no address (rc ${WC_RC}):"
        while IFS= read -r _wl; do [[ -n "${_wl}" ]] && warn "    ${_wl}"; done < "${WC_ERR}"
        warn "    reproduce: network-manager split-horizon-target ${DOMAIN} --assume-published --json"
    fi
    rm -f "${WC_ERR}"
fi

echo
if [[ "${WC_SKIPPED:-0}" == "1" ]]; then
    # The certificate is real and the refid is stored, but in wildcard mode the
    # Unbound record is what makes the names reachable from a client zone. A run
    # that skipped it has not finished the job, and used to say it had (#703).
    warn "${BOLD}ACME setup INCOMPLETE${CL} — the certificate is issued, the split-horizon record is not."
    warn "  *.${DOMAIN} resolves publicly from inside until it is registered:"
    warn "    unbound-manager --no-ssl-verify add '*' '${DOMAIN}' '<dmz-gateway>'"
    exit 1
fi
info "${BOLD}${GN}✓${CL} ACME setup complete${BOLD}.${CL}"
info "  • Wildcard *.${DOMAIN} is issued and lives in OPNsense Trust (refid ${REFID})"
info "  • The 'caddy-reload' action will reload Caddy automatically on renewal"
info "  • From here, ${BL}rest-of-foundation.sh${CL} will install modules whose"
info "    proxyTls=dns01 binds this refid via Caddy's CustomCertificate"
info "  • The DNS provider and the certificate are ca-manager's: ${BL}ca-manager provider list${CL}, ${BL}ca-manager status${CL}"
