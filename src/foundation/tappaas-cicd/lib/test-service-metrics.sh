#!/usr/bin/env bash
#
# test-service-metrics.sh — unit tests for lib/service-metrics.sh (ADR-046
# P3). Offline: no CMDB, no firewall, no logging VM.
#
#   - the level comes from P2's cascade when present, else the site's;
#   - the routes come from the CMDB's proxy-routes, one per host, cached;
#   - only routes whose module is at service are scraped and probed;
#   - a module's exporters render only at service, from an official module,
#     with its keep-list; a Community module's block renders nothing;
#   - the identity module gives the controller's route series the route's
#     identity, and nobody else's;
#   - the module dashboard and logging's own scrapes follow the declaration;
#   - the guest pipeline carries the extra blocks, even at level off;
#   - the Caddy files bind the firewall's mgmt address and admit the controller.
#
# Usage: test-service-metrics.sh   (prints "Results: N passed, M failed"; exit 1 on fail)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info(){ :; }; warn(){ :; }; error(){ :; }; debug(){ :; }
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
export CONFIG_DIR="${T}/config" LOG_SHIPPING_CRED_DIR="${T}/cred" LOG_SHIPPING_ADMIN_FILE="${T}/admin" \
       METRICS_IDENTITY_CACHE="${T}/identity-cache.json" SERVICE_ROUTES_CACHE="${T}/routes-cache.json"
mkdir -p "${CONFIG_DIR}/environments" "${T}/bin"
export PATH="${T}/bin:${PATH}"
# shellcheck source=metrics-shipping.sh
. "${HERE}/metrics-shipping.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); }
no(){ fail=$((fail+1)); echo "FAIL: $1"; }
eq(){ [[ "$1" == "$2" ]] && ok || no "$3 (got '$1', want '$2')"; }
has(){ grep -qF -- "$2" <<<"$1" && ok || no "$3"; }
hasnt(){ grep -qF -- "$2" <<<"$1" && no "$3" || ok; }
balanced(){ [[ "$(tr -cd '{' <<<"$1" | wc -c)" -eq "$(tr -cd '}' <<<"$1" | wc -c)" ]] && ok || no "$2: braces do not balance"; }

R1=f2d2826e-5c9f-4d41-9234-9b8fb8af8811
R2=50fc6a8d-90f0-4200-b999-842b74e5d83b
R3=c7af0d1d-0000-4000-8000-000000000003
# A fake cmdb: the proxy-routes of a site, one with a path, one ended, one not ours.
cat > "${T}/bin/cmdb" <<EOF
#!/usr/bin/env bash
[[ "\$1 \$2" == "query proxy-route" ]] || exit 1
[[ -f "${T}/cmdb-down" ]] && exit 1
cat <<'J'
[{"id":"${R1}","name":"cloud.hrossen.dk","attributes":{"host":"cloud.hrossen.dk","description":"TAPPaaS: nextcloud"}},
 {"id":"${R2}","name":"identity.hrossen.dk","attributes":{"host":"identity.hrossen.dk","description":"TAPPaaS: identity"}},
 {"id":"${R3}","name":"karakeep.hrossen.dk","attributes":{"host":"karakeep.hrossen.dk","description":"TAPPaaS: karakeep"}},
 {"id":"aaaaaaaa-0000-4000-8000-000000000004","name":"jellyfin.hrossen.dk/metrics*","attributes":{"host":"jellyfin.hrossen.dk","path":"/metrics*","description":"TAPPaaS: jellyfin /metrics*"}},
 {"id":"aaaaaaaa-0000-4000-8000-000000000005","name":"old.hrossen.dk","ended":"2026-10-01T00:00:00Z","attributes":{"host":"old.hrossen.dk","description":"TAPPaaS: old"}},
 {"id":"aaaaaaaa-0000-4000-8000-000000000006","name":"x.example.org","attributes":{"host":"x.example.org","description":"hand-made"}}]
J
EOF
chmod +x "${T}/bin/cmdb"

echo '{"name":"s","size":"medium","performance":{"level":"basic"}}' > "${CONFIG_DIR}/site.json"
echo '{"vmname":"logging","zone0":"mgmt","environment":"mgmt"}' > "${CONFIG_DIR}/logging.json"
echo '{"vmname":"nextcloud","environment":"rossen","performance":{"level":"service"}}' > "${CONFIG_DIR}/nextcloud.json"
echo '{"vmname":"identity","environment":"mgmt"}' > "${CONFIG_DIR}/identity.json"
echo '{"vmname":"karakeep","environment":"rossen"}' > "${CONFIG_DIR}/karakeep.json"
echo '{"vmname":"tappaas-cicd","environment":"mgmt"}' > "${CONFIG_DIR}/tappaas-cicd.json"

