#!/usr/bin/env bash
#
# Satellite reverse-proxy deep test (ADR-010).
#
# Stands up the disposable `sat-hello` module (a minimal nginx published via
# network:proxy), then verifies the FULL public path THROUGH the satellite:
#
#     client → satellite:443 (public IP) → WireGuard tunnel → Caddy-on-OPNsense
#            → sat-hello VM:80  ⇒  HTTP 200 + valid Let's Encrypt wildcard cert
#
# This is the runtime analogue of tappaas-cicd/test-vm-creation: install-module →
# verify → delete-module. It is a LIVE test — it needs a provisioned satellite
# (reverse-proxy role) and an ACME wildcard cert already issued for the target
# environment — so it is gated behind --deep from satellite/test.sh and skips
# (exit 0) with a clear reason when the prerequisites are absent.
#
# Usage: ./test.sh [--env <name>] [--skip-delete]
#   --env <name>     target environment (default: $TAPPAAS_SAT_TEST_ENV, else the
#                    single non-mgmt environment under config/environments/).
#   --skip-delete    leave the sat-hello VM running after the test (debugging).
#
# Env overrides:
#   TAPPAAS_SAT_TEST_ENV   default environment name
#   TAPPAAS_SAT_NAME       satellite config to read the public IP from
#                          (default: the single config/satellite-*.json)
#   CONFIG_DIR             config root (default: /home/tappaas/config)
#   TAPPAAS_BIN            toolbox dir (default: /home/tappaas/bin)
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${here}"

CONFIG_DIR="${CONFIG_DIR:-/home/tappaas/config}"
TAPPAAS_BIN="${TAPPAAS_BIN:-/home/tappaas/bin}"
MODULE="sat-hello"
ENV_NAME="${TAPPAAS_SAT_TEST_ENV:-}"
SKIP_DELETE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)          ENV_NAME="${2:?--env needs a value}"; shift 2 ;;
        --skip-delete)  SKIP_DELETE=1; shift ;;
        -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
        *)              echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

info() { echo -e "  \e[32m[info]\e[0m $*"; }
skip() { echo -e "  \e[33m[skip]\e[0m $*"; exit 0; }   # prerequisite absent → not a failure
die()  { echo -e "  \e[31m[FAIL]\e[0m $*" >&2; exit 1; }

# ── Resolve the target environment ──────────────────────────────────────────
if [[ -z "${ENV_NAME}" ]]; then
    mapfile -t _envs < <(find "${CONFIG_DIR}/environments" -maxdepth 1 -name '*.json' \
        -not -name 'mgmt.json' -printf '%f\n' 2>/dev/null | sed 's/\.json$//')
    [[ "${#_envs[@]}" -eq 1 ]] && ENV_NAME="${_envs[0]}"
fi
[[ -n "${ENV_NAME}" ]] || skip "no target environment (set --env or TAPPAAS_SAT_TEST_ENV; none auto-resolved)"
ENV_FILE="${CONFIG_DIR}/environments/${ENV_NAME}.json"
[[ -f "${ENV_FILE}" ]] || skip "environment '${ENV_NAME}' not found (${ENV_FILE})"

DOMAIN_PRIMARY="$(jq -r '.domains.primary // empty' "${ENV_FILE}")"
[[ -n "${DOMAIN_PRIMARY}" ]] || skip "environment '${ENV_NAME}' has no domains.primary"
FQDN="${MODULE}.${DOMAIN_PRIMARY}"

# ── Prerequisite: a provisioned satellite with the reverse-proxy role ────────
SAT_NAME="${TAPPAAS_SAT_NAME:-}"
if [[ -z "${SAT_NAME}" ]]; then
    mapfile -t _sats < <(find "${CONFIG_DIR}" -maxdepth 1 -name 'satellite-*.json' -printf '%f\n' 2>/dev/null \
        | sed -e 's/^satellite-//' -e 's/\.json$//')
    [[ "${#_sats[@]}" -eq 1 ]] && SAT_NAME="${_sats[0]}"
