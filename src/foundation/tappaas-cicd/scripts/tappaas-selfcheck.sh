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
# guard anyway rather than turn its absence into seven false failures.
if command -v timeout >/dev/null 2>&1; then
    bounded() { timeout 60 "$@"; }
else
    bounded() { "$@"; }
fi

# Run a command as the tappaas user, whoever we are now.
as_tappaas() {
    if [[ "$(id -un)" == "${TAPPAAS_USER}" ]]; then
        "$@"
    else
        runuser -u "${TAPPAAS_USER}" -- "$@"
    fi
}

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

# ── 1. The managers this flake built actually run ────────────────────
# A broken nixpkgs bump shows up here first: the CLIs are built from the same
# revision as the system, so if the revision is bad they fail to start.
for mgr in module-manager site-manager network-manager backup-manager \
           health-manager identity-manager environment-manager; do
    if ! as_tappaas command -v "${mgr}" >/dev/null 2>&1; then
        bad "${mgr} is not on ${TAPPAAS_USER}'s PATH"
    elif as_tappaas bounded "${mgr}" --help >/dev/null 2>&1; then
        ok "${mgr} runs"
    else
        bad "${mgr} is installed but will not run"
    fi
done

# ── 2. The config cascade still resolves ─────────────────────────────
# Reading a manager's --help proves the binary starts; this proves it can still
# do its job against this site's data.
if as_tappaas bounded module-manager module list >/dev/null 2>&1; then
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

if (( FAIL > 0 )); then
    error "control-plane self-check FAILED — ${PASS} passed, ${FAIL} failed"
    exit 1
fi
info "control-plane self-check passed (${PASS} checks)"
exit 0
