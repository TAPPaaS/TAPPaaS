#!/usr/bin/env bash
#
# The live state of one backup-buddy tunnel (#796) — `backup-manager peer check`.
# Read-only: the OPNsense instance and its key, the peer handshake, and on the
# dialing side whether the far PBS answers on <net>.1:8007 from our PBS.
#
# Usage: tunnel-check.sh <serve|dial> <name> <net/30>
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../lib/pbs-job.sh disable=SC1091
. "${SCRIPT_DIR}/../lib/pbs-job.sh"
# shellcheck source=../lib/pbs-namespace.sh disable=SC1091
. "${SCRIPT_DIR}/../lib/pbs-namespace.sh"
# shellcheck source=../lib/pbs-tunnel.sh disable=SC1091
. "${SCRIPT_DIR}/../lib/pbs-tunnel.sh"

ROLE="${1:-}"; NAME="${2:-}"; NET="${3:-}"
[[ "${ROLE}" == "serve" || "${ROLE}" == "dial" ]] && [[ -n "${NAME}" && -n "${NET}" ]] \
    || die "Usage: $0 <serve|dial> <name> <net/30>"
hosts="$(bt_hosts "${NET}")" || die "not a tunnel /30: ${NET}"

rc=0
st="$(bt_status "${ROLE}" "${NAME}")" || rc=1
info "  ${st}"
case "${st}" in
    *"peer=none"*)    warn "  no peer yet — re-run peer add with --peer-key <their key> --force"; rc=1 ;;
    *"hs=never"*|*"peer=unknown"*) warn "  no handshake — check the endpoint, the WAN rule and the keys on both sides"; rc=1 ;;
esac

if [[ "${ROLE}" == "dial" ]]; then
    far="${hosts% *}"
    code="$(_pbs_node_run curl -sk -m 8 -o /dev/null -w '%{http_code}' "https://${far}:8007/" 2>/dev/null || true)"
    if [[ "${code}" =~ ^[23] ]]; then
        info "  ${GN}✓${CL} their PBS answers at ${far}:8007 (HTTP ${code})"
    else
        warn "  their PBS does not answer at ${far}:8007 from our PBS (HTTP ${code:-none})"; rc=1
    fi
fi
exit "${rc}"
