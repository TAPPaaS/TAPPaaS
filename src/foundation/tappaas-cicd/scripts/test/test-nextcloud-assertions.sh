#!/usr/bin/env bash
#
# test-nextcloud-assertions.sh — the Nextcloud suite fails on the faults it
# exists for (#715).
#
# It could not before: the trusted-domain check only warned, so the suite
# reported zero failures while the public route answered HTTP 400; and nothing
# compared versions, so a partial upgrade (new code over an old database, an
# app left disabled) passed every test. Tests 13-15 are lifted out of
# nextcloud/test.sh and fed a scripted VM, so each verdict is exercised without
# a Nextcloud — the live site is healthy and cannot show the failing half.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "${HERE}/../../../.." && pwd)/apps/nextcloud/test.sh"
HPB="$(cd "${HERE}/../../../.." && pwd)/apps/nextcloud-hpb/test.sh"

PASS=0; FAIL=0
ck()   { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
ckin() { if [[ "$3" == *"$2"* ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (missing '$2' in: $3)"; FAIL=$((FAIL+1)); fi; }

[[ -f "${SRC}" ]] || { echo "nextcloud/test.sh not found — cannot run here."; exit 77; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/nc-assert.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

awk '/^header "Test 13: /{f=1} f&&/^# Summary$/{exit} f{print}' "${SRC}" > "${TMP}/block.sh"
ck "tests 13-15 extract and parse" "yes" \
    "$(grep -q 'Test 15' "${TMP}/block.sh" && bash -n "${TMP}/block.sh" 2>/dev/null && echo yes || echo no)"

# run <trusted_domains block> <probe output>  →  "<failed>|<passed>|<warned>", log in ${TMP}/out
run() {
    TD="$1" PROBE="$2" B="${TMP}/block.sh" bash -c '
        set -euo pipefail
        PASSED=0; FAILED=0; WARNED=0; SKIPPED=0
        log()    { echo "$1"; }
        pass()   { echo "[PASS] $1"; ((++PASSED)); }
        fail()   { echo "[FAIL] $1"; ((++FAILED)); }
        warn()   { echo "[WARN] $1"; ((++WARNED)); }
        skip()   { echo "[SKIP] $1"; ((++SKIPPED)); }
        info()   { :; }; header() { :; }
        public_domain_of() { echo cloud.example.org; }
        # Test 13 asks occ, not the config file (#724 follow-up): two calls, the
        # value and a liveness probe. A stub that answers only the first makes a
        # correctly configured site report "could not ask occ".
        remote() { case "$1" in
            *"test -r"*)            echo ok ;;
            *"status --output=json"*) echo "{" ;;
            *trusted_domains*)      printf "%s\n" "${TD}" ;;
        esac; }
        fake_ssh() { cat >/dev/null; printf "%s\n" "${PROBE}"; }
        SSH_CMD=fake_ssh VMNAME=nextcloud MODULE=nextcloud MODULE_JSON=/dev/null
        . "${B}"
        echo "RESULT ${FAILED}|${PASSED}|${WARNED}"
    ' > "${TMP}/out" 2>&1
    sed -n 's/^RESULT //p' "${TMP}/out"
}

# As `occ config:system:get trusted_domains` prints it: one per line.
TD_OK="localhost
cloud.example.org"
TD_OTHER="localhost
other.example.org"
APPS="APP|calendar|6.2.3|yes|6.2.3
APP|spreed|23.0.4|yes|23.0.4"
GOOD="PKG|/nix/store/x-nextcloud-33.0.3-with-apps
CODE|33.0.3.2
DB|33.0.3.2
${APPS}"

echo "── healthy ──"
ck "all green: no failures, three passes" "0|3|0" "$(run "${TD_OK}" "${GOOD}")"
ckin "  …and counts the apps" "2 of 2 declared apps" "$(cat "${TMP}/out")"

echo "── trusted_domains (Test 13) ──"
ck "public name missing from trusted_domains: a failure, not a warning" "1|2|0" "$(run "${TD_OTHER}" "${GOOD}")"
ckin "  …and names the 400" "gets HTTP 400" "$(cat "${TMP}/out")"
ck "trusted_domains absent entirely: a failure" "1|2|0" "$(run "" "${GOOD}")"

echo "── versions (Test 14) ──"
ck "code ahead of the database: fails" "1|2|0" "$(run "${TD_OK}" "${GOOD/DB|33.0.3.2/DB|32.0.6.1}")"
ckin "  …and names both" "Code is 33.0.3.2 but the database is at 32.0.6.1" "$(cat "${TMP}/out")"
ck "no package found: fails (twice — no apps either)" "2|1|0" "$(run "${TD_OK}" "PKG|")"
ck "database version unreadable: fails" "1|2|0" "$(run "${TD_OK}" "${GOOD/DB|33.0.3.2/DB|}")"

echo "── apps (Test 15) ──"
ck "a declared app disabled: fails" "1|3|0" "$(run "${TD_OK}" "${GOOD/spreed|23.0.4|yes/spreed|23.0.4|no}")"
ckin "  …and names it" "App spreed is declared but not enabled" "$(cat "${TMP}/out")"
ck "an app whose upgrade did not run: fails" "1|3|0" "$(run "${TD_OK}" "${GOOD/calendar|6.2.3|yes|6.2.3/calendar|6.2.3|yes|6.1.0}")"
ckin "  …and names both versions" "ships 6.2.3 but the database records 6.1.0" "$(cat "${TMP}/out")"
ck "an app never installed: fails" "1|3|0" "$(run "${TD_OK}" "${GOOD/calendar|6.2.3|yes|6.2.3/calendar|6.2.3||}")"

echo "── nextcloud-hpb: an empty public name can no longer pass ──"
ck "hpb/test.sh parses" "yes" "$(bash -n "${HPB}" 2>/dev/null && echo yes || echo no)"
ckin "Test 7 fails on an empty domain before grepping" 'if [ -z "${HPB_PROXY_DOMAIN}" ]; then' "$(cat "${HPB}")"
ck "no bare grep -q on the domain" "0" "$(grep -c 'grep -q "${HPB_PROXY_DOMAIN}"' "${HPB}")"

echo "── public_domain_of never ends the suite ──"
# A lib without module_public_domain (an installed copy that predates it) made
# the helper exit 127, and set -e ended test.sh silently at Test 12.
# The helper is placed where test.sh lives relative to the lib, with the
# installed-copy fallback pointed at a lib that lacks the function too.
mkdir -p "${TMP}/apps/m" "${TMP}/foundation/tappaas-cicd/lib" "${TMP}/bin"
echo 'true' > "${TMP}/foundation/tappaas-cicd/lib/common-install-routines.sh"
echo 'true' > "${TMP}/bin/common-install-routines.sh"
for f in "${SRC}" "${HPB}"; do
    awk '/^public_domain_of\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "${f}" \
        | sed "s#/home/tappaas/bin/#${TMP}/bin/#" > "${TMP}/apps/m/pdo.sh"
    got=$(bash -c 'set -euo pipefail; . "$1"; x="$(public_domain_of v e /dev/null)"; echo "survived:[${x}]"' _ "${TMP}/apps/m/pdo.sh" 2>&1)
    ck "$(basename "$(dirname "${f}")"): a lib without the function yields empty, not an exit" "survived:[]" "${got}"
done
# And with a lib that has it, the checkout's copy answers.
cat > "${TMP}/foundation/tappaas-cicd/lib/common-install-routines.sh" <<'LIB'
module_public_domain() { printf '%s' "$1.from-checkout"; }
LIB
got=$(bash -c 'set -euo pipefail; . "$1"; public_domain_of v e /dev/null' _ "${TMP}/apps/m/pdo.sh" 2>&1)
ck "the checkout's lib is preferred" "v.from-checkout" "${got}"

echo
echo "Passed: ${PASS}  Failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]]
