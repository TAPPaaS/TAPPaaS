#!/usr/bin/env bash
#
# test-metrics-shipping.sh — unit tests for lib/metrics-shipping.sh (ADR-046
# P1). Offline: no node, no CMDB, no logging VM.
#
#   - the level and retention follow site.json, else the site's size;
#   - the identity module stamps hosts and guests, drops what a sender says,
#     lets only the cluster's credential speak for nodes and only nodes for
#     guests, and leaves out anything that is not a plain name, id or vmid;
#   - the CMDB map is built from nodes and the PBS app, and cached;
#   - the PVE target's state follows the level and the credential.
#
# Usage: test-metrics-shipping.sh   (prints "Results: N passed, M failed"; exit 1 on fail)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info(){ :; }; warn(){ :; }; error(){ :; }; debug(){ :; }
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
export CONFIG_DIR="${T}/config" LOG_SHIPPING_CRED_DIR="${T}/cred" LOG_SHIPPING_ADMIN_FILE="${T}/admin" \
       METRICS_IDENTITY_CACHE="${T}/identity-cache.json"
mkdir -p "${CONFIG_DIR}"
# shellcheck source=metrics-shipping.sh
. "${HERE}/metrics-shipping.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); }
no(){ fail=$((fail+1)); echo "FAIL: $1"; }
eq(){ [[ "$1" == "$2" ]] && ok || no "$3 (got '$1', want '$2')"; }

# ── level and retention ──────────────────────────────────────────────
echo '{}' > "${CONFIG_DIR}/site.json"
eq "$(metrics_level)" basic "no size, no level → basic"
eq "$(metrics_retention_days)" 15 "medium → 15 days"
echo '{"size":"small"}' > "${CONFIG_DIR}/site.json"
eq "$(metrics_level)" off "small → off"
eq "$(metrics_retention_days)" 7 "small → 7 days"
echo '{"size":"large","performance":{"retentionDays":45}}' > "${CONFIG_DIR}/site.json"
eq "$(metrics_level)" basic "large → basic"
eq "$(metrics_retention_days)" 45 "retentionDays wins"
echo '{"size":"small","performance":{"level":"basic","retentionDays":0}}' > "${CONFIG_DIR}/site.json"
eq "$(metrics_level)" basic "a set level wins over the size"
eq "$(metrics_retention_days)" 7 "an out-of-range retention falls back to the size"
echo '{"performance":{"level":"trace"}}' > "${CONFIG_DIR}/site.json"
eq "$(metrics_level)" service "trace is never standing: read as service"
echo '{"performance":{"level":"loud"}}' > "${CONFIG_DIR}/site.json"
eq "$(metrics_level 2>/dev/null)" basic "an unknown level falls back to the default"
echo '{}' > "${CONFIG_DIR}/site.json"
metrics_wanted && no "wanted without logging" || ok
echo '{}' > "${CONFIG_DIR}/logging.json"
metrics_wanted && ok || no "not wanted with logging at basic"

# ── the identity module ──────────────────────────────────────────────
N1=c11c3e17-fe34-4bd7-bed6-6f8b259469c8
G1=ebf1c948-fb06-4806-b502-234fdf036669
P1=1d05f892-79d6-4dd8-8b5a-a360256112f5
map="$(jq -nc --arg n1 "${N1}" --arg g1 "${G1}" --arg p1 "${P1}" '{
  cluster: "pvecluster", nodes: ["tappaas1", "tappaas2", "bad node"],
  hosts: {tappaas1: $n1, logging: $g1, backup: $p1, "evil\"x": $g1, nocid: "not-a-uuid"},
  guests: {"150": $g1, "15x": $g1},
  ids: {($n1): {name: "tappaas1", ns: "mgmt"}, ($g1): {name: "logging", ns: "mgmt"}, ($p1): {name: "backup", ns: "mgmt"}}}')"
render_metrics_identity "${map}" > "${T}/identity.alloy" || no "render failed"
A="${T}/identity.alloy"
grep -q '^declare "stamp" {' "${A}" && grep -q 'export "receiver"' "${A}" && ok || no "no declare/export"
# Braces balance (a cheap syntax check: no alloy here).
[[ "$(tr -cd '{' < "${A}" | wc -c)" -eq "$(tr -cd '}' < "${A}" | wc -c)" ]] && ok || no "braces do not balance"
grep -q 'regex  = "tappaas_ci_id|service_instance_id|service_name|service_namespace|deployment_environment_name|instance|tappaas_node|tappaas_module"' "${A}" \
    && ok || no "sender identity labels are not dropped first"
