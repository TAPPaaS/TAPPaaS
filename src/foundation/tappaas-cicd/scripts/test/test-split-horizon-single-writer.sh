#!/usr/bin/env bash
# test-split-horizon-single-writer.sh — ADR-021 D5's contract guard.
#
# The split-horizon address must have exactly ONE implementation:
#   network-manager split-horizon-target   (src/.../network-manager/src/splithorizon.ts)
#
# #577 was not a bug in any one writer. It was three writers, each having
# transcribed "the rule" from ADR-005 §6 and each having read it differently:
# network:proxy resolved the authorized CLIENT zone, acme-setup.sh resolved the
# environment's SERVICE zone, environment-manager resolved the same but with its
# own fallback. All three cited the same authority; on a live site they held
# three different addresses. The fix was not to pick a winner — it was to leave
# one implementation and make the others call it.
#
# Nothing structural stops a fourth from appearing. The next person who needs
# the address, in a hurry, five lines from a zones.json they already parsed,
# will write `<subnet>.1` again and it will look completely reasonable in
# review. This guard is the thing that objects.
#
# Two sweeps, no curated allow-list of files (a curated list is what let #577
# persist across three writers — each new one was simply not on it):
#   1. the retired resolvers' names must not come back
#   2. no file outside the resolver may derive a gateway from a zone subnet
#      near split-horizon/wildcard-DNS code
#
# Self-contained: grep + git plumbing, no cluster, no network.
# Exits 1 if any assertion fails.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# A SOURCE-TREE check: it reads what git records, so it needs the checkout, not
# a copy of it. The test harness ships the working tree to a scratch directory
# on the site, where there is no work tree to read — exit 77 (the sweep's
# "cannot run here", test.sh Test 9z) with the reason on the last line, rather
# than failing on every single run and training everyone to ignore red.
REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null || true)"
# The second half matters as much as the first: a copy unpacked INSIDE some
# other repository would resolve a toplevel that does not track this project,
# and the check would then read a tree it knows nothing about.
if [[ -z "${REPO_ROOT}" ]] || \
   [[ -z "$(git -C "${REPO_ROOT}" ls-files -- src/foundation/tappaas-cicd/test.sh 2>/dev/null)" ]]; then
    echo "no TAPPaaS git work tree here (a shipped copy, not a checkout) — this source-tree check runs on a clone"
    exit 77
fi
cd "${REPO_ROOT}" || { echo "cannot cd to repo root" >&2; exit 1; }

PASS=0
FAIL=0
pass() { printf '  \xe2\x9c\x93 %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \xe2\x9c\x97 %s\n' "$1"; FAIL=$((FAIL + 1)); }

# The one sanctioned implementation. Everything else must call it.
RESOLVER="src/foundation/tappaas-cicd/manager/network-manager/src/splithorizon.ts"

# Both sweeps below look at PRODUCTION code only. A test file legitimately
# asserts concrete addresses and exercises the generic zone_gateway_ip helper —
# that is the test doing its job, not a fourth writer. Scanning them produced
# only false positives, and a guard that cries wolf is a guard people delete.
is_test_path() {
    case "$1" in
        */test/*|*/tests/*|*/test-*|*/test.sh|*.test.ts|*/test-variants/*|*_test.py|*/test_*.py) return 0 ;;
        *) return 1 ;;
    esac
}

echo "ADR-021 D5: the split-horizon address has exactly one implementation"
echo

# ── 0. the resolver itself exists and is the one that answers ───────────────
echo "[0] the sanctioned resolver is present"
if [ -f "${RESOLVER}" ] && grep -q "resolveSplitHorizonTarget" "${RESOLVER}"; then
    pass "${RESOLVER} defines resolveSplitHorizonTarget()"
else
    fail "${RESOLVER} is missing or no longer defines resolveSplitHorizonTarget()"
fi
if grep -rq '"split-horizon-target"' src/foundation/tappaas-cicd/manager/network-manager/src/main.ts; then
    pass "network-manager exposes the 'split-horizon-target' verb"
