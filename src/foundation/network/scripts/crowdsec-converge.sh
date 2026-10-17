#!/usr/bin/env bash
# TAPPaaS network — CrowdSec on the firewall (#851)
#
# Bans a client at the firewall (pf, before Caddy) when the published names'
# access logs show it guessing sign-ins or probing for known exploits. Local
# only: the instance never registers with CrowdSec's central API, so nothing
# about this site's traffic leaves it (operator decision, 2026-10-17); hub
# updates — parsers and scenarios — are downloaded, nothing is sent.
#
# What it converges, every run (idempotent):
#   1. the packages: crowdsec + its firewall bouncer, the central-API section
#      removed from config.yaml BEFORE the plugin (os-crowdsec) first starts it —
#      the rc script registers with the central API on a first start otherwise;
#   2. Caddy writes one access log per published name (os-caddy LogAccessPlain,
#      AccessLog on every TAPPaaS domain), which CrowdSec reads (acquis.d);
#   3. what it acts on: the Caddy log parser, the TAPPaaS sign-in brute-force
#      scenario, and the known-exploit and bad-user-agent scenarios — NOT the
#      generic HTTP probing ones, which a Jellyfin client's missing-image 404s
#      would trip;
#   4. who it never bans: private IPv4 (crowdsecurity/whitelists) and every
#      IPv6 /64 on the firewall's internal interfaces (the site's own clients
#      use global IPv6 addresses), recomputed each run for a dynamic prefix.
#
# Usage: crowdsec-converge.sh [--check]   (--check: report, change nothing)

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh
FW="${FIREWALL_FQDN:-firewall.mgmt.internal}"
CHECK=0; [[ "${1:-}" == "--check" ]] && CHECK=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO="$(cat "${HERE}/crowdsec/tappaas-http-login-bf.yaml")"

# ── 2. Caddy access logs (the OPNsense API, from the mothership) ──────────
OPN_CREDS="${HOME}/.opnsense-credentials.txt"
OPN_AUTH="$(grep '^key=' "$OPN_CREDS" | cut -d= -f2-):$(grep '^secret=' "$OPN_CREDS" | cut -d= -f2-)"
CADDY_API="https://${FW}:8443/api/caddy"
caddy_changed=0
if [[ "$(curl -ksS -u "$OPN_AUTH" "${CADDY_API}/General/get" | jq -r '.caddy.general.LogAccessPlain')" != "1" ]]; then
    if [[ ${CHECK} -eq 1 ]]; then info "  would turn on per-name access logs (Caddy LogAccessPlain)"; else
    curl -ksS -u "$OPN_AUTH" -X POST "${CADDY_API}/General/set" -H 'Content-Type: application/json' \
        -d '{"caddy":{"general":{"LogAccessPlain":"1"}}}' | jq -e '.result == "saved"' >/dev/null \
        || die "could not turn on Caddy's per-name access logs"
    caddy_changed=1; fi
fi
while IFS=$'\t' read -r uuid name; do
    [[ -n "${uuid}" ]] || continue
    if [[ ${CHECK} -eq 1 ]]; then info "  would log access for ${name}"; continue; fi
    curl -ksS -u "$OPN_AUTH" -X POST "${CADDY_API}/ReverseProxy/setReverseProxy/${uuid}" -H 'Content-Type: application/json' \
        -d '{"reverse":{"AccessLog":"1"}}' | jq -e '.result == "saved"' >/dev/null \
        || die "could not turn on the access log of ${name}"
    caddy_changed=1
done < <(curl -ksS -u "$OPN_AUTH" "${CADDY_API}/ReverseProxy/searchReverseProxy" \
    | jq -r '.rows[] | select((.description // "") | startswith("TAPPaaS")) | select((.AccessLog // "0") != "1") | [.uuid, .FromDomain] | @tsv')
if [[ ${caddy_changed} -eq 1 ]]; then
    curl -ksS -u "$OPN_AUTH" -X POST "${CADDY_API}/service/reconfigure" | jq -r .status >/dev/null
    info "  ${GN}✓${CL} Caddy writes one access log per published name"
fi

# ── 1, 3, 4. On the firewall ──────────────────────────────────────────────
ssh -o BatchMode=yes "root@${FW}" "/bin/sh -s -- ${CHECK}" <<EOF
set -e
CHECK="\$1"
CS=/usr/local/etc/crowdsec
say() { echo "  \$*"; }
# 1. packages, local only
if ! pkg info -q os-crowdsec; then
    [ "\$CHECK" = 1 ] && { say "would install crowdsec, its firewall bouncer and os-crowdsec (local only)"; exit 0; }
    pkg install -y crowdsec crowdsec-firewall-bouncer >/dev/null
