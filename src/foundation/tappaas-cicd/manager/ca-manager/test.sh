#!/usr/bin/env bash
# test.sh — ca-manager offline test suite (ADR-043).
#
# Compiles the sources and unit tests, runs the unit suite (ADR-043's rules), then
# drives the compiled CLI with real openssl against a temp config dir and key
# dir: it makes the internal CA and two domain CAs, signs certificates, and asks
# openssl itself whether each verifies — never the live config or keys.
set -uo pipefail
export TAPPAAS_CMDB=off
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
ok()   { echo "  ok: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1" >&2; fail=$((fail + 1)); }

mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }   # GNU first: BSD's -f is a filesystem query there
for f in "${HERE}"/*.sh; do bash -n "$f" && ok "$(basename "$f") parses" || bad "$(basename "$f") syntax"; done

run_ts() {
    if command -v tsc >/dev/null 2>&1 && command -v node >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then bash -c "$1"
    elif command -v nix-shell >/dev/null 2>&1; then nix-shell -p typescript nodejs_22 openssl --run "$1"
    else return 127; fi
}
DIST="${HERE}/dist-test"
rm -rf -- "${DIST}"
run_ts "tsc --noEmit -p '${HERE}/tsconfig.json'" >/dev/null 2>&1 && ok "tsc --noEmit clean (src)" || bad "tsc --noEmit reported type errors (src)"
if run_ts "tsc -p '${HERE}/test/unit/tsconfig.json'" >/dev/null 2>&1; then ok "sources + unit tests compile"
else bad "unit tests do not compile"; echo "ca-manager test: ${pass} passed, ${fail} failed"; exit 1; fi
for unit in $(cd "${HERE}/test/unit" && ls *.test.ts | sed 's/\.test\.ts$//'); do
    run_ts "node '${DIST}/manager/ca-manager/test/unit/${unit}.test.js'" >/dev/null 2>&1 \
        && ok "unit: ${unit}" || bad "unit: ${unit} (rerun: node ${DIST}/manager/ca-manager/test/unit/${unit}.test.js)"
done

# ── the CLI with real openssl ────────────────────────────────────────
FIX="$(mktemp -d "${TMPDIR:-/tmp}/ca-fix.XXXXXX")"
trap 'rm -rf "${FIX}" "${DIST}"' EXIT
mkdir -p "${FIX}/cfg"
echo '{"name":"lab9"}' > "${FIX}/cfg/site.json"
K="${FIX}/keys"
CA() { TAPPAAS_CONFIG="${FIX}/cfg" CONFIG_DIR="${FIX}/cfg" TAPPAAS_CA_DIR="${K}" run_ts "node '${DIST}/manager/ca-manager/src/main.js' $*"; }
vfy() { run_ts "openssl verify -CAfile '$1' -verify_hostname '$3' '$2'" >/dev/null 2>&1; }

# A bundle with a CA put there by hand is not taken from the guests.
mkdir -p "${FIX}/hand"; run_ts "openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout '${FIX}/hand/k' -out '${FIX}/cfg/site-ca.pem' -days 5 -subj '/CN=hand CA'" >/dev/null 2>&1
CA init >/dev/null 2>&1 && bad "init: a hand-made CA in the bundle refused" || ok "init: a hand-made CA in the bundle refused"
[[ ! -e "${K}" && "$(grep -c BEGIN "${FIX}/cfg/site-ca.pem")" == "1" ]] && ok "…before anything is made" || bad "…something was made"
CA init --replace-bundle >/dev/null 2>&1 && ! grep -q 'hand CA' <(run_ts "openssl crl2pkcs7 -nocrl -certfile '${FIX}/cfg/site-ca.pem' | openssl pkcs7 -print_certs -noout") \
    && [[ "$(grep -c BEGIN "${FIX}/cfg/site-ca.pem")" == "1" ]] && ok "init --replace-bundle takes it over" || bad "init --replace-bundle"
rm -rf "${K}" "${FIX}/cfg/certificates.json" "${FIX}/cfg/site-ca.pem"

CA init --check >/dev/null 2>&1; [[ ! -e "${K}" && ! -e "${FIX}/cfg/certificates.json" ]] && ok "init --check makes nothing" || bad "init --check made something"
CA init >/dev/null 2>&1 && ok "init: the internal CA" || bad "init"
[[ "$(mode "${K}")" == "700" ]] && ok "init: the key dir is 700" || bad "init: key dir mode"
[[ "$(mode "${K}/ca/internal.key")" == "600" ]] && ok "init: the CA key is 600" || bad "init: CA key mode"
run_ts "openssl x509 -in '${K}/ca/internal.pem' -noout -subject -ext nameConstraints" 2>/dev/null | grep -q 'DNS:internal' && ok "init: constrained to internal" || bad "init: constraint"
run_ts "openssl x509 -in '${K}/ca/internal.pem' -noout -subject" 2>/dev/null | grep -q 'TAPPaaS lab9 internal CA' && ok "init: named after the site" || bad "init: CA name"
fp="$(jq -r '.cas.internal.fingerprint' "${FIX}/cfg/certificates.json")"
CA init >/dev/null 2>&1; [[ "$(jq -r '.cas.internal.fingerprint' "${FIX}/cfg/certificates.json")" == "${fp}" ]] && ok "init again changes nothing" || bad "init again replaced the CA"

CA domain add my-org.tld >/dev/null 2>&1 && ok "domain add: the first domain" || bad "domain add"
CA domain add test.my-org.tld 2>&1 | grep -q 'needs no CA of its own' && ok "domain add: a subdomain is covered" || bad "domain add: subdomain"
CA domain add other-org.tld >/dev/null 2>&1 && ok "domain add: an unrelated domain" || bad "domain add: unrelated"
[[ "$(jq -r '.cas | keys | join(",")' "${FIX}/cfg/certificates.json")" == "domain-my-org.tld,domain-other-org.tld,internal" ]] && ok "three CAs recorded" || bad "CAs recorded"
CA domain add x.internal >/dev/null 2>&1 && bad "domain add: under internal refused" || ok "domain add: under internal refused"
[[ "$(grep -c 'BEGIN CERTIFICATE' "${FIX}/cfg/site-ca.pem")" == "3" ]] && ok "the bundle holds all three CAs" || bad "bundle"

CA cert issue logging --dns logging.mgmt.internal >/dev/null 2>&1 && ok "cert issue: an internal name" || bad "cert issue: internal"
vfy "${K}/ca/internal.pem" "${K}/certs/logging.pem" logging.mgmt.internal && ok "…verifies against the internal CA" || bad "…verify internal"
vfy "${K}/ca/domain-my-org.tld.pem" "${K}/certs/logging.pem" logging.mgmt.internal && bad "…not against a domain CA" || ok "…not against a domain CA"
CA cert issue wild --dns '*.my-org.tld,*.test.my-org.tld' >/dev/null 2>&1 && ok "cert issue: wildcards of one tree" || bad "cert issue: wildcards"
vfy "${FIX}/cfg/site-ca.pem" "${K}/certs/wild.pem" a.test.my-org.tld && ok "…a subdomain environment verifies against the bundle" || bad "…subdomain verify"
CA cert issue bad --dns x.hrossen.dk >/dev/null 2>&1 && bad "cert issue: an uncovered name refused" || ok "cert issue: an uncovered name refused"
CA cert issue mix --dns a.mgmt.internal,a.my-org.tld >/dev/null 2>&1 && bad "cert issue: a mix refused" || ok "cert issue: a mix refused"
CA cert issue logging --dns logging.mgmt.internal >/dev/null 2>&1 && bad "cert issue: an existing name refused" || ok "cert issue: an existing name refused"
[[ ! -e "${K}/certs/bad.key" && ! -e "${K}/certs/mix.key" ]] && ok "a refused issue leaves no key" || bad "a refused issue left a key"

CA cert renew 2>&1 | grep -q 'nothing to renew' && ok "cert renew: nothing due" || bad "cert renew: nothing due"
CA_MANAGER_NOW=2027-10-15T00:00:00Z CA cert renew --check 2>&1 | grep -c 'would renew' | grep -q '^2$' && ok "cert renew --check: both due 60 days ahead" || bad "cert renew --check"
fp="$(jq -r '.certificates.logging.fingerprint' "${FIX}/cfg/certificates.json")"
CA cert renew logging --force >/dev/null 2>&1 && [[ "$(jq -r '.certificates.logging.fingerprint' "${FIX}/cfg/certificates.json")" != "${fp}" ]] && ok "cert renew --force: a new certificate" || bad "cert renew --force"
vfy "${K}/ca/internal.pem" "${K}/certs/logging.pem" logging.mgmt.internal && ok "…which verifies" || bad "…renewed verify"

# ── wildcard: an environment's domain CA and wildcard, onto the firewall ──
# trust-manager and ssh are stand-ins: the store is a directory of files.
mkdir -p "${FIX}/bin" "${FIX}/fw"
cat > "${FIX}/bin/trust-manager" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "${FIX}/fw/calls"
[[ \$1 == --no-ssl-verify ]] && shift
v=\$1; name=""; pem=""
while [[ \$# -gt 0 ]]; do case \$1 in --name) name=\$2; shift;; --pem-file) pem=\$2; shift;; esac; shift; done
f="${FIX}/fw/\$(printf %s "\${name}" | tr -c 'a-zA-Z0-9' _)"
[[ \$v == cert-ensure ]] && cat > /dev/null
id="\$(printf %s "\${name}" | cksum | cut -d' ' -f1)abcdef"
if [[ -f "\$f" ]] && cmp -s "\$f" "\$pem"; then echo "present: \$name" >&2; else cp "\$pem" "\$f"; echo "updated: \$name" >&2; fi
echo "\${id}"
STUB
printf '#!/bin/sh\necho "$*" >> "%s/fw/ssh"\n' "${FIX}" > "${FIX}/bin/ssh"; chmod +x "${FIX}/bin/trust-manager" "${FIX}/bin/ssh"
W() { PATH="${FIX}/bin:${PATH}" CA "$@"; }
W wildcard mgmt --domain lab9.example.org --check >/dev/null 2>&1; [[ ! -e "${FIX}/fw/calls" ]] && ok "wildcard --check touches nothing" || bad "wildcard --check touched the firewall"
W wildcard mgmt --domain lab9.example.org >/dev/null 2>&1 && ok "wildcard: an environment's CA and wildcard" || bad "wildcard"
[[ "$(jq -r '.cas["domain-lab9.example.org"].scope' "${FIX}/cfg/certificates.json")" == "domain" ]] && ok "…its domain got a CA" || bad "…no domain CA"
vfy "${FIX}/cfg/site-ca.pem" "${K}/certs/wildcard-mgmt.pem" console.lab9.example.org && ok "…the wildcard verifies for console.<domain>" || bad "…wildcard verify"
r="$(jq -r '.mgmt' "${FIX}/cfg/cert-refids.json")"; [[ -n "${r}" && "${r}" == "$(jq -r '.certificates["wildcard-mgmt"].refid' "${FIX}/cfg/certificates.json")" ]] && ok "…its refid recorded for Caddy" || bad "…refid not recorded"
grep -q -- '--name TAPPaaS: domain-lab9.example.org' "${FIX}/fw/calls" && ! grep -q 'key-stdin' <(grep 'ca-ensure' "${FIX}/fw/calls") && ok "…the CA imported without its key" || bad "…CA import"
W wildcard lab9 --domain test.lab9.example.org >/dev/null 2>&1 && [[ "$(jq -r '.cas | keys | length' "${FIX}/cfg/certificates.json")" == "4" ]] && ok "a subdomain environment: no new CA" || bad "subdomain environment"
: > "${FIX}/fw/calls"; W wildcard mgmt --domain lab9.example.org 2>&1 | grep -q 'refid' && ! grep -q 'updated' <(W wildcard mgmt --domain lab9.example.org 2>&1) && ok "wildcard again: nothing re-signed" || bad "wildcard again"
[[ ! -e "${FIX}/fw/ssh" ]] && ok "…and Caddy not reloaded" || bad "…Caddy reloaded for nothing"
CA_MANAGER_NOW=2027-10-15T00:00:00Z W cert renew wildcard-mgmt >/dev/null 2>&1 && grep -q 'configctl caddy reload' "${FIX}/fw/ssh" && ok "a renewed wildcard is replaced on the firewall and Caddy reloaded" || bad "renewal onto the firewall"
[[ "$(jq -r '.mgmt' "${FIX}/cfg/cert-refids.json")" == "${r}" ]] && ok "…its refid unchanged" || bad "…refid changed"
W wildcard x --domain lab9.internal >/dev/null 2>&1 && bad "wildcard: an internal domain refused" || ok "wildcard: an internal domain refused"

CA validate >/dev/null 2>&1 && ok "validate: all consistent" || bad "validate"
chmod 644 "${K}/certs/wild.key"; CA validate >/dev/null 2>&1 && bad "validate: a readable key is a finding" || ok "validate: a readable key is a finding"; chmod 600 "${K}/certs/wild.key"
echo "# x" >> "${FIX}/cfg/site-ca.pem"; CA validate >/dev/null 2>&1 && bad "validate: a changed bundle is a finding" || ok "validate: a changed bundle is a finding"
CA init >/dev/null 2>&1; CA validate >/dev/null 2>&1 && ok "init rewrites the bundle" || bad "init did not repair the bundle"
[[ "$(CA status --json 2>/dev/null | jq -r '.certificates.logging.daysLeft')" -ge 364 ]] && ok "status --json: days left" || bad "status --json"
CA --help --json >/dev/null 2>&1 && ok "--help --json: the verb manifest" || bad "--help --json"
CA cert issue x --bogus y >/dev/null 2>&1 && bad "an undeclared option refused" || ok "an undeclared option refused"
TAPPAAS_SIMULATE=1 CA domain add sim.tld >/dev/null 2>&1; [[ ! -e "${K}/ca/domain-sim.tld.key" ]] && ok "simulate: nothing made" || bad "simulate made a CA"

rm -rf -- "${DIST}"
echo ""
echo "ca-manager test: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
