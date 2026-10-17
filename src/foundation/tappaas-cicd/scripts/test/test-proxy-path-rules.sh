#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals set here are read by the sourced access-list.sh
# test-proxy-path-rules.sh — proxyAccess path rules (ADR-023 D1–D4, #642):
# validation, one handle per path with its rule's list and gate, pruning, the
# shared deny-all list for `none`, and route rules keeping their lists.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACL="${HERE}/../../../network/services/proxy/access-list.sh"
W="$(mktemp -d)"; trap 'rm -rf "${W}"' EXIT

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $1 (got '$2', want '$3')"; fi; }

info() { :; }; debug() { :; }; warn() { echo "WARN: $*" >> "${W}/warn"; }; error() { echo "ERR: $*" >> "${W}/err"; }
die() { echo "DIE: $*" >> "${W}/err"; exit 1; }
BL=""; CL=""; YW=""; GN=""; : "${BL}${CL}${YW}${GN}"
normalize_module_config() { cat; }
get_config_value() { echo "${2:-}"; }
mkdir -p "${W}/bin"
cat > "${W}/bin/caddy-manager" <<'STUB'
#!/usr/bin/env bash
if [ "${2:-}" = "--help" ]; then echo "usage --message --path"; exit 0; fi
echo "$*" >> "${STUBLOG}"
exit 0
STUB
chmod +x "${W}/bin/caddy-manager"; export PATH="${W}/bin:${PATH}" STUBLOG="${W}/calls"
# shellcheck source=../../../network/services/proxy/access-list.sh disable=SC1091
. "${ACL}"
run_caddy() { caddy-manager "$@"; }
proxy_prune_domains() { :; }
reset() { : > "${W}/calls"; rm -f "${W}/err" "${W}/warn"; }

echo '{"mgmt":{"ip":"10.0.0.0/24"},"home":{"ip":"10.3.10.0/24"}}' > "${W}/zones.json"
MODULE=hass; ZONES_FILE="${W}/zones.json"; PROXY_PORT=8123

