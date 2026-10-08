#!/usr/bin/env bash
#
# test-firewall-cert.sh — check-firewall-cert.sh notices when the firewall's API
# certificate changes, and when it is about to expire (#310).
#
# Offline: CERT_PROBE stands in for the TLS probe, FIREWALL_CERT_STATE for the
# record in config/, FAKE_NOW for the clock.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="${HERE}/../../manager/health-manager/check-firewall-cert.sh"
PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
[[ -f "${S}" ]] || { echo "check-firewall-cert.sh not found — cannot run here."; exit 77; }
command -v jq >/dev/null || { echo "jq missing — skipped."; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/fwcert.XXXXXX")"; trap 'rm -rf "${T}"' EXIT

A=$(printf 'a%.0s' {1..64}); B=$(printf 'b%.0s' {1..64})
DAY=86400; NOW0=1791460000                       # 2026-10-08
FAR=$(( NOW0 + 300*DAY )); NEAR=$(( NOW0 + 10*DAY ))
run() {  # $1 = sha, $2 = notAfter epoch, $3 = now → OUT, RC
    OUT="$(CERT_PROBE="echo '$1|$2|network.internal'" FIREWALL_CERT_STATE="${T}/fw.json" FAKE_NOW="$3" bash "${S}" 2>&1)"; RC=$?
}
lines() { grep -c "$1" <<<"${OUT}"; }

run "${A}" "${FAR}" "${NOW0}"
ck "first run records the certificate" "1 0" "$(lines 'recorded') $(lines 'cert-changed')"
ck "…in config" "${A}" "$(jq -r .sha256 "${T}/fw.json")"
run "${A}" "${FAR}" $(( NOW0 + 3600 ))
ck "the same certificate an hour later: nothing to say" "" "${OUT}"
run "${B}" "${FAR}" $(( NOW0 + 7200 ))
ck "a new certificate: one 'changed' line naming both fingerprints" "1" "$(grep -c "tappaas-firewall-cert-changed: ${A} -> ${B}" <<<"${OUT}")"
ck "…and the record moves to it" "${B}" "$(jq -r .sha256 "${T}/fw.json")"
run "${B}" "${FAR}" $(( NOW0 + 10800 ))
ck "…said once, not every hour after" "" "${OUT}"

run "${B}" "${NEAR}" $(( NOW0 + 4*3600 ))
ck "within 30 days of expiry: one 'expiring' line" "1" "$(lines 'tappaas-firewall-cert-expiring:')"
run "${B}" "${NEAR}" $(( NOW0 + 5*3600 ))
ck "…not again the same day" "0" "$(lines 'expiring')"
run "${B}" "${NEAR}" $(( NOW0 + DAY + 3600 ))
ck "…again the next day" "1" "$(lines 'expiring')"
run "${A}" "${FAR}" $(( NOW0 + DAY + 7200 ))
ck "a renewal: changed, and no expiry left to warn about" "1 0" "$(lines 'cert-changed') $(lines 'expiring')"

OUT="$(CERT_PROBE="exit 1" FIREWALL_CERT_STATE="${T}/fw.json" bash "${S}" 2>&1)"; RC=$?
ck "an unreachable firewall: rc 1, the record untouched" "1 ${A}" "${RC} $(jq -r .sha256 "${T}/fw.json")"
OUT="$(CERT_PROBE="echo 'nonsense|1|x'" FIREWALL_CERT_STATE="${T}/fw.json" bash "${S}" 2>&1)"; RC=$?
ck "a probe answer that is no fingerprint: rc 1, nothing recorded" "1 ${A}" "${RC} $(jq -r .sha256 "${T}/fw.json")"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