fi
/usr/local/bin/python3 - "\$CS/config.yaml" "\$CHECK" <<'PY'
import sys, yaml
path, check = sys.argv[1], sys.argv[2] == "1"
cfg = yaml.safe_load(open(path))
server = (cfg.get("api") or {}).get("server") or {}
if "online_client" in server:
    if check:
        print("  would remove the central-API section (online_client) from config.yaml")
    else:
        del server["online_client"]
        yaml.safe_dump(cfg, open(path, "w"), sort_keys=False)
        print("  central API off: online_client removed from config.yaml")
PY
[ "\$CHECK" = 1 ] || rm -f "\$CS/online_api_credentials.yaml"
if ! pkg info -q os-crowdsec; then
    pkg install -y os-crowdsec >/dev/null
    say "installed os-crowdsec (agent, local API, firewall bouncer)"
fi
# 3. what it acts on
changed=0
# hub items by kind (the known-exploit scenarios are a collection)
for item in parsers:crowdsecurity/caddy-logs parsers:crowdsecurity/whitelists \
            collections:crowdsecurity/http-cve scenarios:crowdsecurity/http-bad-user-agent; do
    kind=\${item%%:*}; name=\${item#*:}
    cscli \$kind list -o raw --error 2>/dev/null | grep -q "^\$name," || { [ "\$CHECK" = 1 ] && say "would install \$kind \$name" || { cscli \$kind install "\$name" --error >/dev/null; changed=1; }; }
done
want_scn='$(printf '%s' "${SCENARIO}" | sed "s/'/'\\\\''/g")'
if [ "\$(cat "\$CS/scenarios/tappaas-http-login-bf.yaml" 2>/dev/null)" != "\$want_scn" ]; then
    [ "\$CHECK" = 1 ] && say "would write the TAPPaaS sign-in brute-force scenario" || { printf '%s\n' "\$want_scn" > "\$CS/scenarios/tappaas-http-login-bf.yaml"; changed=1; }
fi
want_acq='filenames:
  - /var/log/caddy/access/*.log
labels:
  type: caddy'
if [ "\$(cat "\$CS/acquis.d/tappaas-caddy.yaml" 2>/dev/null)" != "\$want_acq" ]; then
    [ "\$CHECK" = 1 ] && say "would read Caddy's access logs" || { printf '%s\n' "\$want_acq" > "\$CS/acquis.d/tappaas-caddy.yaml"; changed=1; }
fi
# 4. who it never bans: the site's own IPv6 networks (not the WAN's)
wan=\$(route -6 get default 2>/dev/null | awk '/interface/ {print \$2}')
nets=\$(for i in \$(ifconfig -l); do [ "\$i" = "\$wan" ] && continue; ifconfig \$i inet6 2>/dev/null | awk '/inet6/ && \$2 !~ /^fe80/ && \$2 != "::1" && \$4 == 64 {print \$2}'; done \\
    | /usr/local/bin/python3 -c 'import sys, ipaddress; print("\n".join(sorted({str(ipaddress.ip_network(l.strip() + "/64", strict=False)) for l in sys.stdin if l.strip()})))')
wl="name: tappaas/site-whitelist
description: \"The site's own clients: its internal IPv6 networks (private IPv4 is crowdsecurity/whitelists)\"
whitelist:
  reason: \"a TAPPaaS site's own network\"
  cidr:"
for n in \$nets; do wl="\$wl
    - \"\$n\""; done
[ -n "\$nets" ] || wl="\$wl []"
if [ "\$(cat "\$CS/parsers/s02-enrich/tappaas-site-whitelist.yaml" 2>/dev/null)" != "\$wl" ]; then
    [ "\$CHECK" = 1 ] && say "would whitelist the site's IPv6 networks: \$(echo \$nets)" || { mkdir -p "\$CS/parsers/s02-enrich"; printf '%s\n' "\$wl" > "\$CS/parsers/s02-enrich/tappaas-site-whitelist.yaml"; changed=1; }
fi
[ "\$changed" = 1 ] && [ "\$CHECK" != 1 ] && { service crowdsec reload >/dev/null 2>&1 || service crowdsec restart >/dev/null; say "crowdsec reloaded"; }
# report
cscli capi status --error >/dev/null 2>&1 && say "WARNING: registered with the central API" || say "central API: not registered (local only)"
service crowdsec status >/dev/null 2>&1 && say "crowdsec: running" || say "crowdsec: NOT running"
service crowdsec_firewall status >/dev/null 2>&1 && say "firewall bouncer: running" || say "firewall bouncer: NOT running"
say "active bans: \$(cscli decisions list -o json --error 2>/dev/null | /usr/local/bin/python3 -c 'import sys, json; d = json.load(sys.stdin) or []; print(sum(len(a.get("decisions") or []) for a in d))' 2>/dev/null || echo 0)"
EOF
