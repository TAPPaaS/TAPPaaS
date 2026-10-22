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
# Check 4 below closes that gap (#719).
#
# What this check does earn: a dangling or garbage-collected link, and a manager
# that starts but cannot run.
# Which managers: the control plane's registry (ADR-035 D5), written by every
# prepare step; the standard nine when it is not there yet (a first install).
_registry="${SELFCHECK_REGISTRY:-/home/${TAPPAAS_USER}/config/control-plane.json}"
_managers="$(jq -r '.components[]? | select(.kind == "manager") | .name' "${_registry}" 2>/dev/null)"
if [[ -z "${_managers}" ]]; then
    warn "  no control-plane registry (${_registry}) — checking the standard managers"
    _managers="module-manager site-manager network-manager backup-manager health-manager identity-manager environment-manager storage-manager rack-manager"
fi
for mgr in ${_managers}; do
    if ! as_tappaas bash -c 'command -v "$1"' _ "${mgr}" >/dev/null 2>&1; then
        bad "${mgr} is not on ${TAPPAAS_USER}'s PATH"
    elif as_tappaas "${BOUND[@]}" "${mgr}" --help >/dev/null 2>&1; then
        ok "${mgr} runs"
    else
        bad "${mgr} is installed but will not run"
    fi
done

# A link to nothing is no control plane's: report it (refresh-control-plane.sh
# removes the ones it planted; one to a deleted script outlived it, #719).
_hb="$(getent passwd "${TAPPAAS_USER}" 2>/dev/null | cut -d: -f6)"; _hb="${SELFCHECK_BIN:-${_hb:-/home/${TAPPAAS_USER}}/bin}"
for _l in "${_hb}"/*; do
    [[ -L "${_l}" && ! -e "${_l}" ]] && warn "  dangling link in ${_hb}: ${_l##*/} -> $(readlink "${_l}")"
done

# Code patched in place runs ahead of what the checkout declares, and the next
# refresh reverts it silently (ADR-028 D12, #746). A warning, never a failure.
_dd="${SELFCHECK_REPO:-/home/${TAPPAAS_USER}/TAPPaaS}/src/foundation/tappaas-cicd/lib/deployed-drift.sh"
if [[ -r "${_dd}" ]]; then
    # shellcheck source=../lib/deployed-drift.sh disable=SC1090
    . "${_dd}"
    while IFS= read -r _d; do [[ -n "${_d}" ]] && warn "  ${_d}"; done \
        < <(deployed_drift "${SELFCHECK_REPO:-/home/${TAPPAAS_USER}/TAPPaaS}" "${_hb}")
fi

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

# ── 4. What the new generation implies IS what is linked (#719) ───────
#
# Check 1 proves the INSTALLED binaries run — which they do across a switch to a
# revision that could not build them, since ~tappaas/bin links into immutable
# store paths. This check makes the self-check mean what D10 says: every
# component the checkout's flake builds (the seven managers, the two controllers,
# node-provisioner, update-tappaas) must be BUILT at the store path this
# generation implies, and ~tappaas/bin must link INTO it.
#
# The prepare step (refresh-control-plane.sh) builds and relinks every component
# before this rebuild; a component that failed to build there is non-fatal
# (exit 10, "those bins are STALE") — and used to reach the sweep unnoticed.
# Here it fails, and the rebuild rolls back (#719, operator 2026-10-03: one way
# back, the D10 one). Four outcomes per component, only the first passes:
#   match          built, and linked from ~/bin
#   not built      the implied path is not in the store — prepare could not build it
#   not linked     built, but nothing in ~/bin points into it
#   stale link     a link points into a store path this generation does not imply
# A flake that cannot even evaluate its packages fails the check too.
#
# It EVALUATES, never builds: one `nix eval` of all packages (~1 s on hrossen);
# the builds are prepare's. The 83-odd links that point straight at the checkout
# (shell scripts) follow the pull, not the pin — nothing to compare.
SELFCHECK_FLAKE="${SELFCHECK_FLAKE:-/home/${TAPPAAS_USER}/TAPPaaS/src/foundation/tappaas-cicd}"
_store="${SELFCHECK_STORE:-/nix/store}"   # tests use a fake one
_home="$(getent passwd "${TAPPAAS_USER}" 2>/dev/null | cut -d: -f6)"
_home="${SELFCHECK_BIN:-${_home:-/home/${TAPPAAS_USER}}/bin}"
if [[ ! -f "${SELFCHECK_FLAKE}/flake.nix" ]] || ! command -v nix >/dev/null 2>&1; then
    warn "  no flake at ${SELFCHECK_FLAKE} or no nix — what the generation implies is not checked"
