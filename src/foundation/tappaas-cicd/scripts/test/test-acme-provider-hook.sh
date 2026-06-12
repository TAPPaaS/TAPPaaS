#!/usr/bin/env bash
#
# test-acme-provider-hook.sh — ACME DNS provider → acme.sh hook resolution (#327).
#
# acme-setup.sh's #327 preflight verifies the acme.sh dnsapi hook for the chosen
# provider exists on the firewall before signing. The hook file is named after the
# RESOLVED os-acme-client key (cloudflare→dns_cf.sh), NOT the friendly --provider
# name — a naive dns_<name>.sh false-negatives the default (cloudflare) and others,
# breaking the happy path. resolve_dns_service() does the resolution and MUST stay
# in sync with PROVIDER_ALIASES in opnsense-controller's acme_cli.py (the authority
# that actually drives os-acme-client). This test pins both.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACME_CLI="${SCRIPT_DIR}/../../opnsense-controller/src/opnsense_controller/acme_cli.py"

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common-install-routines.sh"

PASS=0
FAIL=0
pass() { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got '$1' expected '$2')"; fi; }

echo "test-acme-provider-hook: provider → acme.sh dnsapi hook resolution (#327)"

# Friendly names whose acme.sh key differs from dns_<name> — the regression cases.
assert_eq "$(resolve_dns_service cloudflare)" "dns_cf"   "cloudflare (default) -> dns_cf"
assert_eq "$(resolve_dns_service route53)"    "dns_aws"  "route53 -> dns_aws"
assert_eq "$(resolve_dns_service aws)"        "dns_aws"  "aws -> dns_aws"
assert_eq "$(resolve_dns_service powerdns)"   "dns_pdns" "powerdns -> dns_pdns"

# Friendly names that resolve to dns_<name> verbatim.
assert_eq "$(resolve_dns_service desec)"      "dns_desec"   "desec -> dns_desec"
assert_eq "$(resolve_dns_service hetzner)"    "dns_hetzner" "hetzner -> dns_hetzner"

# A raw os-acme-client key passes through unchanged.
assert_eq "$(resolve_dns_service dns_cf)"     "dns_cf"      "raw dns_cf passes through"
assert_eq "$(resolve_dns_service dns_gandi)"  "dns_gandi"   "raw dns_gandi passes through"

# Unknown friendly name best-effort falls back to dns_<name> (acme-manager would
# then reject it cleanly — the preflight is not the place to validate provider names).
assert_eq "$(resolve_dns_service somethingnew)" "dns_somethingnew" "unknown name -> dns_<name> fallback"

# Cross-check: every friendly alias in acme_cli.py's PROVIDER_ALIASES must resolve
# identically here, or the preflight check will drift from the actual signer.
if command -v python3 >/dev/null 2>&1 && [[ -f "$ACME_CLI" ]]; then
    while IFS=$'\t' read -r friendly key; do
        [[ -z "$friendly" ]] && continue
        got="$(resolve_dns_service "$friendly")"
        assert_eq "$got" "$key" "in sync with acme_cli.py: ${friendly} -> ${key}"
    done < <(python3 - "$ACME_CLI" <<'PY'
import ast, sys
src = open(sys.argv[1]).read()
tree = ast.parse(src)
for node in ast.walk(tree):
    if isinstance(node, ast.Assign) and any(
        isinstance(t, ast.Name) and t.id == "PROVIDER_ALIASES" for t in node.targets
    ):
        for k, v in zip(node.value.keys, node.value.values):
            print(f"{ast.literal_eval(k)}\t{ast.literal_eval(v)}")
PY
    )
else
    echo "  (skipping acme_cli.py cross-check: python3 or source file unavailable)"
fi

echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