fi
[[ -n "${SAT_NAME}" ]] || skip "no satellite config (config/satellite-*.json) — provision one first"
SAT_FILE="${CONFIG_DIR}/satellite-${SAT_NAME}.json"
[[ -f "${SAT_FILE}" ]] || skip "satellite '${SAT_NAME}' config not found (${SAT_FILE})"
jq -e '(.roles // []) | index("reverse-proxy")' "${SAT_FILE}" >/dev/null 2>&1 \
    || skip "satellite '${SAT_NAME}' does not carry the reverse-proxy role"
SAT_IP="$(jq -r '.host.publicIp // empty' "${SAT_FILE}")"
[[ -n "${SAT_IP}" ]] || skip "satellite '${SAT_NAME}' has no host.publicIp"

# ── Prerequisite: a wildcard cert issued for this environment ───────────────
REFIDS="${CONFIG_DIR}/cert-refids.json"
[[ -f "${REFIDS}" ]] && [[ "$(jq -r --arg e "${ENV_NAME}" '.[$e] // empty' "${REFIDS}")" != "" ]] \
    || skip "no wildcard cert for environment '${ENV_NAME}' (run acme-setup.sh) — cert-refids.json"

echo "=============================================================="
echo " Satellite reverse-proxy deep test"
echo "   module      : ${MODULE}"
echo "   environment : ${ENV_NAME}  (domain ${DOMAIN_PRIMARY})"
echo "   satellite   : ${SAT_NAME}  (public IP ${SAT_IP})"
echo "   target URL  : https://${FQDN}/  (forced via the satellite IP)"
echo "=============================================================="

cleanup() {
    if [[ "${SKIP_DELETE}" -eq 1 ]]; then
        info "--skip-delete: leaving ${MODULE} running"
        return
    fi
    info "Tearing down ${MODULE}..."
    "${TAPPAAS_BIN}/delete-module.sh" "${MODULE}" --force >/dev/null 2>&1 \
        && info "  ${MODULE} removed" || echo "  [warn] delete-module ${MODULE} failed (clean up manually)" >&2
}
trap cleanup EXIT

# ── Install ─────────────────────────────────────────────────────────────────
info "Installing ${MODULE} on environment '${ENV_NAME}'..."
if ! "${TAPPAAS_BIN}/install-module.sh" "${MODULE}" --environment "${ENV_NAME}"; then
    die "install-module ${MODULE} failed"
fi

# ── Verify THROUGH the satellite ────────────────────────────────────────────
# Force resolution to the satellite public IP so the request traverses the real
# relay path (from inside the cluster, split-horizon would otherwise resolve the
# name to the internal DMZ gateway and bypass the satellite).
info "Probing https://${FQDN}/ via the satellite (${SAT_IP}) — polling up to 120s..."
body=""; issuer=""; code=""; ok=0
for _ in $(seq 1 24); do
    code="$(curl -sS --max-time 15 --resolve "${FQDN}:443:${SAT_IP}" \
              -o /tmp/sat-hello-body.$$ -w '%{http_code}' "https://${FQDN}/" 2>/dev/null || true)"
    if [[ "${code}" == "200" ]]; then
        body="$(cat /tmp/sat-hello-body.$$ 2>/dev/null)"
        issuer="$(echo | openssl s_client -connect "${SAT_IP}:443" -servername "${FQDN}" 2>/dev/null \
                    | openssl x509 -noout -issuer 2>/dev/null || true)"
        ok=1; break
    fi
    sleep 5
done
rm -f /tmp/sat-hello-body.$$

[[ "${ok}" -eq 1 ]] || die "no HTTP 200 through the satellite (last code='${code}')"
echo "${body}" | grep -q "sat-hello OK" || die "unexpected body through the satellite: '${body}'"
# Cert issuer check is best-effort (openssl SNI quirks); warn rather than fail if empty.
if [[ -n "${issuer}" ]]; then
    echo "${issuer}" | grep -qi "Let's Encrypt" \
        && info "  cert issuer: ${issuer#*= }" \
        || die "served cert is not Let's Encrypt: ${issuer}"
else
    info "  (cert issuer probe inconclusive; curl already verified the chain via HTTP 200)"
fi

echo ""
echo -e "  \e[32m[PASS]\e[0m satellite reverse-proxy serves ${FQDN} end-to-end (HTTP 200, valid TLS)"
exit 0
