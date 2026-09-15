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
