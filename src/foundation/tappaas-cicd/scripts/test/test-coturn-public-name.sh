#!/usr/bin/env bash
#
# test-coturn-public-name.sh — coturn's public TURN name comes from the site's
# environment domain, and from nothing else.
#
# The domain lives in site.json, read through get_variant_config. pre-install.sh
# and public-name.sh each derived turn.<domain> themselves, and both still fell back
# to configuration.json, the file site.json replaced. Now there is one derivation.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COTURN="$(readlink -f "${HERE}/../../../../collaboration/coturn")"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

[[ -f "${COTURN}/public-name.sh" ]] || { echo "coturn not found — cannot run here."; exit 77; }

# The environment lookup, as site.json answers it.
get_variant_config() {
    case "$1" in
        rossen|"") echo '{"domain":"hrossen.dk"}' ;;
        nodomain)  echo '{"domain":null}' ;;
        *)         return 1 ;;
    esac
}
# shellcheck source=/dev/null
. "${COTURN}/public-name.sh"

ck "the environment's domain gives turn.<domain>" "turn.hrossen.dk" "$(coturn_default_public_name rossen)"
ck "the default environment too"                  "turn.hrossen.dk" "$(coturn_default_public_name "")"
ck "no domain: no name (the caller warns)"        ""                "$(coturn_default_public_name nodomain)"
ck "an unknown environment: no name"              ""                "$(coturn_default_public_name ghost)"
ck "nothing in coturn reads configuration.json"   "0" \
   "$(grep -rl 'configuration\.json' "${COTURN}" --include='*.sh' | wc -l | tr -d ' ')"
ck "pre-install.sh uses the one derivation"       "yes" \
   "$(grep -q 'coturn_default_public_name' "${COTURN}/pre-install.sh" && echo yes || echo no)"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
