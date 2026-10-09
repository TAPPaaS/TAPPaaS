# shellcheck shell=bash
# oidc-consumer.sh — where identity:identity wires an OIDC consumer (#560).
#
# install-service.sh writes the OIDC client config to these places and
# test-service.sh checks them, so both read them from here.
#
# oidc_consumer_paths <module> <environment> <normalized-module-json>
# Sets:
#   OIDC_MODULE_BASE        module name without its -<environment> suffix
#   OIDC_SECRETS_ENV        secrets env file on the VM
#   OIDC_CONFIGURE_SERVICE  unit that registers the provider in the app, or ""
#                           when the module opts out (identity.configureService
#                           = "none": the app registers it itself)
# Returns 1 when either value is not a plain path / unit name: both are pasted
# into a remote shell run under sudo on the VM, so a quote in module config
# would otherwise run as root there.
# oidc_public_domain <vmname> <environment> <normalized-module-json>
#
# Echoes the domain a browser reaches this module at, or "" when the site
# publishes it nowhere — the one predicate that decides whether SSO can exist
# at all, so install-service.sh, accessControl and test-service.sh must not each
# have their own (#698: they disagreed, and the sweep rolled a module back).
#
# Explicit proxyDomain wins; otherwise it is <vmname>.<environment domain>, the
# name network:proxy publishes at. A derived domain therefore counts as
# published — treating it as unpublished would let a reachable app pass as
# "nothing to protect". An environment with no domain at all (mgmt is the
# standard internal-only case) yields "", and then there is no redirect URI, no
# OIDC application, and nothing for any of the three to do.
oidc_public_domain() {
    # Delegates to the platform's one derivation (#715), which is the proxy's:
    # this predicate used to be a seventh copy, and it disagreed with what the
    # proxy publishes in two ways — it read only a top-level proxyDomain (so a
    # Pattern-A module published at cloud.<domain> came out as
    # nextcloud.<domain>), and it ignored the legacy configuration.json domain
    # (so on a site that still has one, mgmt modules Caddy serves were called
    # unpublished and got no SSO). Verified against both sites' Caddyfiles.
    module_public_domain "$1" "$2" "$3"
}

# accesscontrol_gate_slug <module> <normalized module json> — the Authentik slug
# of the module's forward-auth gate (identity:accessControl). It is <module>,
# unless the module ALSO declares identity:identity: then its OIDC app holds
# <module> and shows the tile, and the gate is <module>-gate, hidden from the
# app list (#806 — Jellyfin's API needs the gate, its login needs OIDC; the
# ADR-006 §4 exception). install, test and delete must agree, so it is here.
accesscontrol_gate_slug() {
    if jq -e '(.dependsOn // []) | index("identity:identity")' <<<"$2" >/dev/null 2>&1; then
        printf '%s-gate\n' "$1"
    else
        printf '%s\n' "$1"
    fi
}

# oidc_domain_unpublished <domain> — succeeds when the name is authoritatively
# NOT published (#778): no public A record on a per-service site, so no proxy
# route, no certificate, and no OIDC redirect to it can complete. The verdict is
# the one resolver's (ADR-021, `network-manager split-horizon-target` exit 3),
# shared with network:proxy and with_public_domain. Unknown (no network-manager,
# a lookup error) is NOT unpublished: the module keeps its SSO as before.
oidc_domain_unpublished() {
    local rc=0
    command -v network-manager >/dev/null 2>&1 || return 1
    network-manager split-horizon-target "$1" >/dev/null 2>&1 || rc=$?
    [[ ${rc} -eq 3 ]]
}

oidc_consumer_paths() {
    local module="$1" environment="$2" json="$3" cs
    OIDC_MODULE_BASE="${module}"
    if [[ -n "${environment}" && "${module}" == *"-${environment}" ]]; then
        OIDC_MODULE_BASE="${module%-"${environment}"}"
    fi
    OIDC_SECRETS_ENV="$(jq -r --arg d "/etc/secrets/${OIDC_MODULE_BASE}.env" \
        '.identity.secretsEnv // $d' <<<"${json}")"
    cs="$(jq -r '.identity.configureService // ""' <<<"${json}")"
    if [[ "${cs}" == "none" ]]; then
        cs=""
    elif [[ -z "${cs}" ]]; then
        cs="${OIDC_MODULE_BASE}-configure-oidc.service"
    fi
    OIDC_CONFIGURE_SERVICE="${cs}"
    [[ "${OIDC_SECRETS_ENV}" =~ ^/[A-Za-z0-9._/-]+$ && "${OIDC_SECRETS_ENV}" != *..* ]] || return 1
    [[ -z "${cs}" || "${cs}" =~ ^[A-Za-z0-9@._-]+\.service$ ]] || return 1
}
