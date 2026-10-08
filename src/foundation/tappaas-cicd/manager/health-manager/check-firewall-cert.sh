#!/usr/bin/env bash
#
# check-firewall-cert.sh — has the firewall's API certificate changed? (#310)
#
# Every opnsense-controller call reaches the firewall's API with --no-ssl-verify:
# its certificate is self-signed for `network.internal`, while callers connect to
# firewall.mgmt.internal, so it cannot be verified as it stands. A rotation is
# then invisible — hrossen's changed with the firewall rebuild of 2026-07-31 and
# nothing said so. Blocking on a pinned certificate would stop the sweep at every
# rebuild or renewal; this DETECTS instead: it records the certificate's
# fingerprint and logs a line when it changes, which logging mails
# (FirewallCertChanged). Real verification waits for a TAPPaaS CA (#787).
#
#   tappaas-firewall-cert-changed: <old sha256> -> <new sha256> (<subject>, valid to <date>)
#       once, when the fingerprint differs from the one recorded
#   tappaas-firewall-cert-expiring: <sha256> expires <date> (<n> days)
#       once a day within 30 days of notAfter — the renewal changes it too
#
# The record is config/firewall-cert.json; the first run writes it and says so.
# Runs from check-firewall-cert.timer on the mothership (hourly).
#
# Exit: 0 checked (changed or not), 1 the firewall could not be reached.
# Tests: CERT_PROBE stands in for the probe (prints "<sha256>|<notAfter epoch>|<subject>"),
# FIREWALL_CERT_STATE for the record, FAKE_NOW for the clock.
set -uo pipefail

HOST="${FIREWALL_HOST:-firewall.mgmt.internal}"
STATE="${FIREWALL_CERT_STATE:-${CONFIG_DIR:-/home/tappaas/config}/firewall-cert.json}"
WARN_DAYS="${FIREWALL_CERT_WARN_DAYS:-30}"
NOW="${FAKE_NOW:-$(date +%s)}"
TAG="tappaas-firewall-cert"

# stdout is the journal under check-firewall-cert.service, which Loki reads.
say() { echo "$*"; }

# "<sha256>|<notAfter epoch>|<subject CN>" of the certificate the firewall's API
# presents — 443 first, then 8443, as opnsense-controller probes. No openssl on
# the mothership; Python's ssl module decodes the certificate.
probe() {
    if [[ -n "${CERT_PROBE:-}" ]]; then bash -c "${CERT_PROBE}"; return; fi
    python3 - "${HOST}" <<'PY'
import hashlib, os, socket, ssl, sys, tempfile
host = sys.argv[1]
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
for port in (443, 8443):
    try:
        with socket.create_connection((host, port), timeout=5) as s, ctx.wrap_socket(s, server_hostname=host) as t:
            der = t.getpeercert(binary_form=True)
        break
    except OSError:
        der = None
if not der:
    sys.exit(1)
with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as f:
    f.write(ssl.DER_cert_to_PEM_cert(der)); path = f.name
try:
    info = ssl._ssl._test_decode_cert(path)
finally:
    os.unlink(path)
cn = next((v for rdn in info.get("subject", ()) for k, v in rdn if k == "commonName"), "?")
print(f"{hashlib.sha256(der).hexdigest()}|{ssl.cert_time_to_seconds(info['notAfter'])}|{cn}")
PY
}

live="$(probe)" || { echo "could not reach the firewall's API at ${HOST} (443/8443)" >&2; exit 1; }
IFS='|' read -r sha not_after subject <<<"${live}"
[[ "${sha}" =~ ^[0-9a-f]{64}$ ]] || { echo "unexpected probe answer: ${live}" >&2; exit 1; }
until_day="$(date -u -d "@${not_after}" +%F 2>/dev/null || date -u -r "${not_after}" +%F)"

old="$(jq -r '.sha256 // empty' "${STATE}" 2>/dev/null || true)"
record() {   # $1 = first-seen date to keep, $2 = the day the expiry was last warned about
    local tmp="${STATE}.tmp.$$"
    jq -n --arg s "${sha}" --arg sub "${subject}" --arg na "${until_day}" --arg warned "${2:-}" \
          --arg first "$1" --arg seen "$(date -u -d "@${NOW}" +%FT%TZ 2>/dev/null || date -u -r "${NOW}" +%FT%TZ)" \
        '{sha256: $s, subject: $sub, notAfter: $na, recordedAt: $first, lastSeen: $seen}
         + (if $warned == "" then {} else {expiryWarned: $warned} end)' > "${tmp}" \
        && mv -f "${tmp}" "${STATE}" || { rm -f "${tmp}"; echo "could not write ${STATE}" >&2; }
}
today="$(date -u -d "@${NOW}" +%F 2>/dev/null || date -u -r "${NOW}" +%F)"
days=$(( (not_after - NOW) / 86400 ))
warned="$(jq -r '.expiryWarned // empty' "${STATE}" 2>/dev/null || true)"
[[ "${old}" == "${sha}" ]] || warned=""          # a new certificate starts its own count
if (( days <= WARN_DAYS )) && [[ "${warned}" != "${today}" ]]; then
    say "${TAG}-expiring: ${sha} expires ${until_day} (${days} days) — renewing it changes the fingerprint (and alerts)"
    warned="${today}"
fi

if [[ -z "${old}" ]]; then
    record "${today}" "${warned}"
    say "${TAG}: recorded ${sha} (${subject}, valid to ${until_day}) as the firewall's API certificate"
elif [[ "${old}" != "${sha}" ]]; then
    say "${TAG}-changed: ${old} -> ${sha} (${subject}, valid to ${until_day}) — expected after a firewall rebuild or a certificate renewal; otherwise something answers as the firewall"
    record "${today}" "${warned}"
else
    record "$(jq -r '.recordedAt // empty' "${STATE}" 2>/dev/null)" "${warned}"
fi
exit 0
