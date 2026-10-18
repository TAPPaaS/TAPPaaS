#!/usr/bin/env bash
#
# console check-config — what the console's config may not say (ADR-034 D2).
#
# module-manager runs a module's check-config.sh on the config it is about to
# install (`module add`) or write (`module modify --set`), before anything is
# provisioned or written, and refuses the change when it exits non-zero; what it
# prints is the reason. The console's own test.sh runs it on the deployed config.
#
# The console runs the site: it is reached from mgmt and over the admin VPN, and
# nowhere else. A zone list that opens it to the internet ('internet', or the
# networks 0.0.0.0/0 and ::/0) or to every zone ('all') is refused — on the
# module's route, on any proxyRoutes entry and in any proxyAccess path rule.
#
# Usage: check-config.sh <config.json>   (flat, or with the fields under .config)
set -euo pipefail

cfg="${1:?usage: check-config.sh <config.json>}"
# Every zone list anywhere in the config: Pattern A nests the module's own under
# .config."network:proxy", a route's sit in proxyRoutes[], a path rule's in .zones.
open="$(jq -r '
    def items: if type == "array" then .[] elif type == "string" then . else empty end;
    [ .. | objects
      | ((.proxyAllowedZones // empty | items), (.proxyAccess // empty | items | objects | .zones // empty | items)) ]
    | map(select(. == "internet" or . == "all" or . == "0.0.0.0/0" or . == "::/0"))
    | unique | join(", ")' "${cfg}" 2>/dev/null)" \
    || { echo "console: cannot read the config ${cfg}" >&2; exit 2; }

if [[ -n "${open}" ]]; then
    echo "console: proxyAllowedZones may not include ${open} — the console is reached from mgmt and the admin VPN only (ADR-034 D2); keep it [\"mgmt\", \"admin\"]" >&2
    exit 1
fi
exit 0
