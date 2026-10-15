#!/usr/bin/env bash
# test-proxy-cidr.sh — proxyAllowedZones may name networks as well as zones
# (#656): a well-formed CIDR goes into the access list as written, next to the
# zones' networks; a malformed one is refused, like an unknown zone (#419).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACL="${HERE}/../../../network/services/proxy/access-list.sh"
W="$(mktemp -d)"; trap 'rm -rf "${W}"' EXIT

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $1 (got '$2', want '$3')"; fi; }

# The lib's environment: logging, the config normalizer, and a caddy-manager
# that records what it was asked to allow.
info() { :; }; debug() { :; }; warn() { :; }; error() { echo "ERR: $*" >> "${W}/err"; }
BL=""; CL=""; YW=""; GN=""; : "${BL}${CL}${YW}${GN}"
normalize_module_config() { cat; }
mkdir -p "${W}/bin"
cat > "${W}/bin/caddy-manager" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  add-accesslist)
    [ "${2:-}" = "--help" ] && { echo "usage --message"; exit 0; }
    while [ $# -gt 0 ]; do [ "$1" = "--clients" ] && echo "$2" > "${STUBLOG}"; shift; done ;;
esac
exit 0
STUB
chmod +x "${W}/bin/caddy-manager"; export PATH="${W}/bin:${PATH}" STUBLOG="${W}/clients"
run_caddy() { caddy-manager "$@"; }
# shellcheck source=../../../network/services/proxy/access-list.sh disable=SC1091
. "${ACL}"
run_caddy() { caddy-manager "$@"; }

echo '{"mgmt":{"ip":"10.0.0.0/24"},"home":{"ip":"10.3.10.0/24"}}' > "${W}/zones.json"
resolve() {  # resolve <proxyAllowedZones json> → "rc|clients"
    rm -f "${W}/clients" "${W}/err"
    echo "{\"proxyAllowedZones\": $1}" > "${W}/m.json"
    local rc=0; proxy_resolve_access_list demo "${W}/m.json" "${W}/zones.json" "TAPPaaS: demo" >/dev/null || rc=$?
    echo "${rc}|$(cat "${W}/clients" 2>/dev/null)"
}

ck "an IPv4 network"                  "$(proxy_cidr_kind 52.112.0.0/14)"  cidr
ck "an IPv6 network"                  "$(proxy_cidr_kind 2603:1063::/38)" cidr
ck "a zone name is not a network"     "$(proxy_cidr_kind home)"           ""
ck "an octet over 255 is malformed"   "$(proxy_cidr_kind 10.0.0.300/24)"  bad
ck "a prefix over 32 is malformed"    "$(proxy_cidr_kind 10.0.0.0/33)"    bad
ck "no prefix is malformed"           "$(proxy_cidr_kind 10.0.0.1)"       bad
ck "an IPv6 prefix over 128"          "$(proxy_cidr_kind 2001:db8::/129)" bad

ck "zones and a provider range in one list" "$(resolve '["mgmt","52.112.0.0/14"]')" "0|10.0.0.0/24,52.112.0.0/14"
ck "only provider ranges"                   "$(resolve '["52.112.0.0/14","2603:1063::/38"]')" "0|52.112.0.0/14,2603:1063::/38"
ck "a malformed range refuses the list"     "$(resolve '["mgmt","52.112.0.0/40"]')" "1|"
ck "…and says which"                        "$(grep -c '52.112.0.0/40' "${W}/err" 2>/dev/null)" "1"
ck "an unknown zone still refuses"          "$(resolve '["mgmt","nosuchzone"]')" "1|"

# The install-time reference check takes a network too, and refuses a bad one
# before anything is created.
eval "$(sed -n '/^validate_module_zone_refs() {/,/^}/p' "${HERE}/../../lib/common-install-routines.sh")"
CONFIG_DIR="${W}"
refs() { echo "{\"proxyAllowedZones\": $1}" > "${W}/r.json"; local rc=0; validate_module_zone_refs "${W}/r.json" demo >/dev/null 2>&1 || rc=$?; echo "${rc}"; }
ck "install check: a zone and a network pass"   "$(refs '["mgmt","52.112.0.0/14","2603:1063::/38"]')" 0
ck "install check: a malformed network fails"   "$(refs '["mgmt","52.112.0.0/40"]')" 1
ck "install check: an unknown zone still fails" "$(refs '["nosuchzone"]')" 1

echo "test-proxy-cidr: ${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]]
