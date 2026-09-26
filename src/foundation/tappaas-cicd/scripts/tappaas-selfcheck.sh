#!/usr/bin/env bash
# tappaas-selfcheck.sh — is this control plane working? (ADR-028 D10)
#
# The mothership rebuilds itself before every sweep (ADR-017 D3) and, until
# #713, nothing looked at the result. A `nixos-rebuild switch` that returns 0
# can still leave a control plane that cannot resolve a config or whose managers
# no longer start — and that system then runs the estate's update.
#
# This script answers one question — "does the control plane work?" — cheaply
# enough to run on every rebuild and without touching the network or changing
# anything. tappaas-self-rebuild.sh runs it after the switch and rolls the
# generation back when it fails.
#
# Deliberately NOT the cicd test suite: that is a developer suite, it takes
# minutes, and it runs from a checkout. This runs from the installed system in
# about a second.
#
# Usage:
#   tappaas-selfcheck.sh --record <file>     write the pre-change failed-unit baseline
#   tappaas-selfcheck.sh [--baseline <file>] run the checks; exit 0 pass, 1 fail
#
# Runs as root (from the rebuild) or as tappaas (by hand). The manager checks
# always run AS tappaas: root must not execute code from ~tappaas/bin, and the
# question is whether the control plane works for the user that runs it.

set -uo pipefail
# As root, resolve tools only from the system profile: root must not pick up a
# binary from a tappaas-writable directory. As tappaas, keep the caller's PATH —
# that IS the PATH the control plane runs with, so checking against anything
# else would be checking the wrong system.
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    export PATH=/run/wrappers/bin:/run/current-system/sw/bin
fi

info()  { echo -e "\033[32m[Info]\033[m $*"; }
warn()  { echo -e "\033[33m[Warning]\033[m $*"; }
error() { echo -e "\033[01;31m[Error]\033[m $*" >&2; }
# Defined because this script calls it: a self-contained script that provides
# info/warn/error and omits debug turns every debug call into "command not
# found" at the moment it is trying to explain something — the #423 defect, met
# three times in one day (Create-TAPPaaS-LXC.sh, convert-json-to-config.sh's
# fallback block, and here). Silent unless TAPPAAS_DEBUG=1, per convention.
debug() { [[ "${TAPPAAS_DEBUG:-0}" -eq 1 ]] || return 0; echo -e "\033[36m[Debug]\033[m $*"; }

TAPPAAS_USER="${TAPPAAS_USER:-tappaas}"

# The units that must not be newly failed. `update-tappaas.service` is excluded
# because this runs INSIDE it: its own last-run state is whatever the previous
# sweep left, which says nothing about the generation just built.
failed_units() {
    systemctl --failed --no-legend --plain 2>/dev/null \
        | awk '{print $1}' | grep -v '^update-tappaas\.service$' | sort
}

# `timeout` bounds a manager that hangs — a real failure mode for a CLI whose
# backend is unreachable. It is coreutils, so it is always on the mothership;
# guard anyway rather than turn its absence into seven false failures. A word
# list, not a function: under runuser it has to be a PROGRAM (see below).
BOUND=()
command -v timeout >/dev/null 2>&1 && BOUND=(timeout 60)

# The PATH the control plane runs with: update-tappaas.service's own (#713).
# As root, the child runuser starts inherits root's system-only PATH above,
# which does not hold ~tappaas/bin — every manager then read as "not on
# tappaas's PATH", the check failed on a healthy mothership, and the rebuild
# rolled back and aborted every sweep. Asked of the unit, so a change to it is
# followed; the fallback is what that unit carries today.
tappaas_path() {
    local p home
    p="$(systemctl show update-tappaas.service -p Environment --value 2>/dev/null \
        | tr ' ' '\n' | sed -n 's/^PATH=//p' | head -1)"
    if [[ -z "${p}" ]]; then
        home="$(getent passwd "${TAPPAAS_USER}" 2>/dev/null | cut -d: -f6)"
        home="${home:-/home/${TAPPAAS_USER}}"
        p="${home}/bin:/run/wrappers/bin:${home}/.nix-profile/bin:/etc/profiles/per-user/${TAPPAAS_USER}/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin"
    fi
    printf '%s' "${p}"
}

