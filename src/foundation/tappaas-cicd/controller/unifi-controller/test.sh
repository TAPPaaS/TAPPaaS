#!/usr/bin/env bash
# The UniFi controller's offline tests: its vendor logic (test-unifi-controller.sh)
# and the contract verbs through the shim (no controller is called).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
bash "${here}/test-unifi-controller.sh" || rc=1
d="$("${here}/unifi-controller" describe)" || rc=1
for want in '.contracts == ["switch/1","ap/1"]' '.vendors == ["unifi"]' '.arch == "controller"' '.module == "unifi-os"'; do
    if jq -e "${want}" >/dev/null <<<"${d}"; then echo "  ✓ describe: ${want}"; else echo "  ✗ describe: ${want}"; rc=1; fi
done
"${here}/unifi-controller" supports unifi && echo "  ✓ supports unifi" || { echo "  ✗ supports unifi"; rc=1; }
"${here}/unifi-controller" supports mikrotik; [[ $? -eq 3 ]] && echo "  ✓ supports mikrotik: no (3)" || { echo "  ✗ supports mikrotik should be 3"; rc=1; }
"${here}/unifi-controller" interrogate 2>/dev/null; [[ $? -eq 2 ]] && echo "  ✓ interrogate without --controller or --switch is bad usage (2)" || { echo "  ✗ interrogate usage"; rc=1; }
exit "${rc}"