[[ "$(grep -n 'labeldrop' "${A}" | head -1 | cut -d: -f1)" -lt "$(grep -n 'target_label  = "tappaas_ci_id"' "${A}" | head -1 | cut -d: -f1)" ]] \
    && ok || no "the drop does not come before the stamps"
grep -q 'regex         = "pvecluster;(tappaas1|tappaas2)"' "${A}" && ok || no "the cluster credential does not map to its nodes"
grep -q 'bad node' "${A}" && no "a node name with a space got in" || ok
grep -q 'evil' "${A}" && no "a host name with a quote got in" || ok
grep -q 'nocid' "${A}" && no "a host without a CI id got in" || ok
grep -q '15x' "${A}" && no "a non-numeric vmid got in" || ok
grep -A2 'source_labels = \["host"\]' "${A}" | grep -q 'regex         = "pvecluster"' && ok || no "leftover cluster pushes are not dropped"
grep -B3 'action        = "drop"' "${A}" | grep -q 'regex         = ";.+"' && ok || no "a non-node's vmid series are not dropped"
# tappaas1 as itself: five labels; logging (vmid 150) as the guest, keyed on the node flag.
[[ "$(grep -c 'replacement   = "'"${N1}"'"' "${A}")" -eq 2 ]] && ok || no "tappaas1's id is not on tappaas_ci_id and service_instance_id"
grep -B3 'target_label  = "service_name"' "${A}" | grep -q 'regex         = "1;150"' && ok || no "guest 150 is not stamped from the node's series"
grep -A3 'regex         = "1;150"' "${A}" | grep -q 'replacement   = "logging"' && ok || no "guest 150 is not named logging"
grep -q 'replacement   = "mgmt"' "${A}" && ok || no "the namespace is missing"
[[ "$(grep -c 'regex         = "backup"' "${A}")" -eq 5 ]] && ok || no "the PBS instance does not get its five labels"
sed '/^declare "stamp_traces"/,$d' "${A}" | tail -12 | grep -q 'regex  = "tappaas_node"' && ok || no "the node flag is not dropped at the end"
# No nodes known: no cluster mapping, the cluster's pushes dropped all the same.
render_metrics_identity '{"cluster":"pvecluster","nodes":[],"hosts":{},"guests":{},"ids":{}}' > "${T}/empty.alloy"
grep -q 'pvecluster;' "${T}/empty.alloy" && no "an empty map maps the cluster" || ok
grep -q 'regex         = "pvecluster"' "${T}/empty.alloy" && ok || no "an empty map lets the cluster's pushes through"

# ── the map from the CMDB, cached ────────────────────────────────────
echo '{"defaultEnvironment":"home"}' > "${CONFIG_DIR}/site.json"
echo '{"environment":"mgmt"}' > "${CONFIG_DIR}/tappaas1.json"
echo '{"environment":"rossen","vmid":340}' > "${CONFIG_DIR}/nextcloud.json"
echo '{"kind":"application","moduleSource":"/x/src/foundation/backup","node":"tappaas3","environment":"mgmt"}' > "${CONFIG_DIR}/backup.json"
cmdb() {
    case "$1 $2" in
        "query node") jq -nc --arg n1 "${N1}" --arg g1 "${G1}" '[
            {id: $n1, class: "machine", name: "tappaas1", attributes: {}},
            {id: $g1, class: "vm", name: "nextcloud", attributes: {vmid: 340}},
            {id: "ab1ce443-0026-4d0c-9579-2cf6c2904a9b", class: "device", name: "crs-a", attributes: {}}]' ;;
        "show backup") jq -nc --arg p1 "${P1}" '{id: $p1, class: "app", name: "backup"}' ;;
        *) return 1 ;;
    esac
}
m="$(metrics_identity_json 2>/dev/null)"
eq "$(jq -r '.nodes | join(",")' <<<"${m}")" tappaas1 "nodes are the machines"
eq "$(jq -r '.guests["340"]' <<<"${m}")" "${G1}" "a guest by its vmid"
eq "$(jq -r '.hosts.backup' <<<"${m}")" "${P1}" "the PBS app is a host"
eq "$(jq -r '.hosts["crs-a"] // "none"' <<<"${m}")" none "a device is not a host"
eq "$(jq -r --arg g "${G1}" '.ids[$g].ns' <<<"${m}")" rossen "the namespace is the instance's environment"
[[ -s "${METRICS_IDENTITY_CACHE}" ]] && ok || no "the map was not cached"
cmdb() { return 1; }
eq "$(metrics_identity_json 2>/dev/null | jq -r '.hosts.tappaas1')" "${N1}" "the CMDB down: the cached map stands"
rm -f "${METRICS_IDENTITY_CACHE}"
eq "$(metrics_identity_json 2>/dev/null | jq -c '.hosts')" '{}' "the CMDB down and nothing cached: no identities"
unset -f cmdb