# Run a PROGRAM as the tappaas user, whoever we are now. runuser executes its
# argument directly — no shell — so a builtin (`command -v`) or a function
# cannot be passed through it; callers pass programs only (#713).
as_tappaas() {
    if [[ "$(id -un)" == "${TAPPAAS_USER}" ]]; then
        "$@"
    else
        runuser -u "${TAPPAAS_USER}" -- env PATH="${TAPPAAS_PATH}" "$@"
    fi
}
TAPPAAS_PATH=""
[[ "$(id -un)" == "${TAPPAAS_USER}" ]] || TAPPAAS_PATH="$(tappaas_path)"

MODE=check
BASELINE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --record)   MODE=record; BASELINE="${2:?--record needs a file}"; shift 2 ;;
        --baseline) BASELINE="${2:?--baseline needs a file}"; shift 2 ;;
        -h|--help)  sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          error "unknown argument: $1"; exit 2 ;;
    esac
done

if [[ "${MODE}" == record ]]; then
    failed_units > "${BASELINE}" 2>/dev/null || : > "${BASELINE}"
    exit 0
fi

PASS=0; FAIL=0
ok()  { info "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { error "  ✗ $1"; FAIL=$((FAIL + 1)); }

# ── 1. The managers on the operator's PATH actually run ──────────────
# This proves the INSTALLED control plane works. It does NOT prove the new
# generation's revision can build it (#719): ~tappaas/bin holds symlinks into
# immutable store paths planted by each component's install.sh, and a
# `nixos-rebuild switch` neither rebuilds nor relinks them — so these binaries
# keep working across a switch to a revision that could not build them. Measured
# on hrossen 2026-09-23: 0 managers in the system closure, 38 links in ~/bin.
# Check 4 below reports that gap; closing it is #719 step 2.
#
# What this check does earn: a dangling or garbage-collected link, and a manager
# that starts but cannot run.
for mgr in module-manager site-manager network-manager backup-manager \
           health-manager identity-manager environment-manager; do
    if ! as_tappaas bash -c 'command -v "$1"' _ "${mgr}" >/dev/null 2>&1; then
        bad "${mgr} is not on ${TAPPAAS_USER}'s PATH"
    elif as_tappaas "${BOUND[@]}" "${mgr}" --help >/dev/null 2>&1; then
        ok "${mgr} runs"
    else
        bad "${mgr} is installed but will not run"
    fi
done

# ── 2. The config cascade still resolves ─────────────────────────────
# Reading a manager's --help proves the binary starts; this proves it can still
# do its job against this site's data.
if as_tappaas "${BOUND[@]}" module-manager module list >/dev/null 2>&1; then
    ok "the module catalogue resolves"
else
    bad "module-manager cannot list the site's modules — the config cascade does not resolve"
fi

# ── 3. Nothing NEWLY failed ──────────────────────────────────────────
# Absolute "no failed units" would be wrong: a site can carry an unrelated
# failure for days. What matters is whether this change broke something that
# was working a minute ago.
if [[ -n "${BASELINE}" && -f "${BASELINE}" ]]; then
    _new="$(comm -13 "${BASELINE}" <(failed_units) 2>/dev/null)"
    if [[ -z "${_new}" ]]; then
        ok "no unit failed that was not already failing"
    else
        bad "newly failed unit(s): $(tr '\n' ' ' <<< "${_new}")"
    fi
else
    warn "  no baseline given — skipping the newly-failed-unit check"
fi

# ── 4. What the new generation implies vs what is linked (#719) ──────
#
# REPORT-ONLY, deliberately. The decision on #719 is to make the self-check
# verify what the new generation implies rather than what happens to be linked,
# and to relink ~tappaas/bin as part of the rebuild so a mismatch is fixed
# rather than merely reported. Both belong together and both change what every
# mothership rebuild does, so this step only MEASURES: it never sets FAIL and
# never influences the rollback. What it is here to answer is the two things
# nobody has numbers for yet — what the comparison actually says on a real
# rebuild, and what it costs.
#
# Two things the first run measured on hrossen (2026-09-26), both of which step 2
# needs and neither of which was known when #719 was written:
#
#   6 of 7 managers matched, 0 stale, 1 would need a build, in 3s (eval only).
#   The one was health-manager, whose source had changed that morning.
#
#   ~tappaas/bin is NOT all store-backed, as the issue assumes. Of 108 links:
#   25 point into /nix/store (the built managers and controllers) and 83 point
#   straight at the CHECKOUT (the shell scripts). A store-path comparison is
#   therefore meaningful for a quarter of ~/bin; the checkout-backed majority is
#   current the moment a pull happens, and carries the opposite risk — those
#   scripts never go through the pin at all.
#
# It EVALUATES rather than builds. `nix eval` of the flake's package outPath is
# cheap and tells us whether the implied store path differs from the linked one.
# It cannot tell us the revision would fail to BUILD them — only a build proves
# that, and that is the expensive half step 2 has to price. So the third state
# below ("not in the store") is precisely the population that would need
# building, which is the cost estimate step 2 needs.
SELFCHECK_FLAKE="${SELFCHECK_FLAKE:-/home/${TAPPAAS_USER}/TAPPaaS/src/foundation/tappaas-cicd}"
if [[ -f "${SELFCHECK_FLAKE}/flake.nix" ]] && command -v nix >/dev/null 2>&1; then
    _t0=${SECONDS}
    _same=0; _stale=0; _wouldbuild=0; _unknown=0
    _home="$(getent passwd "${TAPPAAS_USER}" 2>/dev/null | cut -d: -f6)"
    _home="${_home:-/home/${TAPPAAS_USER}}"
    for mgr in module-manager site-manager network-manager backup-manager \
               health-manager identity-manager environment-manager; do
        # The link resolves to <out>/bin/<mgr>; the package out path is its parent's parent.
        _linked=""
        if [[ -e "${_home}/bin/${mgr}" ]]; then
            _resolved="$(readlink -f "${_home}/bin/${mgr}" 2>/dev/null || true)"
            [[ -n "${_resolved}" ]] && _linked="${_resolved%/bin/*}"
        fi
        _implied="$(nix eval --raw --no-write-lock-file \
            "${SELFCHECK_FLAKE}#packages.x86_64-linux.${mgr}.outPath" 2>/dev/null || true)"
        if [[ -z "${_implied}" ]]; then
            _unknown=$((_unknown + 1))
            debug "  ${mgr}: could not evaluate what this generation implies"
        elif [[ "${_implied}" == "${_linked}" ]]; then
            _same=$((_same + 1))
        elif [[ -e "${_implied}" ]]; then
            _stale=$((_stale + 1))
            debug "  ${mgr}: linked ${_linked##*/} but this generation implies ${_implied##*/} (already in the store)"
        else
            _wouldbuild=$((_wouldbuild + 1))
            debug "  ${mgr}: this generation implies ${_implied##*/}, which is NOT in the store — step 2 would have to build it"
        fi
    done
    info "  #719 (report-only): ${_same} manager(s) match this generation, ${_stale} stale link(s), ${_wouldbuild} would need a build, ${_unknown} not evaluable — took $((SECONDS - _t0))s"
    if (( _stale > 0 || _wouldbuild > 0 )); then
        info "    ~${TAPPAAS_USER}/bin does not follow a rebuild; each component's install.sh plants those links."
        info "    Not a failure here — #719 step 2 makes it one, together with relinking on rebuild."
    fi
else
    debug "  #719 report skipped: no flake at ${SELFCHECK_FLAKE} or nix not on PATH"
fi

if (( FAIL > 0 )); then
    error "control-plane self-check FAILED — ${PASS} passed, ${FAIL} failed"
    exit 1
fi
info "control-plane self-check passed (${PASS} checks)"
exit 0
