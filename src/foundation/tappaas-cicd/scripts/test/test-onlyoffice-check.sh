#!/usr/bin/env bash
#
# test-onlyoffice-check.sh — nextcloud:fileservice's onlyoffice connector check
# gives the verdict the run actually produced (#714).
#
# Three faults hid behind one symptom — euro-office failing the nightly on
# "Error while downloading the document file to be converted":
#
#   1. No TTY. nextcloud-occ execs `systemd-run --pty --wait`; over a
#      non-interactive ssh it returns 0 having run nothing, so settings_error
#      was never refreshed and the last stored error stood for ever.
#   2. No readiness. The sweep reaches the check straight after euro-office's
#      OS update restarts the document server. Measured on the test site
#      (2026-09-23): /healthcheck answers `true` 22 s after a restart and the
#      round trip succeeds at 23 s — a check inside that window fails for real.
#   3. Exit code read as "did it run". The command returns 1 on a genuine
#      failure (DocumentServer.php), so treating every non-zero as "did not
#      run" reported a real outage as "could not determine". That was the first
#      #714 fix; this suite exists partly because of it.
#
# The block is lifted out of update-service.sh and run with `ssh` stubbed, so
# every outcome is exercised without a Nextcloud or a document server.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "${HERE}/../../../.." && pwd)/apps/nextcloud/services/fileservice/update-service.sh"

PASS=0; FAIL=0
ck()   { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
ckin() { if [[ "$3" == *"$2"* ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (missing '$2' in: $3)"; FAIL=$((FAIL+1)); fi; }

[[ -f "${SRC}" ]] || { echo "update-service.sh not found — cannot run here."; exit 77; }
ck "the service script parses" "yes" "$(bash -n "${SRC}" 2>/dev/null && echo yes || echo no)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/oo-check.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

# The verdict block: from its first variable to the comment that opens the
# three-way chain.
awk '/^            _oo_err=""$/{f=1} f&&/# Three outcomes, not two/{exit} f{print}' "${SRC}" > "${TMP}/block.sh"
[[ -s "${TMP}/block.sh" ]] || { echo "  FAIL: could not extract the verdict block"; exit 1; }
bash -n "${TMP}/block.sh" 2>/dev/null && ck "the verdict block extracts and parses" "yes" "yes" \
    || { ck "the verdict block extracts and parses" "yes" "no"; exit 1; }

# run <healthcheck-answer> <check-output>
# Prints: verdict|err|why|ssh-invocations
run() {
    HC="$1" CHECK_OUT="$2" CALLS="${TMP}/calls" bash -c '
        : > "${CALLS}"
        NC_HOST="nextcloud.example.internal"
        EO_HOST="euro-office.example.internal"
        OO_READY_TIMEOUT=6          # keep the "never ready" case fast
        sleep() { :; }
        ssh() {
            echo "ssh $*" >> "${CALLS}"
            case "$*" in
                *healthcheck*) printf "%s\n" "${HC}" ;;
                *documentserver\ --check*) printf "%s\n" "${CHECK_OUT}" ;;
            esac
        }
        . '"${TMP}"'/block.sh
        printf "%s|%s|%s\n" "${_oo_verdict}" "${_oo_err}" "${_oo_why}"
    ' 2>/dev/null
}

# ── working ─────────────────────────────────────────────────────────────────
out="$(run true $'Document server https://eo.example.org/ version 9.3.1.37 is successfully connected\r')"
ck   "a successful round trip is WORKING"               "working" "${out%%|*}"
calls="$(cat "${TMP}/calls")"
ckin "…the check ran over an ssh that forces a TTY"      "ssh -tt" "$(grep -- '--check' <<< "${calls}")"
ckin "…with --no-ansi, so the verdict text is plain"     "--no-ansi" "$(grep -- '--check' <<< "${calls}")"
# The gate ran before the check, not after.
first_hc="$(grep -n healthcheck <<< "${calls}" | head -1 | cut -d: -f1)"
first_ck="$(grep -n -- '--check' <<< "${calls}" | head -1 | cut -d: -f1)"
ck   "…and only after the document server was healthy"  "yes" "$([[ -n "${first_hc}" && -n "${first_ck}" && "${first_hc}" -lt "${first_ck}" ]] && echo yes || echo no)"

# ── broken: a real verdict, with the error it named ─────────────────────────
out="$(run true 'Error connection: Error occurred in the document service: Error while downloading the document file to be converted.')"
ck   "an Error connection is BROKEN, not unknown"       "broken" "${out%%|*}"
ckin "…carrying the error the check named"              "Error while downloading the document file" "${out}"

out="$(run true 'Document server is not configured')"
ck   "an unconfigured document server is BROKEN"        "broken" "${out%%|*}"

# ── unknown: no verdict was produced, so none is reported ───────────────────
out="$(run false '')"
ck   "a document server that never gets healthy is UNKNOWN" "unknown" "${out%%|*}"
ckin "…and says what it waited for"                      "did not report healthy" "${out}"
ck   "…without running a check that would only fail"     "0" "$(grep -c -- '--check' "${TMP}/calls")"

# The wrapper without a TTY: rc 0, no output. That must never read as working.
out="$(run true '')"
ck   "a silent check is UNKNOWN, never WORKING"          "unknown" "${out%%|*}"
ckin "…and says it returned no verdict"                  "returned no verdict" "${out}"

# ── the chain: only BROKEN fails the module ─────────────────────────────────
undet="$(awk '/_oo_verdict}" == "unknown" \]\]; then/{f=1} f{print} f&&/^            elif/{exit}' "${SRC}")"
ck   "the unknown branch does not fail the module"       "0" "$(grep -c 'exit 1' <<< "${undet}")"
broken="$(awk '/onlyoffice connector is wired but NOT working/{f=1} f{print} f&&/^            fi$/{exit}' "${SRC}")"
ck   "the broken branch still does"                      "1" "$(grep -c 'exit 1' <<< "${broken}")"

# ── and the hints never send an operator into the silent no-op ──────────────
ckin "update-service's by-hand hint keeps the TTY" "ssh -t " "$(grep 'by hand:' "${SRC}")"
VERIFIER="$(dirname "${SRC}")/test-service.sh"
ckin "test-service's by-hand hint keeps the TTY"   "ssh -t " "$(grep 'nextcloud-occ onlyoffice:documentserver --check' "${VERIFIER}")"

# ── Nextcloud tolerates clock skew on the connector's JWT ──────────────────
# The document server signs its download request; Nextcloud checks the token's
# iat against its own clock with the app's default leeway of 0. A guest a few
# seconds behind (hrossen, 2026-09-23: 5-6 s for 17 minutes while its NTP was
# unreachable) rejects every download — "Cannot handle token with iat prior
# to …" — which surfaces as "Error while downloading the document file".
NCNIX="$(cd "$(dirname "${SRC}")/../.." && pwd)/nextcloud.nix"
leeway="$(awk '/^      onlyoffice = \{/{f=1} f&&/jwt_leeway/{gsub(/[^0-9]/,""); print; exit}' "${NCNIX}")"
ck "nextcloud.nix sets a JWT leeway for the connector" "yes" "$([[ -n "${leeway}" && "${leeway}" -gt 0 ]] && echo yes || echo "no (${leeway:-unset})")"

echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
