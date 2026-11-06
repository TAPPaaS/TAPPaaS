#!/usr/bin/env bash
# test-proxy-wildcard-tls.sh — under dnsMode wildcard a proxy domain gets the
# environment's wildcard only when it covers the name; with no covering
# certificate and no public A record it is not published, so Caddy never starts
# an HTTP-01 order the CA cannot complete.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACL="${HERE}/../../../network/services/proxy/access-list.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $1 (got '$2', want '$3')"; fi; }

# Like the real ones, the messages go to stdout: a helper whose stdout is
# captured must send them elsewhere.
info() { echo "I: $*"; }; debug() { echo "D: $*"; }; warn() { echo "W: $*"; }; error() { echo "E: $*"; }
BL=""; CL=""; YW=""; GN=""; : "${BL}${CL}${YW}${GN}"
normalize_module_config() { cat; }
# shellcheck source=../../../network/services/proxy/access-list.sh disable=SC1091
. "${ACL}"

covers() { proxy_wildcard_covers "$1" "$2" >/dev/null && echo yes || echo no; }
ck "one label under the domain"      "$(covers app.example.com example.com)"        yes
ck "the bare apex"                   "$(covers example.com example.com)"            yes
ck "case does not matter"            "$(covers App.Example.COM example.com)"        yes
ck "two labels under: not covered"   "$(covers app.test.example.com example.com)"   no
ck "another domain: not covered"     "$(covers app.example.org example.com)"        no
ck "a suffix lookalike"              "$(covers app.badexample.com example.com)"     no
ck "no environment domain"           "$(covers app.example.com '')"                 no

tls() {  # tls <domain> <env-domain> <refid> <dns-rc> → "rc|refid"
    local out rc=0
    out="$(proxy_wildcard_tls "$1" "$2" "$3" "$4" test 2>/dev/null)" || rc=$?
    echo "${rc}|${out}"
}
ck "covered: the wildcard is bound"                 "$(tls app.example.com example.com wc1 1)"      "0|wc1"
ck "covered, public record: the wildcard is bound"  "$(tls app.example.com example.com wc1 0)"      "0|wc1"
ck "not covered, no public record: not published"   "$(tls app.test.example.com example.com wc1 1)" "3|"
ck "no wildcard at all, no public record"           "$(tls app.test.example.com test.example.com '' 1)" "3|"
ck "not covered, public record: Caddy's own cert"   "$(tls app.test.example.com example.com wc1 0)" "0|"
ck "DNS not checkable: published as before"         "$(tls app.test.example.com example.com '' 2)"  "0|"

# Install and update both decide through the helper, wildcard mode only.
for s in install-service.sh update-service.sh; do
    f="${HERE}/../../../network/services/proxy/${s}"
    ck "${s} calls proxy_wildcard_tls"       "$(grep -c 'proxy_wildcard_tls ' "${f}")" 1
    ck "${s} keeps local mode out of it"     "$(grep -c 'if \[\[ "${DNS_MODE}" == "wildcard" \]\]; then' "${f}")" 1
done

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
