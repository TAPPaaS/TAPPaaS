#!/usr/bin/env bash
# controller/update.sh — ADR-007 P4/S0 two-level dispatcher (no shared runner).
# Runs each child component's update.sh, skipping TEMPLATE/. Idempotent; a
# failing child does not stop the others (worst rc is returned).
#
# Output: one "[Info] Building <component>" per child; the child's own build
# output is quiet — lines already tagged [Info] pass through, everything else
# goes to [Debug] (shown only when TAPPAAS_DEBUG=1).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_GN=$'\033[32m'; _BL=$'\033[36m'; _CL=$'\033[m'
info()  { echo -e "${_GN}[Info]${_CL} $*"; }
debug() { [ "${TAPPAAS_DEBUG:-0}" = "1" ] && echo -e "${_BL}[Debug]${_CL} $*" || true; }

rc=0
for d in "${here}"/*/; do
    name="$(basename "${d}")"
    [ "${name}" = TEMPLATE ] && continue
    [ -x "${d}update.sh" ] || continue
    info "Building ${name}"
    # Child output: pass [Info] lines through; route the rest to [Debug].
    if "${d}update.sh" "$@" 2>&1 | while IFS= read -r _l; do
           case "${_l}" in
               *'[Info]'*) printf '%s\n' "${_l}" ;;
               *)          debug "${_l}" ;;
           esac
       done
    then :; else rc=$?; fi
done
exit "${rc}"