# ── the level: P2's cascade when present ─────────────────────────────
eq "$(service_metrics_level nextcloud)" service "the module's own level (cascade)"
eq "$(service_metrics_level karakeep)" basic "a module without one: the site's"
echo '{"name":"rossen","performance":{"level":"service"}}' > "${CONFIG_DIR}/environments/rossen.json"
eq "$(service_metrics_level karakeep)" service "its environment's"
rm "${CONFIG_DIR}/environments/rossen.json"
eq "$( unset -f metrics_effective; service_metrics_level nextcloud )" basic "without the cascade: the site's level"

# ── the routes ───────────────────────────────────────────────────────
routes="$(service_routes_json)"
eq "$(jq -r '[.[].host] | join(",")' <<<"${routes}")" "cloud.hrossen.dk,identity.hrossen.dk,karakeep.hrossen.dk" "one per host, not ended, not with a path, ours only"
eq "$(jq -r '.[] | select(.host == "cloud.hrossen.dk") | [.id, .module, .ns] | join(" ")' <<<"${routes}")" "${R1} nextcloud rossen" "a route's id, module and namespace"
touch "${T}/cmdb-down"
eq "$(service_routes_json | jq length)" 3 "the CMDB down: the cached routes"
rm "${T}/cmdb-down"
eq "$(service_routes_wanted | jq -r '[.[].host] | join(",")')" "cloud.hrossen.dk" "only nextcloud's route is at service"

# ── a module's declaration ───────────────────────────────────────────
eq "$(perf_keep_regex 'authentik_*_total' 'pg_up' 'bad name' 'a{1}')" 'authentik_.*_total|pg_up' "globs to a regex, anything else dropped"
cat > "${CONFIG_DIR}/identity.json" <<'J'
{"vmname":"identity","environment":"mgmt","performance":{"level":"service","exporters":[
  {"name":"authentik","port":9301,"path":"/metrics","level":"service","keep":["authentik_*_total","authentik_*_seconds_*"]},
  {"name":"postgres","port":9187,"keep":["pg_up","pg_stat_database_*"]},
  {"name":"evil","port":"80; rm -rf /","keep":["x"]}]}}
J
blocks="$(render_service_blocks identity service)"
has "${blocks}" 'prometheus.scrape "exp_authentik"' "the authentik exporter is scraped"
has "${blocks}" '"__address__" = "127.0.0.1:9301"' "on the guest, at its port"
has "${blocks}" 'regex         = "authentik_.*_total|authentik_.*_seconds_.*"' "with its keep-list"
has "${blocks}" 'prometheus.scrape "exp_postgres"' "postgres, its level defaulting to service"
hasnt "${blocks}" 'evil' "an exporter with a bad port renders nothing"
balanced "${blocks}" "the exporter blocks"
eq "$(render_service_blocks identity basic)" "" "below service: nothing"
jq '.source = "community"' "${CONFIG_DIR}/identity.json" > "${T}/x" && mv "${T}/x" "${CONFIG_DIR}/identity.json"
eq "$(render_service_blocks identity service)" "" "a Community module's block renders nothing"
eq "$(perf_declaration_of identity)" "{}" "and declares nothing"
jq 'del(.source)' "${CONFIG_DIR}/identity.json" > "${T}/x" && mv "${T}/x" "${CONFIG_DIR}/identity.json"

# ── the controller: Caddy and probes for the wanted routes ───────────
jq 'del(.performance.level)' "${CONFIG_DIR}/identity.json" > "${T}/x" && mv "${T}/x" "${CONFIG_DIR}/identity.json"
ctl="$(render_service_blocks tappaas-cicd off)"
has "${ctl}" '"__address__" = "firewall.mgmt.internal:9180"' "Caddy scraped on the firewall"
has "${ctl}" 'regex         = "cloud\\.hrossen\\.dk"' "only the wanted hosts, dots escaped"
hasnt "${ctl}" 'karakeep.hrossen.dk' "a route below service is neither scraped nor probed"
has "${ctl}" 'target_label  = "tappaas_route"' "the host moves to tappaas_route"
has "${ctl}" 'replacement   = "${1}xx"' "the status code is bucketed"
has "${ctl}" 'regex  = "host|handler|server|method|path|uri|instance"' "host and anything path-like dropped"
has "${ctl}" 'address = "https://cloud.hrossen.dk/"' "the route is probed over HTTPS"
has "${ctl}" 'labels  = {"tappaas_route" = "cloud.hrossen.dk"}' "the probe names its route"
balanced "${ctl}" "the controller blocks"
jq 'del(.performance)' "${CONFIG_DIR}/nextcloud.json" > "${T}/x" && mv "${T}/x" "${CONFIG_DIR}/nextcloud.json"
eq "$(render_service_blocks tappaas-cicd off)" "" "no route at service: no Caddy, no probes"
echo '{"vmname":"nextcloud","environment":"rossen","performance":{"level":"service"}}' > "${CONFIG_DIR}/nextcloud.json"