# ── the PVE target's state ───────────────────────────────────────────
get_all_node_hostnames() { echo tappaas1; }
PVE_JSON="" SAMPLER_SUM=""
fake_node() { # what a node answers to metrics_pve_state's probe
    local cmd="${*: -1}"
    [[ "${cmd}" == true ]] && return 0
    printf '%s\n%s\n' "${PVE_JSON}" "${SAMPLER_SUM}"
}
METRICS_NODE_SSH=fake_node
echo '{}' > "${CONFIG_DIR}/site.json"
eq "$(metrics_pve_state)" missing "level basic, nothing set → missing"
PVE_JSON="$(jq -nc --arg h "$(_ms_pve_headers)" '{type:"opentelemetry", server:"logging.mgmt.internal", port:3120, "otel-headers":$h}')"
SAMPLER_SUM="$(_ms_sampler_conf | sha256sum | cut -d' ' -f1)"
eq "$(metrics_pve_state)" in-sync "set as wanted → in-sync"
PVE_JSON="$(jq -c '.port = 3101' <<<"${PVE_JSON}")"
eq "$(metrics_pve_state)" stale "another port → stale"
PVE_JSON="$(jq -c '.port = 3120' <<<"${PVE_JSON}")"; SAMPLER_SUM="x"
eq "$(metrics_pve_state)" stale "the sampler's file differs → stale"
echo '{"performance":{"level":"off"}}' > "${CONFIG_DIR}/site.json"
eq "$(metrics_pve_state)" unwanted "level off, still set → unwanted"
PVE_JSON="" SAMPLER_SUM=""
eq "$(metrics_pve_state)" absent "level off, nothing set → absent"
# shellcheck disable=SC2034  # read by metrics_pve_state
METRICS_NODE_SSH=false
eq "$(metrics_pve_state)" unknown "no node answers → unknown"
# The header the cluster sends is basic auth of the cluster's own credential.
echo '{}' > "${CONFIG_DIR}/site.json"
h="$(_ms_pve_headers | base64 -d | jq -r '.Authorization' | sed 's/^Basic //' | base64 -d)"
eq "${h}" "pvecluster:$(cat "${LOG_SHIPPING_CRED_DIR}/pvecluster")" "the cluster pushes with its credential from the store"
# PBS's InfluxDB token line, for nginx's map.
eq "$(_ms_influx_map)" "\"Token backup:$(cat "${LOG_SHIPPING_CRED_DIR}/backup")\" \"backup\";" "the PBS token maps to its instance"


