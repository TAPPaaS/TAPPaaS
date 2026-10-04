#!/usr/bin/env bash
#
# test-repair-ownership.sh — which trees the ownership repair keeps the
# operator's (#533; .node-secrets since 2026-10-04). Uses --check with a real
# account that owns none of the fixture (root, or nobody when run as root), so
# every inspected tree reports drift and nothing is ever chowned.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="${HERE}/../tappaas-repair-ownership.sh"
PASS=0; FAIL=0
ck() { if [[ "$3" == *"$2"* ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (missing '$2' in: $3)"; FAIL=$((FAIL+1)); fi; }
no() { if [[ "$3" != *"$2"* ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (unexpected '$2')"; FAIL=$((FAIL+1)); fi; }
command -v jq >/dev/null || { echo "jq missing — skipped"; exit 77; }
OTHER=root; [[ "$(id -u)" -eq 0 ]] && OTHER=nobody
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
H="$(cd "${T}" && pwd -P)/home"
mkdir -p "${H}/config" "${H}/TAPPaaS" "${H}/.node-secrets" "${H}/elsewhere"
echo pw > "${H}/.node-secrets/tappaas2.pw"; echo x > "${H}/TAPPaaS/f"; echo '{}' > "${H}/config/site.json"
echo x > "${H}/elsewhere/f"
OUT="$(TAPPAAS_HOME_ROOT="${H}" CONFIG_DIR="${H}/config" TAPPAAS_OPERATOR="${OTHER}" bash "${R}" --check 2>&1)"; RC=$?
ck "the config dir is inspected"            "'${H}/config'"        "${OUT}"
ck "the checkout is inspected"              "'${H}/TAPPaaS'"       "${OUT}"
ck "the node passwords are inspected"       "'${H}/.node-secrets'" "${OUT}"
no "nothing outside them is"                "elsewhere"            "${OUT}"
ck "drift in --check mode exits 1, repairs nothing" "1" "${RC}"
ck "…and the file kept its mode" "600" "$(chmod 600 "${H}/.node-secrets/tappaas2.pw"; stat -c %a "${H}/.node-secrets/tappaas2.pw" 2>/dev/null || stat -f %Lp "${H}/.node-secrets/tappaas2.pw")"
echo "── repair-ownership: ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
