#!/usr/bin/env bash
# TAPPaaS Module: nomad (Project N.O.M.A.D.) — Update
#
# The NixOS configuration is built and applied by templates:nixos (update-os.sh)
# on every install and update, before this runs. This adds the two things the
# VM cannot work out for itself:
#
#   * the Command Center's public URL (https://<public name>), which NOMAD
#     needs as URL — the proxy publishes it behind the site's sign-in;
#   * where the content apps open from. NOMAD links each app as
#     <current host>:<port>, and behind the proxy the current host is the
#     public name, which serves only 443. So each app's "custom URL" points at
#     the VM itself, http://<vmname>.<zone>.internal:<port>, which the client
#     networks reach (the module's ingress rules). An app's URL set by hand
#     elsewhere is left alone.
#
# Sourced by install.sh. Usage: ./update.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "${1:-nomad}")"
ZONE0NAME="$(get_config_value 'zone0' 'srv')"
NOMAD_HOST="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=30 -o BatchMode=yes)
vm() { ssh "${SSH_OPTS[@]}" "tappaas@${NOMAD_HOST}" "$@"; }

echo ""
info "${BOLD}nomad: Command Center URL and app links on ${NOMAD_HOST}${CL}"

# ── The Command Center's URL ─────────────────────────────────────────────────
_env="$(get_config_value 'environment' '')"
_domain="$(module_public_domain "${VMNAME}" "${_env}" \
    "$(read_module_config "${VMNAME}" 2>/dev/null || echo '{}')")"
URL="http://${NOMAD_HOST}:8080"
[[ -n "${_domain}" ]] && URL="https://${_domain}"
if [[ "$(vm "sudo cat /var/lib/project-nomad/url 2>/dev/null" || true)" != "${URL}" ]]; then
    vm "sudo install -d -m 0700 /var/lib/project-nomad && echo '${URL}' | sudo tee /var/lib/project-nomad/url >/dev/null && sudo systemctl restart project-nomad.service" \
        && info "  ${GN}✓${CL} Command Center URL: ${URL}" \
        || warn "  could not set the Command Center URL on ${NOMAD_HOST}"
else
    debug "  Command Center URL already ${URL}"
fi

# ── Wait for the Command Center ──────────────────────────────────────────────
for _i in $(seq 1 60); do
    vm "curl -sf --max-time 5 http://localhost:8080/api/health >/dev/null" 2>/dev/null && break
    [[ ${_i} -eq 60 ]] && { warn "  the Command Center did not answer within 5 minutes — app links not set (next update retries)"; exit 0; }
    sleep 5
done
info "  ${GN}✓${CL} Command Center answers"

# ── Where each app opens from ───────────────────────────────────────────────
# A ui_location is a port ("8090") or a scheme and port ("https:8480"). Only an
# empty custom URL, or one this script set before (same host), is (re)written.
_sql="UPDATE services SET custom_url = CASE
        WHEN ui_location REGEXP '^[0-9]+\$' THEN CONCAT('http://${NOMAD_HOST}:', ui_location)
        WHEN ui_location REGEXP '^https?:[0-9]+\$' THEN CONCAT(SUBSTRING_INDEX(ui_location, ':', 1), '://${NOMAD_HOST}:', SUBSTRING_INDEX(ui_location, ':', -1))
      END
      WHERE (ui_location REGEXP '^[0-9]+\$' OR ui_location REGEXP '^https?:[0-9]+\$')
        AND (custom_url IS NULL OR custom_url = '' OR custom_url LIKE 'http%://${NOMAD_HOST}:%');
      SELECT ROW_COUNT();"
if _n="$(vm "sudo bash -c '. /var/lib/project-nomad/.env; docker exec -i nomad_mysql mysql -N -unomad_user -p\"\${NOMAD_DB_PASSWORD}\" nomad 2>/dev/null'" <<< "${_sql}")"; then
    info "  ${GN}✓${CL} app links point at ${NOMAD_HOST} (${_n:-0} changed)"
else
    warn "  could not set the app links — they open at the public name and its port, which the proxy does not serve"
fi

echo ""
info "${BOLD}Update complete${CL}"
info "  Command Center: ${URL} (signed in through the site's identity)"
info "  Content apps  : http://${NOMAD_HOST}:<port>, from the home network"
