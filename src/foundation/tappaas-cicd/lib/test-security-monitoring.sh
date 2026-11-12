#!/usr/bin/env bash
#
# test-security-monitoring.sh — unit tests for lib/security-monitoring.sh
# (ADR-050 D1, D2). Offline: no logging VM.
#
#   - monitoring follows site.json, else the size: off at small, on otherwise;
#   - security logs are kept 90 days, 180 at large, or what site.json says;
#   - Loki's runtime config keeps the security streams that long, and holds no
#     override when monitoring is off.
#
# Usage: test-security-monitoring.sh   (prints "Results: N passed, M failed"; exit 1 on fail)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info(){ :; }; warn(){ :; }; error(){ :; }; debug(){ :; }
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
export CONFIG_DIR="${T}/config" LOG_SHIPPING_CRED_DIR="${T}/cred" LOG_SHIPPING_ADMIN_FILE="${T}/admin" \
       METRICS_IDENTITY_CACHE="${T}/identity-cache.json"
mkdir -p "${CONFIG_DIR}"
# shellcheck source=security-monitoring.sh
. "${HERE}/security-monitoring.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); }
no(){ fail=$((fail+1)); echo "FAIL: $1"; }
eq(){ [[ "$1" == "$2" ]] && ok || no "$3 (got '$1', want '$2')"; }
has(){ grep -qF -- "$2" <<<"$1" && ok || no "$3"; }

echo '{}' > "${CONFIG_DIR}/site.json"
eq "$(security_monitoring)" on "no size → on"
eq "$(security_retention_days)" 90 "medium → 90 days"
echo '{"size":"small"}' > "${CONFIG_DIR}/site.json"
eq "$(security_monitoring)" off "small → off"
echo '{"size":"large"}' > "${CONFIG_DIR}/site.json"
eq "$(security_retention_days)" 180 "large → 180 days"
echo '{"size":"small","security":{"monitoring":"on","retentionDays":120}}' > "${CONFIG_DIR}/site.json"
eq "$(security_monitoring)" on "site.json on wins at small"
eq "$(security_retention_days)" 120 "retentionDays wins"
echo '{"size":"medium","security":{"monitoring":"maybe","retentionDays":5}}' > "${CONFIG_DIR}/site.json"
eq "$(security_monitoring 2>/dev/null)" on "an unknown value → the default"
eq "$(security_retention_days)" 90 "a retention under 30 → the default"

echo '{"size":"large"}' > "${CONFIG_DIR}/site.json"
r="$(render_loki_runtime)"
has "${r}" "  fake:" "the runtime config overrides the single tenant"
has "${r}" "period: 4320h" "180 days as hours"
has "${r}" "selector: '{transport=\"audit\"}'" "audit records are a security stream"
has "${r}" "selector: '{source=\"opnsense\", unit=~\"filterlog|audit|api|sshd.*|crowdsec.*|suricata\"}'" "the firewall's blocks are"
eq "$(grep -c 'selector:' <<<"${r}")" "$(security_streams | grep -c .)" "one rule per stream"
if command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null; then
    python3 -c 'import sys,yaml; d=yaml.safe_load(sys.stdin); assert d["overrides"]["fake"]["retention_stream"][0]["priority"]==1' <<<"${r}" && ok || no "the runtime config is YAML Loki reads"
fi
echo '{"size":"small"}' > "${CONFIG_DIR}/site.json"
r="$(render_loki_runtime)"
has "${r}" "overrides: {}" "off: no override"
eq "$(grep -c 'selector:' <<<"${r}")" 0 "off: no stream kept longer"

echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