else
    _t0=${SECONDS}
    # As root, exactly as tappaas-self-rebuild.sh runs nix: HOME holds root's
    # safe.directory grant for the tappaas-owned checkout (nix's libgit2 reads it
    # from $HOME/.gitconfig only). Without it, in the unit — not from a sudo
    # shell, where git trusts SUDO_UID — libgit2 refuses the repository ("not
    # owned by current user"), and the first sweep after #719 rolled back a
    # healthy generation for it (2026-10-04).
    _nixenv=()
    [[ "${EUID:-$(id -u)}" -eq 0 && -d /var/lib/tappaas-rebuild ]] && _nixenv=(env HOME=/var/lib/tappaas-rebuild)
    _err="$(mktemp)"
    _implied="$("${_nixenv[@]}" nix --extra-experimental-features 'nix-command flakes' \
        eval --json --no-write-lock-file "${SELFCHECK_FLAKE}#packages.x86_64-linux" \
        --apply 'ps: builtins.mapAttrs (n: p: p.outPath) ps' 2>"${_err}" || true)"
    if ! jq -e 'type == "object" and length > 0' >/dev/null 2>&1 <<<"${_implied}"; then
        bad "the flake's components cannot be evaluated: $(grep -E '^error|error:' "${_err}" | tail -1 | sed 's/^ *//' | cut -c1-200)"
    else
        # Every store-backed link, as "<package root> <link name>".
        _links="$(for _l in "${_home}"/*; do
                      [[ -L "${_l}" ]] || continue
                      _r="$(readlink -f "${_l}" 2>/dev/null)" || continue
                      [[ "${_r}" == "${_store}"/* ]] || continue
                      _rel="${_r#"${_store}"/}"
                      printf '%s %s\n' "${_store}/${_rel%%/*}" "${_l##*/}"
                  done)"
        _ok=0
        while read -r _name _path; do
            if [[ ! -e "${_path}" ]]; then
                bad "${_name}: not built — this generation implies ${_path##*/}, and prepare could not build it"
            elif ! grep -qF "${_path} " <<<"${_links}"; then
                bad "${_name}: built (${_path##*/}) but nothing in ${_home} links to it"
            else
                _ok=$((_ok + 1))
            fi
        done < <(jq -r 'to_entries[] | "\(.key) \(.value)"' <<<"${_implied}")
        # A module's own components (ADR-035 D2) are built by its install, not
        # by this generation: the registry names them, and their links are theirs.
        _theirs="$(jq -c '[.components[]? | select(.module != "tappaas-cicd") | .name, (.aliases // [])[]]' "${_registry}" 2>/dev/null || echo '[]')"
        while read -r _root _link; do
            [[ -n "${_root}" ]] || continue
            jq -e --arg l "${_link}" 'index($l)' >/dev/null 2>&1 <<<"${_theirs}" && continue
            jq -e --arg r "${_root}" 'any(.[]; . == $r)' >/dev/null <<<"${_implied}" \
                || bad "${_link}: links to ${_root##*/}, which this generation does not build — a stale link"
        done <<<"${_links}"
        (( _ok == $(jq 'length' <<<"${_implied}") )) \
            && ok "all ${_ok} components are built as this generation implies, and linked ($((SECONDS - _t0))s)"
    fi
    rm -f "${_err}"
fi

if (( FAIL > 0 )); then
    error "control-plane self-check FAILED — ${PASS} passed, ${FAIL} failed"
    exit 1
fi
info "control-plane self-check passed (${PASS} checks)"
exit 0
