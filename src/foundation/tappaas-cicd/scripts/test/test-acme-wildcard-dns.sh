#!/usr/bin/env bash
#
# test-acme-wildcard-dns.sh — the split-horizon record acme-setup.sh writes in
# wildcard mode (#703).
#
# The probe behind `split-horizon-target` is an A-record lookup on the name it
# is given, and this call used to hand it the bare apex. A DNS-01 wildcard is
# proven by a TXT record at _acme-challenge.<domain> and needs no apex A record,
# so an environment whose wildcard resolved publicly was read as UNPUBLISHED,
# the Unbound record was skipped, and every name the wildcard covers resolved to
# the WAN address from inside — while Caddy held a valid certificate and a live
# handler for it. The run then said `✓ ACME setup complete`, and the skip line
# blamed zones.json, which is not where the cause was.
#
# The block is lifted out of acme-setup.sh (which otherwise needs a firewall, an
# ACME account and a live Unbound) with network-manager and unbound-manager
# stubbed, so the decision is tested without any of them.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../acme-setup.sh"
[[ -f "${SRC}" ]] || { echo "acme-setup.sh not found beside this suite — cannot run here."; exit 77; }

PASS=0; FAIL=0
ck()   { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
ckin() { if [[ "$3" == *"$2"* ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (no '$2' in: $3)"; FAIL=$((FAIL+1)); fi; }
cknot(){ if [[ "$3" != *"$2"* ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 ('$2' should not appear)"; FAIL=$((FAIL+1)); fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/acme-wc.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

# The wildcard block: from the dnsMode read to the `fi` that closes it.
START="$(grep -n '^DNS_MODE=' "${SRC}" | head -1 | cut -d: -f1)"
[[ -n "${START}" ]] || { echo "  FAIL: could not find the dnsMode block in acme-setup.sh"; exit 1; }
END="$(awk -v s="${START}" 'NR>s && /^fi$/ {print NR; exit}' "${SRC}")"
[[ -n "${END}" ]] || { echo "  FAIL: could not find the end of the wildcard block"; exit 1; }
sed -n "$((START+1)),${END}p" "${SRC}" > "${TMP}/block.sh"
bash -n "${TMP}/block.sh" 2>/dev/null || { echo "  FAIL: the extracted block does not parse"; exit 1; }
ck "the wildcard block extracts and parses" "yes" "yes"

# run <resolver-rc> <resolver-stdout> <resolver-stderr>
# Prints everything the block said; leaves the calls it made in ${TMP}/calls.
run() {
    local rc="$1" out="$2" err="$3"
    : > "${TMP}/calls"
    RC="${rc}" OUT="${out}" ERR="${err}" CALLS="${TMP}/calls" \
    bash -c '
        BOLD=""; GN=""; CL=""; BL=""; YW=""; RD=""
        info() { echo "$*"; }
        warn() { echo "[Warning] $*"; }
        DNS_MODE="wildcard"
        DOMAIN="tenant1.example.org"
        VARIANT="tenant1"
        network-manager() {
            echo "network-manager $*" >> "${CALLS}"
            [ -n "${OUT}" ] && echo "${OUT}"
            [ -n "${ERR}" ] && echo "${ERR}" >&2
            return "${RC}"
        }
        unbound-manager() {
            echo "unbound-manager $*" >> "${CALLS}"
            case " $* " in
                *" list "*) printf "HOST ZONE\nlogging tenant1.example.org\nother elsewhere.org\n" ;;
            esac
            return 0
        }
        export -f network-manager unbound-manager
        . '"${TMP}"'/block.sh
        echo "WC_SKIPPED=${WC_SKIPPED:-0}"
    ' 2>&1
}

# ── 1. the probe does not hinge on an apex A record ─────────────────────────
out="$(run 0 "10.6.0.1" "split-horizon: tenant1.example.org → 10.6.0.1 (dmz)")"
calls="$(cat "${TMP}/calls")"
ckin "the resolver is asked with --assume-published" "--assume-published" "${calls}"
ckin "…for the environment's domain"                 "tenant1.example.org" "${calls}"
ckin "the wildcard record is registered"             "unbound-manager --no-ssl-verify add * tenant1.example.org 10.6.0.1" "${calls}"
ckin "…and reported"                                 "*.tenant1.example.org -> 10.6.0.1" "${out}"
ck   "the run is not marked incomplete"              "WC_SKIPPED=0" "$(grep -o 'WC_SKIPPED=[01]' <<< "${out}")"

# A per-service override for the same domain is dropped first: the wildcard
# installs a `redirect` zone and Unbound refuses per-name data inside it.
ckin "a stale per-service override is removed" "delete logging tenant1.example.org" "${calls}"
cknot "…and one in another domain is left alone" "delete other" "${calls}"

# ── 2. a genuine resolver error says what the resolver said ─────────────────
out="$(run 2 "" "[Error] split-horizon: no 'dmz' zone in zones.json — the split-horizon answer is the DMZ gateway")"
ckin "an error marks the run incomplete"   "WC_SKIPPED=1" "${out}"
ckin "…and prints the reason the resolver gave" "no 'dmz' zone" "${out}"
ckin "…and says how to reproduce it"       "--assume-published --json" "${out}"
cknot "…without the old invented cause"    "could not derive a gateway from zones.json" "${out}"
cknot "…and writes no record"              "unbound-manager --no-ssl-verify add" "$(cat "${TMP}/calls")"

# ── 3. the caller must not report success when the record is missing ───────
# Checked against the script itself: the completion banner is guarded, and the
# guard exits non-zero. A cert without the record leaves every internal client
# resolving the name publicly, which is the failure this issue is about.
tail_of="$(sed -n "$((END+1)),\$p" "${SRC}")"
ckin "the completion banner is guarded by the skip"  'WC_SKIPPED' "${tail_of}"
guard="$(awk '/WC_SKIPPED:-0/,/^fi$/' <<< "${tail_of}")"
ckin "…and the guard exits non-zero"                 "exit 1" "${guard}"
ckin "…naming what is missing"                       "split-horizon record is not" "${guard}"

echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
