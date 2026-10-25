#!/usr/bin/env bash
# test-proxy-unpublish-quiet.sh — withdrawing a route that is not there prints
# nothing: caddy-manager's "… not found — nothing to delete" lines went straight
# into every update of an unpublished module. They are debug detail now; a
# delete that fails still says what caddy-manager said, and warns.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACL="${HERE}/../../../network/services/proxy/access-list.sh"
W="$(mktemp -d)"; trap 'rm -rf "${W}"' EXIT

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $1 (got '$2', want '$3')"; fi; }

info() { :; }; warn() { echo "WARN: $*"; }; error() { echo "ERR: $*"; }; die() { echo "DIE: $*"; exit 1; }
debug() { [[ "${DBG:-0}" == 1 ]] && echo "DEBUG: $*"; return 0; }
BL=""; CL=""; YW=""; GN=""; : "${BL}${CL}${YW}${GN}"
mkdir -p "${W}/bin"
cat > "${W}/bin/caddy-manager" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  delete-handler) echo "OK"; echo "Handler '${3}' not found — nothing to delete"; [[ -n "${FAIL_DELETE:-}" ]] && { echo "ERROR: API refused" >&2; exit 1; } ;;
  delete-domain)  echo "Domain '${2}' not found — nothing to delete" ;;
  prune-handlers) [[ "${2:-}" == --help ]] && exit 0 ;;
esac
exit 0
STUB
chmod +x "${W}/bin/caddy-manager"; export PATH="${W}/bin:${PATH}"
# shellcheck source=../../../network/services/proxy/access-list.sh disable=SC1091
. "${ACL}"
proxy_prune_domains() { :; }; proxy_prune_route_lists() { :; }; unbound_prune_host_override() { :; }

out="$(proxy_unpublish network network.example.org example.org '' 2>&1)"
ck "withdrawing a route that is not there prints nothing" "${out}" ""
out="$(DBG=1 proxy_unpublish network network.example.org example.org '' 2>&1)"
ck "…the detail is there for debug" "$(grep -c '^DEBUG: .*not found — nothing to delete' <<<"${out}")" "2"
out="$(FAIL_DELETE=1 proxy_unpublish network network.example.org example.org '' 2>&1)"
ck "a failed delete prints what caddy-manager said" "$(grep -c 'ERROR: API refused' <<<"${out}")" "1"
ck "…and warns" "$(grep -c '^WARN: Could not delete handler for network' <<<"${out}")" "1"

echo "test-proxy-unpublish-quiet: ${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]]
