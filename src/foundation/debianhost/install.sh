#!/usr/bin/env bash
# debianhost install — register a Debian machine TAPPaaS manages (ADR-026 D3).
#
# Proves two things — the mothership reaches it as root by key, and it runs the
# OS this module manages — then makes SSH key-only, as on the cluster nodes (#19),
# unless the operator adopted it with `--set sshKeyOnly=false` (ADR-026 D8.1, as
# amended 2026-10-02, #756). Nothing else on the machine is changed.
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
dh_key_only_converge || die "${INSTANCE}: not registered as key-only — fix the above, or adopt it with --set sshKeyOnly=false"
info "${GN}✓${CL} ${INSTANCE} registered"
