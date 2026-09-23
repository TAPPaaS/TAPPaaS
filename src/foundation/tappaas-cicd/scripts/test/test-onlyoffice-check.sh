#!/usr/bin/env bash
#
# test-onlyoffice-check.sh — the onlyoffice connector check must actually run,
# and a check that did not run must not fail the module (#714).
#
# What happened: the NixOS `nextcloud-occ` wrapper execs
# `systemd-run --pty --wait`, which needs a TTY. nextcloud:fileservice invoked
# it over a non-interactive ssh, where it prints nothing AND DOES NOT RUN — it
# returns 0 having done nothing. So `settings_error`, the row the code reads as
# "the authoritative state", was never refreshed by a sweep. The last stored
# error stood for ever and euro-office failed night after night on a string no
# run could change, while the connector was healthy the whole time.
#
# Measured on hrossen, 2026-09-23:
#   ssh  tappaas@nextcloud … 'sudo nextcloud-occ status'   → rc=0, NO output
#   ssh -tt tappaas@nextcloud … 'sudo nextcloud-occ status' → full output
#   the real check with a TTY answered in 1.5s: "Document server … is
#   successfully connected", and settings_error cleared.
#
# This is a SOURCE-CONTRACT test: the block lives inside several layers of
# conditionals in update-service.sh and cannot be executed without a Nextcloud
# and a document server. It pins the three decisions that incident turned on.
# The live behaviour is verified by the module's own test-service.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "${HERE}/../../../.." && pwd)/apps/nextcloud/services/fileservice/update-service.sh"

PASS=0; FAIL=0
ck()   { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
ckin() { if [[ "$3" == *"$2"* ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (missing '$2')"; FAIL=$((FAIL+1)); fi; }

[[ -f "${SRC}" ]] || { echo "update-service.sh not found — cannot run here."; exit 77; }
BODY="$(cat "${SRC}")"
ck "the service script parses" "yes" "$(bash -n "${SRC}" 2>/dev/null && echo yes || echo no)"

# ── 1. the check is invoked in a way that can actually run ─────────────────
occ_line="$(grep -n 'nextcloud-occ onlyoffice:documentserver --check' "${SRC}" | grep -v '^\s*#' | head -1)"
ckin "the check is invoked at all"              "onlyoffice:documentserver --check" "${occ_line}"
# The whole incident in one assertion. Look only at the EXECUTED invocation —
# the line that runs the check, and the ssh line continued into it — never at a
# comment, several of which mention ssh -tt precisely because this matters.
_exec_ln="$(grep -n 'nextcloud-occ onlyoffice:documentserver --check' "${SRC}" \
            | grep -v ':[[:space:]]*#' | grep 'sudo timeout' | head -1 | cut -d: -f1)"
if [[ -z "${_exec_ln}" ]]; then
    ck "the executed check invocation was found" "yes" "no"
    invoke=""
else
    invoke="$(sed -n "$((_exec_ln>2 ? _exec_ln-2 : 1)),${_exec_ln}p" "${SRC}" | grep -v '^[[:space:]]*#')"
fi
ckin "…over an ssh that forces a TTY (-tt)"     "ssh -tt" "${invoke}"

# A hand-run hint that omits the TTY sends the operator down the same hole.
hint="$(grep -n 'by hand:' "${SRC}" | head -1)"
ckin "the by-hand hint keeps the TTY"           "ssh -t " "${hint}"

# ── 2. the row read back is this run's answer ──────────────────────────────
ckin "settings_error is cleared before the check" \
     "DELETE FROM oc_appconfig WHERE appid='onlyoffice' AND configkey='settings_error'" "${BODY}"
# Order matters: clearing AFTER the check would erase the verdict it just wrote.
_del="$(grep -n 'DELETE FROM oc_appconfig' "${SRC}" | head -1 | cut -d: -f1)"
_chk="$(grep -n 'nextcloud-occ onlyoffice:documentserver --check' "${SRC}" | grep -v '#' | head -1 | cut -d: -f1)"
if [[ -n "${_del}" && -n "${_chk}" && "${_del}" -lt "${_chk}" ]]; then
    ck "…before it, not after" "yes" "yes"
else
    ck "…before it, not after" "yes" "no (delete at ${_del:-?}, check at ${_chk:-?})"
fi

# ── 3. three outcomes, and only one of them fails the module ───────────────
ckin "a run that could not determine says so"   "could not determine whether the onlyoffice connector works" "${BODY}"
ckin "…and the chain starts with that case"     'if [[ "${_oo_ran}" -eq 0 ]]; then' "${BODY}"
ckin "…the healthy case follows it"             'elif [[ -z "${_oo_err}" ]]; then' "${BODY}"

# The undetermined branch must not exit: that is the regression, exactly.
undet="$(awk '/if \[\[ "\$\{_oo_ran\}" -eq 0 \]\]; then/{f=1} f{print} f&&/^            elif/{exit}' "${SRC}")"
ck "the undetermined branch does not fail the module" "0" "$(grep -c 'exit 1' <<< "${undet}")"

# …while a verdict of "broken" still does.
broken="$(awk '/onlyoffice connector is wired but NOT working/{f=1} f{print} f&&/^            fi$/{exit}' "${SRC}")"
ck "a real failure still fails it" "1" "$(grep -c 'exit 1' <<< "${broken}")"

# The stale-verdict wording is gone: it described a timeout that was not
# happening, and pointed diagnosis at the wrong thing for four nights.
ck "the old 'STORED verdict' wording is gone" "0" "$(grep -c 'STORED verdict' <<< "${BODY}")"

echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
