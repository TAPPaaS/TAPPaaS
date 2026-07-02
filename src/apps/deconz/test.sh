#!/usr/bin/env bash
#
# TAPPaaS deCONZ module — test
#
# Verifies the deCONZ service is up and the REST/Hue-compat API answers.
# Exit 0 = all gates pass, 1 = a gate failed.
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "${1:-deconz}")"
ZONE0NAME="$(get_config_value 'zone0' 'iotCloud')"
HTTP_PORT="$(get_config_value 'config.firewall:proxy.proxyPort' '8080')"
FQDN="${VMNAME}.${ZONE0NAME}.internal"

fail=0

# Gate 1 — deCONZ REST/Hue-compat API answers on the http port (/api/config is
# unauthenticated and returns the bridge descriptor).
info "Gate 1: deCONZ API http://${FQDN}:${HTTP_PORT}/api/config"
code="$(curl -s -m 10 -o /tmp/deconz_config.json -w '%{http_code}' \
  "http://${FQDN}:${HTTP_PORT}/api/config" 2>/dev/null || echo 000)"
if [[ "${code}" == "200" ]]; then
  name="$(jq -r '.name // .bridgeid // "?"' /tmp/deconz_config.json 2>/dev/null || echo '?')"
  info "  ${GN}PASS${CL} — API 200 (bridge: ${name})"
else
  warn "  FAIL — expected 200, got ${code}"
  fail=1
fi

# Gate 2 — websocket port open (HA deconz integration live-event channel).
WS_PORT="8443"
info "Gate 2: websocket port ${FQDN}:${WS_PORT} reachable"
if timeout 5 bash -c ">/dev/tcp/${FQDN}/${WS_PORT}" 2>/dev/null; then
  info "  ${GN}PASS${CL} — ws port open"
else
  warn "  FAIL — ws port ${WS_PORT} not reachable"
  fail=1
fi

# Gate 3 — diyHue's `hue-bridge` service (SysAP-facing Hue API) is up. Checked
# HERE, independent of any consumer's firewall wiring, because the module
# PROVIDES hue-bridge (deconz.json provides[]) — its own health must not depend
# on whether a consumer module (e.g. sysap) happens to invoke
# services/hue-bridge/test-service.sh. Regression history (2026-07-02): a
# canon-patch redeploy silently dropped the diyHue container; Gate 1/2 still
# passed (deCONZ itself was fine) and the outage went undetected until a
# consumer noticed. This gate exists so `test.sh` alone catches that again.
for HUE_PORT in 80 443; do
  info "Gate 3: hue-bridge (diyHue) port ${FQDN}:${HUE_PORT} reachable"
  if timeout 5 bash -c ">/dev/tcp/${FQDN}/${HUE_PORT}" 2>/dev/null; then
    info "  ${GN}PASS${CL} — hue-bridge port ${HUE_PORT} open"
  else
    warn "  FAIL — hue-bridge port ${HUE_PORT} not reachable (diyHue container down/misconfigured?)"
    fail=1
  fi
done

echo ""
if [[ "${fail}" -eq 0 ]]; then
  info "${GN}✓ deCONZ test passed${CL}"
  exit 0
else
  warn "✗ deCONZ test failed"
  exit 1
fi
