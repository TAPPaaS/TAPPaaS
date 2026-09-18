#!/usr/bin/env bash
# test-adopt.sh — the decisions `module adopt` makes without a machine (ADR-026 D8.1).
#
# Zone from the address (most specific active subnet wins; switched-off zones
# and non-zone entries are skipped; no match is a refusal), and module from the
# OS (one module per OS, no near match). Reaching and learning a machine is the
# live test: docs/design/debianhost-test-plan.md phases 1-2.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
# shellcheck source=/dev/null
. "${CICD}/manager/module-manager/adopt-module.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/adopt.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM
Z="${TMP}/zones.json"
cat > "${Z}" <<'JSON'
{
  "_README": "not a zone",
  "_profiles": {"x": {}},
  "mgmt":    {"ip": "10.0.0.0/24",   "state": "Manual"},
  "netbird": {"ip": "100.64.0.0/10", "state": "Mandatory"},
  "srv":     {"ip": "10.2.0.0/24",   "state": "Inactive"},
  "home":    {"ip": "10.3.10.0/24",  "state": "Active"},
  "wide":    {"ip": "10.3.0.0/16",   "state": "Active"},
  "off":     {"ip": "10.6.0.0/24",   "state": "Disabled"},
  "noip":    {"state": "Active"},
  "bad":     {"ip": "not-a-cidr",    "state": "Active"}
}
JSON

zone() { adopt_zone_for_ip "$1" "${Z}" 2>/dev/null || echo "(none)"; }
ck "an address in mgmt → mgmt"                      mgmt     "$(zone 10.0.0.90)"
ck "the network address itself is inside"           mgmt     "$(zone 10.0.0.0)"
ck "a /10 matches"                                  netbird  "$(zone 100.100.1.2)"
ck "most specific wins (/24 inside a /16)"          home     "$(zone 10.3.10.7)"
ck "…and the /16 takes the rest"                    wide     "$(zone 10.3.99.1)"
ck "an Inactive zone is skipped"                    "(none)" "$(zone 10.2.0.5)"
ck "a Disabled zone is skipped"                     "(none)" "$(zone 10.6.0.5)"
ck "an address in no zone → refused"                "(none)" "$(zone 192.168.1.10)"
ck "one past the subnet is outside"                 "(none)" "$(zone 10.0.1.0)"
ck "not an IPv4 address → refused"                  "(none)" "$(zone dh-test1)"
ck "a missing zones.json → refused"                 "(none)" "$(adopt_zone_for_ip 10.0.0.9 "${TMP}/nope.json" 2>/dev/null || echo "(none)")"

mod() { adopt_module_for_os "$1" 2>/dev/null || echo "(none)"; }
ck "debian → debianhost"                            debianhost "$(mod debian)"
ck "ubuntu → no module (no near match)"             "(none)"   "$(mod ubuntu)"
ck "nixos → no module (not adopted)"                "(none)"   "$(mod nixos)"
ck "an empty ID → no module"                        "(none)"   "$(mod "")"

ipof() { adopt_ip_of "$1" 2>/dev/null || echo "(none)"; }
ck "an IPv4 address is its own address"             10.0.0.90   "$(ipof 10.0.0.90)"
if command -v getent >/dev/null 2>&1; then
    ck "a name is compared by what it resolves to"  127.0.0.1   "$(ipof localhost)"
else
    echo "  - name resolution: no getent here (the mothership has it) — skipped"
fi
ck "a name that does not resolve → refused"         "(none)"    "$(ipof no-such-host.invalid)"

# Sourcing defines the functions and runs nothing.
ck "sourcing does not run the adoption"             function "$(type -t main)"

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
