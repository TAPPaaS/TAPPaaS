#!/usr/bin/env bash
# debianhost install — register a Debian machine TAPPaaS manages (ADR-026 D3).
#
# Proves two things and changes NOTHING on the machine: the mothership reaches it
# as root by key, and it runs the OS this module manages. Adopting a machine is
# not configuring it — hardening such as key-only SSH (#19) is a separate step an
# operator takes deliberately (ADR-026 D8.1).
#
# Usage: install.sh <instance>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. /home/tappaas/bin/common-install-routines.sh
. "${HERE}/lib/debianhost-lib.sh"

dh_load "$1"
info "${BOLD}Registering ${BL}${INSTANCE}${CL}${BOLD} at ${ADDRESS}${CL}"

dh_reachable || die "cannot log in to root@${ADDRESS} with the mothership's key — authorise it first (module adopt prints the command)"
id="$(dh_os_id)"
[[ "${id}" == "debian" ]] || die "${INSTANCE} runs '${id:-unknown}', not debian — it is not a debianhost (ADR-026 D7: one module per OS)"
version="$(dh_ssh '. /etc/os-release && printf "%s" "${VERSION_ID:-?}"' 2>/dev/null || echo '?')"

info "  ${GN}✓${CL} root by key; Debian ${version}"
info "${GN}✓${CL} ${INSTANCE} registered — nothing on it was changed"
