#!/usr/bin/env bash
# test-proxy-route-zones.sh — a proxyRoutes entry may declare its own
# proxyAllowedZones (ADR-023 D2, #643): it then gets its own access list; without
# it the route inherits the module's. Routes no longer declaring their own zones
# have their lists pruned.
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
[ "${2:-}" = "--help" ] && { echo "usage --message"; exit 0; }
echo "$*" >> "${STUBLOG}"
exit 0
STUB
chmod +x "${W}/bin/caddy-manager"; export PATH="${W}/bin:${PATH}" STUBLOG="${W}/calls"
# shellcheck source=../../../network/services/proxy/access-list.sh disable=SC1091
. "${ACL}"
run_caddy() { caddy-manager "$@"; }
proxy_prune_domains() { :; }

echo '{"mgmt":{"ip":"10.0.0.0/24"},"home":{"ip":"10.3.10.0/24"}}' > "${W}/zones.json"
MODULE=demo; ZONES_FILE="${W}/zones.json"; PROXY_PORT=8123
ACL_ARGS=(--access-list tappaas-demo); CADDY_DOMAIN_ARGS=()
JSON='{"proxyRoutes":[
  {"name":"admin","port":9090},
  {"name":"hooks","port":8123,"proxyAllowedZones":["internet"]},
  {"name":"partner","port":7000,"proxyAllowedZones":["mgmt","52.112.0.0/14"]}]}'
( proxy_add_routes "TAPPaaS: demo" example.org demo.srv.internal per-domain ) || echo "add_routes failed" >> "${W}/err"

handler() { grep "^add-handler $1.example.org " "${W}/calls" | grep -o -- '--access-list [^ ]*' | sed 's/--access-list //'; }
ck "a route without its own zones inherits the module's list" "$(handler admin)"   "tappaas-demo"
ck "a route open to the internet gets no list"               "$(handler hooks)"   ""
ck "a route with its own zones gets its own list"            "$(handler partner)" "tappaas-demo#partner"
ck "…built from its zones and networks" \
   "$(grep '^add-accesslist tappaas-demo#partner ' "${W}/calls" | grep -o -- '--clients [^ ]*' | sed 's/--clients //')" "10.0.0.0/24,52.112.0.0/14"
ck "the internet route's own list is removed if it existed" "$(grep -c '^delete-accesslist tappaas-demo#hooks' "${W}/calls")" "1"
ck "undeclared route lists are pruned, the declared one kept" \
   "$(grep '^prune-accesslists' "${W}/calls" | grep -o -- '--name-prefix [^ ]* --keep [^ ]*')" "--name-prefix tappaas-demo# --keep tappaas-demo#partner"
ck "the same-port public route on a restricted module warns" "$(grep -c 'whole app is public under hooks' "${W}/warn" 2>/dev/null)" "1"
ck "no errors" "$(cat "${W}/err" 2>/dev/null)" ""

: > "${W}/calls"; rm -f "${W}/err"
JSON='{"proxyRoutes":[{"name":"bad","port":7000,"proxyAllowedZones":["nosuchzone"]}]}'
( proxy_add_routes "TAPPaaS: demo" example.org demo.srv.internal per-domain ) 2>/dev/null
ck "an unknown zone in a route stops the install" "$(grep -c 'DIE: proxyRoutes .bad.' "${W}/err" 2>/dev/null)" "1"
ck "…before any handler is written" "$(grep -c '^add-handler' "${W}/calls")" "0"

echo "test-proxy-route-zones: ${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]]