else
    fail "network-manager no longer exposes 'split-horizon-target' — the callers shell out to it"
fi

# stdout is the ADDRESS CHANNEL. The command's human diagnostics must go to
# stderr, and NOT through info()/warn() — those console.log to stdout. Shipped
# briefly doing exactly that, and a caller's GW="$(… )" captured two lines:
# the address and the prose, which Unbound would then have been handed as an
# "IP". Caught only by an exact-equality assertion in the deep probe.
_cmd_body="$(sed -n '/function cmdSplitHorizonTarget/,/^}/p' \
             src/foundation/tappaas-cicd/manager/network-manager/src/main.ts 2>/dev/null)"
if [ -z "${_cmd_body}" ]; then
    fail "cmdSplitHorizonTarget() not found in main.ts"
elif printf '%s' "${_cmd_body}" | grep -qE '^[[:space:]]*(info|warn)\('; then
    fail "cmdSplitHorizonTarget() logs via info()/warn() — those write to STDOUT and would corrupt the address a caller command-substitutes"
elif printf '%s' "${_cmd_body}" | grep -q 'process.stderr.write'; then
    pass "split-horizon-target keeps stdout clean (diagnostics go to stderr)"
else
    fail "split-horizon-target has no stderr diagnostics — check stdout is still address-only"
fi
echo

# ── 1. the retired resolvers must not come back ─────────────────────────────
# These are the exact symbols #577 found disagreeing. A reappearance means
# somebody reintroduced a local derivation rather than calling the resolver.
echo "[1] the retired per-writer resolvers stay retired"
_retired=0
for sym in proxy_split_horizon_gateway zoneGatewayIp wildcardDnsGateway; do
    # Match definitions/uses in code, not the prose that explains their removal.
    _hits=""
    while IFS= read -r _line; do
        [ -n "${_line}" ] || continue
        _f="${_line%%:*}"
        [ "${_f}" = "${RESOLVER}" ] && continue
        is_test_path "${_f}" && continue
        _hits="${_hits}${_line}"$'\n'
    done < <(grep -rn --include='*.sh' --include='*.ts' --include='*.py' \
                 -e "^[[:space:]]*\(function[[:space:]]\+\)\?${sym}[[:space:]]*(" \
                 -e "[^A-Za-z_]${sym}(" \
                 src/ 2>/dev/null \
             | grep -vE '^\S+:[0-9]+:[[:space:]]*(#|//|\*)' || true)
    if [ -n "${_hits}" ]; then
        fail "retired resolver '${sym}' is referenced again:"
        printf '      %s\n' "${_hits}" >&2
        _retired=1
    fi
done
[ "${_retired}" -eq 0 ] && pass "none of the retired per-writer resolvers are referenced"
echo

# ── 2. no second derivation in production code ──────────────────────────────
# The first draft of this sweep flagged any assignment to something named
# `gatewayIp`, which cannot tell DERIVING an address from RECEIVING one — it
# fired on the line that reads the resolver's own stdout. So test the two
# structural tells instead, both of which mean "somebody rebuilt the rule":
#
#   2a. constructing <subnet>.1 by slicing three octets off a CIDR
#   2b. calling the generic zone_gateway_ip/dmz_gateway_ip helper from a file
#       that also does split-horizon work
#
# HELPER_HOME defines those generic helpers and is excluded: they are used for
# DHCP, module install and firewall rules too, and banning them outright would
# be a claim ADR-021 does not make. What ADR-021 bans is using them to answer
# the split-horizon question — which, as of D5, no production file does.
HELPER_HOME="src/foundation/tappaas-cicd/lib/common-install-routines.sh"

