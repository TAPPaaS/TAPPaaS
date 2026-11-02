#!/usr/bin/env bash
#
# console install — the published face of the console (ADR-034 D1). The service
# itself is part of the mothership (tappaas-console.service, tappaas-cicd.nix);
# registering this module is what gives it its route: network:proxy publishes it
# through Caddy from mgmt and the admin VPN, identity:accessControl puts the
# Authentik gate in front. Nothing is installed on any machine here.
#
# Usage: install.sh <instance>
set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh
if systemctl is-active --quiet tappaas-console.service 2>/dev/null; then
    info "${BOLD}console: registered — tappaas-console is running on the mothership${CL}"
else
    warn "console: registered, but tappaas-console.service is not running — it starts once ~/bin/console is built (refresh-control-plane.sh)"
fi