# ── the guest pipeline carries them ──────────────────────────────────
p="$(render_metrics_alloy tappaas-cicd off normal guest "${ctl}")"
has "${p}" 'otelcol.exporter.otlphttp "perf"' "at level off with extra blocks: the push is there"
has "${p}" 'prometheus.scrape "caddy"' "and the blocks"
hasnt "${p}" 'prometheus.exporter.unix' "but not the host's own numbers"
balanced "${p}" "the pipeline at off"
p="$(render_metrics_alloy tappaas-cicd basic normal guest "${ctl}")"
has "${p}" 'prometheus.exporter.unix' "at basic: the host's numbers"
has "${p}" 'prometheus.exporter.blackbox "routes"' "and the probes"
balanced "${p}" "the pipeline at basic"
eq "$(render_metrics_alloy tappaas-cicd off normal guest "" | tail -1)" "${LOG_SHIPPING_PERF_DEFAULT}" "off and nothing extra: the empty pipeline"

# ── identity for routes ──────────────────────────────────────────────
map="$(jq -nc --arg r1 "${R1}" '{cluster:"pvecluster", nodes:[], hosts:{}, guests:{}, ids:{}, controller:"tappaas-cicd",
  routes:[{host:"cloud.hrossen.dk", id:$r1, module:"nextcloud", ns:"rossen"},
          {host:"bad host", id:$r1, module:"x", ns:""}, {host:"y.hrossen.dk", id:"nope", module:"y", ns:""}]}')"
ident="$(render_metrics_identity "${map}")"
has "${ident}" 'regex         = "tappaas-cicd;cloud\\.hrossen\\.dk"' "only the controller's series about the route"
has "${ident}" "replacement   = \"${R1}\"" "get the route's id"
has "${ident}" 'replacement   = "nextcloud"' "and its module"
has "${ident}" 'target_label  = "tappaas_module"' "as tappaas_module"
hasnt "${ident}" 'bad host' "a host that is not a name is left out"
hasnt "${ident}" 'y.hrossen.dk' "a route without an id is left out"
has "${ident}" 'regex  = "tappaas_route"' "tappaas_route is dropped after"
balanced "${ident}" "the identity module"
nomap="$(jq -c 'del(.controller)' <<<"${map}")"
hasnt "$(render_metrics_identity "${nomap}")" 'tappaas_route"]' "no controller: no route rules"

# ── dashboards and logging's own exporters ───────────────────────────
d="$(render_module_dashboard identity)"
eq "$(jq -r .uid <<<"${d}")" "tappaas-mod-identity" "the module dashboard's uid"
eq "$(jq '.panels | length' <<<"${d}")" 4 "a panel per kept pattern"
has "$(jq -r '.panels[0].targets[0].expr' <<<"${d}")" 'rate({__name__=~"authentik_.*_total", tappaas_ci_id="$ci"}[5m])' "a counter as a rate, for the chosen CI"
eq "$(jq -r '.templating.list[0].name' <<<"${d}")" ci "the CI is a variable"
cat > "${CONFIG_DIR}/logging.json" <<'J'
{"vmname":"logging","zone0":"mgmt","environment":"mgmt","performance":{"exporters":[
  {"name":"grafana","port":3000,"keep":["grafana_http_request_duration_seconds_*"]},
  {"name":"loki","port":3102,"keep":["loki_request_duration_seconds_*","loki_ingester_streams"]}]}}
J
s="$(render_self_alloy service)"
has "${s}" 'prometheus.scrape "grafana"' "logging scrapes its Grafana"
has "${s}" 'forward_to = argument.forward_to.value' "into the receiver's pipeline"
has "${s}" 'replacement  = "logging"' "as its own host"
balanced "${s}" "the self module"
s="$(render_self_alloy basic)"
hasnt "${s}" 'prometheus.scrape' "below service: an empty module"
has "${s}" 'argument "forward_to"' "that still declares its argument"

# ── the Caddy files ──────────────────────────────────────────────────
getent() { echo "10.0.0.1   STREAM firewall.mgmt.internal"; }
ip() { echo "10.0.0.1 dev ens18 src 10.0.0.209 uid 1000"; }
f="$(_sm_caddy_files)"
g="${f%%$'\x1e'*}"; c="${f#*$'\x1e'}"
has "${g}" 'per_host' "Caddy counts per host"
has "${c}" 'bind 10.0.0.1' "the listener binds the mgmt address only"
has "${c}" 'remote_ip 10.0.0.209/32' "and admits the controller"
has "${c}" 'respond 403' "everyone else is refused"
balanced "${c}" "the site block"

echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