# ── validation ──
chk() { proxy_path_rules_check "$1" | paste -sd'|' -; }
ck "valid rules pass"            "$(chk '[{"paths":["/api/webhook/*"],"zones":["internet"]}]')" ""
ck "a path without /"            "$(chk '[{"paths":["api"],"zones":["mgmt"]}]')" "path api must start with /"
ck "the whole route is refused"  "$(chk '[{"paths":["/*"],"zones":["mgmt"]}]')" "path /* is the whole route — set the route's proxyAllowedZones instead"
ck "no zones"                    "$(chk '[{"paths":["/a"],"zones":[]}]')" "a rule has no zones — delete it instead"
ck "none inside a rule"          "$(chk '[{"paths":["/a"],"zones":["none"]}]')" "none inside a rule admits no one — delete the rule instead"
ck "one path in two rules"       "$(chk '[{"paths":["/a"],"zones":["mgmt"]},{"paths":["/a"],"zones":["home"]}]')" "path /a is in two rules"
ck "identityGate false without a reason" "$(chk '[{"paths":["/hook"],"zones":["internet"],"identityGate":false}]')" "a rule with identityGate false needs a description: who calls these paths and why they cannot sign in (ADR-032 D1)"
ck "…a blank reason is no reason"   "$(chk '[{"paths":["/hook"],"zones":["internet"],"identityGate":false,"description":"  "}]')" "a rule with identityGate false needs a description: who calls these paths and why they cannot sign in (ADR-032 D1)"
ck "…with one, it passes"           "$(chk '[{"paths":["/hook"],"zones":["internet"],"identityGate":false,"description":"Home Assistant Cloud webhooks: signed by a secret ID in the URL"}]')" ""
ck "a gated rule needs no reason"   "$(chk '[{"paths":["/admin/*"],"zones":["mgmt"]}]')" ""

# ── the primary route's rules ──
reset
RULES='[{"paths":["/api/webhook/*"],"zones":["internet"],"identityGate":false,"description":"webhooks signed in their payload"},
        {"paths":["/ui/*","/admin"],"zones":["mgmt"]}]'
( proxy_add_path_rules hass "TAPPaaS: hass" hass.example.org hass.srv.internal 8123 tappaas-hass "${RULES}" '["mgmt","home"]' -- --upstream-http1 )
h() { grep -F -- "--description TAPPaaS: hass $1 --path $1 " "${W}/calls"; }
ck "a handle per path, served without the gate when identityGate is false" \
   "$(h '/api/webhook/*' | grep -c -- '--no-forward-auth')" "1"
ck "…and with no access list (internet)"  "$(h '/api/webhook/*' | grep -c -- '--access-list')" "0"
ck "a gated rule copies the route's gate" "$(h '/ui/*' | grep -o -- '--forward-auth-like TAPPaaS: hass' | head -1)" "--forward-auth-like TAPPaaS: hass"
ck "…with its rule's list, named from its zones" "$(h '/admin' | grep -o -- '--access-list [^ ]*')" "--access-list tappaas-hass:mgmt"
ck "the route's upstream flags reach the path handle" "$(h '/admin' | grep -c -- '--upstream-http1')" "1"
ck "path handles not declared are pruned, the declared kept" \
   "$(grep '^prune-handlers' "${W}/calls" | grep -o -- '--keep TAPPaaS: hass [^ ]*' | sort | paste -sd'|' -)" \
   "--keep TAPPaaS: hass /admin|--keep TAPPaaS: hass /api/webhook/*|--keep TAPPaaS: hass /ui/*"
ck "rule lists not declared are pruned" "$(grep '^prune-accesslists' "${W}/calls" | grep -o -- '--name-prefix [^ ]* --keep [^ ]*')" "--name-prefix tappaas-hass: --keep tappaas-hass:mgmt"
ck "no warnings for useful rules" "$(cat "${W}/warn" 2>/dev/null)" ""

reset
( proxy_add_path_rules hass "TAPPaaS: hass" hass.example.org hass.srv.internal 8123 tappaas-hass '[{"paths":["/x"],"zones":["home","mgmt"]}]' '["mgmt","home"]' )
ck "a rule equal to the route's zones warns" "$(grep -c 'changes nothing' "${W}/warn")" "1"
reset
( proxy_add_path_rules hass "TAPPaaS: hass" hass.example.org hass.srv.internal 8123 tappaas-hass '[]' 'null' )
ck "no rules: every path handle is pruned" "$(grep '^prune-handlers' "${W}/calls" | grep -c -- '--keep')" "0"
reset
( proxy_add_path_rules hass "TAPPaaS: hass" hass.example.org hass.srv.internal 8123 tappaas-hass '[{"paths":["/"],"zones":["mgmt"]}]' 'null' )
ck "an invalid rule stops before any handle" "$(grep -c '^add-handler' "${W}/calls")" "0"

# ── none: the shared deny-all list ──
reset
out="$(proxy_zone_access_list n8n tappaas-n8n#hooks "${ZONES_FILE}" "d" none)"
ck "none → the shared inverted list" "${out}" "tappaas-none"
ck "…created inverted, for every client" "$(grep -c '^add-accesslist tappaas-none --clients 0.0.0.0/0,::/0 --invert' "${W}/calls")" "1"
proxy_zone_access_list n8n x "${ZONES_FILE}" d none mgmt >/dev/null; rc=$?
ck "none with other zones is refused" "${rc}" "1"

# ── a route's rules keep their lists through the route-list prune ──
reset
MODULE=n8n; ACL_ARGS=(--access-list tappaas-n8n); CADDY_DOMAIN_ARGS=()
JSON='{"proxyRoutes":[{"name":"hooks","port":5678,"proxyAllowedZones":["none"],
       "proxyAccess":[{"paths":["/webhook/*"],"zones":["internet"]},{"paths":["/rest/oauth2-credential/callback"],"zones":["mgmt"]}]}]}'
( proxy_add_routes "TAPPaaS: n8n" example.org n8n.srv.internal per-domain )
ck "the route catch-all denies everyone" "$(grep '^add-handler hooks.example.org .*--description TAPPaaS: n8n#hooks ' "${W}/calls" | grep -v -- '--path' | grep -o -- '--access-list [^ ]*')" "--access-list tappaas-none"
ck "its rule paths become handles of the route" "$(grep -c '^add-handler hooks.example.org .*--path' "${W}/calls")" "2"
ck "the route-list prune keeps the route's rule list" \
   "$(grep '^prune-accesslists --name-prefix tappaas-n8n# ' "${W}/calls" | grep -o -- '--keep [^ ]*' | paste -sd'|' -)" "--keep tappaas-n8n#hooks:mgmt"
ck "no errors" "$(cat "${W}/err" 2>/dev/null)" ""

echo "test-proxy-path-rules: ${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]]