echo "[2a] no production file builds a gateway by slicing a subnet"
_second=0
while IFS= read -r f; do
    [ -n "${f}" ] || continue
    [ "${f}" = "${RESOLVER}" ] && continue
    [ "${f}" = "${HELPER_HOME}" ] && continue
    is_test_path "${f}" && continue
    grep -qiE 'split.horizon|wildcard.*(dns|override)' "${f}" 2>/dev/null || continue
    # Three octets kept, ".1" appended — in jq, JS or Python form.
    _deriv="$(grep -nE '\.\[0:3\]|\[0:3\]|slice\(0, ?3\)|\[:3\]' "${f}" 2>/dev/null \
              | grep -vE ':[[:space:]]*(#|//|\*)' || true)"
    if [ -n "${_deriv}" ]; then
        fail "${f} builds an address from a subnet near split-horizon code:"
        printf '      %s\n' "${_deriv}" >&2
        _second=1
    fi
done < <(git ls-files 'src/**/*.sh' 'src/**/*.ts' 'src/**/*.py' 2>/dev/null)
[ "${_second}" -eq 0 ] && pass "no production file slices a subnet into a split-horizon address"
echo

echo "[2b] no split-horizon code calls the generic gateway helpers"
# As of ADR-021 D5 this is exactly zero production files — the proxy scripts and
# acme-setup.sh both stopped. If one comes back, the rule has been re-derived
# from a zone again, which is #577 restarting.
_helper=0
while IFS= read -r f; do
    [ -n "${f}" ] || continue
    [ "${f}" = "${HELPER_HOME}" ] && continue
    is_test_path "${f}" && continue
    grep -qiE 'split.horizon|wildcard.*(dns|override)' "${f}" 2>/dev/null || continue
    _calls="$(grep -nE '(zone|dmz)_gateway_ip' "${f}" 2>/dev/null \
              | grep -vE ':[[:space:]]*(#|//|\*)' || true)"
    if [ -n "${_calls}" ]; then
        fail "${f} resolves a split-horizon address via the generic zone helper:"
        printf '      %s\n' "${_calls}" >&2
        _helper=1
    fi
done < <(git ls-files 'src/**/*.sh' 'src/**/*.ts' 'src/**/*.py' 2>/dev/null)
[ "${_helper}" -eq 0 ] && pass "no production split-horizon code calls zone_gateway_ip/dmz_gateway_ip"
echo

# ── 3. every writer routes through the resolver ─────────────────────────────
# The three files #577 named must each reference the verb. If one stops, it has
# either been retired (fine — drop it from this list, deliberately) or it has
# gone back to deriving its own answer (not fine).
echo "[3] each #577 writer calls the resolver"
for f in \
    src/foundation/network/services/proxy/access-list.sh \
    src/foundation/tappaas-cicd/scripts/acme-setup.sh \
    src/foundation/tappaas-cicd/manager/environment-manager/src/clients.ts
do
    if [ ! -f "${f}" ]; then
        pass "${f} no longer exists (retired)"
    elif grep -q 'split-horizon-target' "${f}"; then
        pass "$(basename "${f}") calls split-horizon-target"
    else
        fail "$(basename "${f}") no longer calls split-horizon-target — does it derive its own address again?"
    fi
done
echo

# ── 4. the exit-code contract is honoured by the shell callers ──────────────
# rc 3 (unpublished, ADR-021 R3) is a supported state, not a failure. A caller
# that only tests success/failure turns a deliberately-unpublished service back
# into an error — the behaviour R3 exists to remove.
echo "[4] shell callers distinguish rc 3 (unpublished) from rc 1 (error)"
for f in \
    src/foundation/network/services/proxy/install-service.sh \
    src/foundation/network/services/proxy/update-service.sh
do
    [ -f "${f}" ] || { pass "${f} no longer exists (retired)"; continue; }
    if grep -q 'proxy_split_horizon_target' "${f}" && grep -qE '[-]eq 3|== 3' "${f}"; then
        pass "$(basename "${f}") branches on rc 3"
    else
        fail "$(basename "${f}") calls the resolver but never tests for rc 3 (R3 would read as an error)"
    fi
done

echo
echo "  Results: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ] || exit 1