# ── the cascade (P2) ─────────────────────────────────────────────────
mkdir -p "${CONFIG_DIR}/environments"
echo '{"size":"medium"}' > "${CONFIG_DIR}/site.json"
echo '{"name":"rossen"}' > "${CONFIG_DIR}/environments/rossen.json"
echo '{"kind":"vm","vmname":"web","environment":"rossen","zone0":"srv"}' > "${CONFIG_DIR}/web.json"
eff(){ metrics_effective web | jq -r "$1"; }
eq "$(eff '.level + " " + .source')" "basic site (by size)" "nothing set: the site's default by size"
echo '{"size":"medium","performance":{"level":"off"}}' > "${CONFIG_DIR}/site.json"
eq "$(eff '.level + " " + .source')" "off site" "the site's level"
echo '{"name":"rossen","performance":{"level":"service","resolution":"fine"}}' > "${CONFIG_DIR}/environments/rossen.json"
eq "$(eff '.level + " " + .source + " " + .resolution')" "service environment rossen fine" "an environment overrides the site"
echo '{"kind":"vm","vmname":"web","environment":"rossen","performance":{"level":"basic"}}' > "${CONFIG_DIR}/web.json"
eq "$(eff '.level + " " + .source + " " + .resolution')" "basic module fine" "a module overrides its environment; its resolution inherits"
echo '{"kind":"vm","vmname":"web","environment":"rossen","performance":{"level":"trace"}}' > "${CONFIG_DIR}/web.json"
eq "$(eff .level)" service "a module record saying trace reads as service"
now_plus(){ date -u -d "@$(( $(date +%s) + $1 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$(( $(date +%s) + $1 ))" +%Y-%m-%dT%H:%M:%SZ; }
jq -n --arg u "$(now_plus 3600)" '{investigations: [{module: "web", level: "trace", resolution: "fine", ended: null, until: $u}], history: []}' > "${CONFIG_DIR}/performance-raises.json"
eq "$(eff '.level + " " + .from + " " + (.raise.until != null | tostring)')" "trace service true" "an active raise wins and keeps where it came from"
jq -n --arg u "$(now_plus -60)" '{investigations: [{module: "web", level: "trace", ended: null, until: $u}], history: []}' > "${CONFIG_DIR}/performance-raises.json"
eq "$(eff '.level + " " + (.raise == null | tostring)')" "service true" "a raise past its time counts for nothing"
rm -f "${CONFIG_DIR}/performance-raises.json"
echo '{"kind":"lxc","vmname":"ct1","environment":"rossen"}' > "${CONFIG_DIR}/ct1.json"
eq "$(metrics_class_of ct1)/$(metrics_class_of web)" "lxc/guest" "a container's class"

# ── the guest pipeline ───────────────────────────────────────────────
R="${T}/perf.alloy"
render_metrics_alloy web off normal guest > "${R}"
grep -q '^declare "pipeline" { argument "off" { optional = true } }$' "${R}" && ! grep -q exporter "${R}" && ok || no "level off is not an empty pipeline"
render_metrics_alloy web basic normal guest > "${R}"
grep -q 'scrape_interval = "60s"' "${R}" && grep -q 'username = "web"' "${R}" && grep -q 'endpoint = "https://logging.mgmt.internal:3120"' "${R}" && ok || no "basic: interval, username or endpoint wrong"
grep -q 'node_netstat' "${R}" && no "basic carries the service keep-list" || ok
grep -q 'CREDENTIALS_DIRECTORY' "${R}" && ! grep -qiE 'password *= *"' "${R}" && ok || no "the push secret is not read from the credential"
[[ "$(tr -cd '{' < "${R}" | wc -c)" -eq "$(tr -cd '}' < "${R}" | wc -c)" ]] && ok || no "basic pipeline braces do not balance"
render_metrics_alloy web service fine lxc > "${R}"
grep -q 'scrape_interval = "15s"' "${R}" && grep -q 'node_netstat' "${R}" && grep -q '"netstat"' "${R}" && ok || no "service/fine: interval or keep-list wrong"
grep -q 'regex         = "node_pressure_.\*|node_boot_time_seconds"' "${R}" && ok || no "a container keeps its node's pressure"
grep -q 'level service' <<<"$(render_metrics_alloy web trace normal guest)" && ok || no "trace does not render as service"
render_metrics_alloy 'bad host' basic normal guest >/dev/null 2>&1 && no "a bad host was rendered" || ok
render_metrics_alloy web loud normal guest >/dev/null 2>&1 && no "a bad level was rendered" || ok
# The rendered file follows the cascade and switches off with the store.
echo '{"size":"medium"}' > "${CONFIG_DIR}/site.json"
echo '{"kind":"vm","vmname":"web","environment":"rossen","performance":{"level":"service"}}' > "${CONFIG_DIR}/web.json"
grep -q 'level service, resolution fine' <<<"$(metrics_guest_render web)" && ok || no "the render does not follow the cascade"
mv "${CONFIG_DIR}/logging.json" "${CONFIG_DIR}/logging.json.x"
grep -q 'level off' <<<"$(metrics_guest_render web)" && ok || no "without logging the guest renders a pipeline"
mv "${CONFIG_DIR}/logging.json.x" "${CONFIG_DIR}/logging.json"
metrics_purge not-an-id 2>/dev/null && no "purge took something that is not a CI id" || ok


# ── traces (P6) ──────────────────────────────────────────────────────
# The spans' identity: the sender's identity attributes go first, then each
# host's CI from tappaas.host; nothing that is not a plain name or id.
render_metrics_identity "${map}" > "${T}/idt.alloy"
TR="$(sed -n '/^declare "stamp_traces"/,$p' "${T}/idt.alloy")"
grep -q 'otelcol.processor.transform "stamp"' <<<"${TR}" && grep -q 'export "input"' <<<"${TR}" && ok || no "no stamp_traces declare"
[[ "$(grep -n 'delete_key(attributes, "tappaas.ci.id")' <<<"${TR}" | cut -d: -f1)" -lt "$(grep -n "set(attributes\[\"tappaas.ci.id\"\]" <<<"${TR}" | head -1 | cut -d: -f1)" ]] \
    && ok || no "the sender's tappaas.ci.id is not deleted before the stamp"
grep -qF "set(attributes[\"tappaas.ci.id\"], \"${N1}\") where attributes[\"tappaas.host\"] == \"tappaas1\"" <<<"${TR}" && ok || no "tappaas1's spans are not stamped"
grep -qF "set(attributes[\"service.namespace\"], \"mgmt\") where attributes[\"tappaas.host\"] == \"backup\"" <<<"${TR}" && ok || no "the namespace is not set on spans"
grep -q 'evil\|nocid' <<<"${TR}" && no "an unsafe host reached the span statements" || ok
grep -q 'set(attributes\["service.name"\]' <<<"${TR}" && no "service.name is overwritten (it is the sender's software)" || ok
[[ "$(tr -cd '{' <<<"${TR}" | wc -c)" -eq "$(tr -cd '}' <<<"${TR}" | wc -c)" ]] && ok || no "stamp_traces braces do not balance"
# Which CIs are traced, and what the logging VM should run.
now_plus2(){ date -u -d "@$(( $(date +%s) + $1 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$(( $(date +%s) + $1 ))" +%Y-%m-%dT%H:%M:%SZ; }
echo '{"vmname":"logging"}' > "${CONFIG_DIR}/logging.json"
rm -f "${CONFIG_DIR}/performance-raises.json"
eq "$(_ms_traces_wanted)" "tempo=off grafana=off" "no raise: Tempo and the senders off"
jq -n --arg u "$(now_plus2 900)" --arg p "$(now_plus2 -60)" '{investigations: [
    {module: "identity", ci: {name: "identity"}, level: "trace", ended: null, until: $u},
    {module: "web", ci: {name: "web"}, level: "service", ended: null, until: $u},
    {module: "old", ci: {name: "old"}, level: "trace", ended: null, until: $p}], history: []}' > "${CONFIG_DIR}/performance-raises.json"
eq "$(metrics_traced_modules | tr '\n' ' ')" "identity " "only an active raise to trace counts"
eq "$(_ms_traces_wanted)" "tempo=on grafana=off" "a trace raise starts Tempo; Grafana only for the logging CI"
jq --arg u "$(now_plus2 900)" '.investigations += [{module: "logging", ci: {name: "logging"}, level: "trace", ended: null, until: $u}]' \
    "${CONFIG_DIR}/performance-raises.json" > "${T}/r.json" && mv "${T}/r.json" "${CONFIG_DIR}/performance-raises.json"
eq "$(_ms_traces_wanted)" "tempo=on grafana=on" "a trace raise on the logging CI switches Grafana's spans on"
mv "${CONFIG_DIR}/logging.json" "${CONFIG_DIR}/logging.json.x"
eq "$(_ms_traces_wanted)" "tempo=off grafana=off" "without logging nothing runs"
mv "${CONFIG_DIR}/logging.json.x" "${CONFIG_DIR}/logging.json"
rm -f "${CONFIG_DIR}/performance-raises.json"

echo "Results: ${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]]
