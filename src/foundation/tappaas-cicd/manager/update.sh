#!/usr/bin/env bash
# manager/update.sh — ADR-007 P4/S0 two-level dispatcher (no shared runner).
# Runs each child component's update.sh, skipping TEMPLATE/. Idempotent; a
# failing child does not stop the others (worst rc is returned).
#
# Output: a single accumulating line —
#   [Info]   Updating <disp>/ components: name1, name2, …
# each name added as its component finishes building. All child build/link output
# is routed to [Debug] (shown only when TAPPAAS_DEBUG=1); failures are reported
# in full afterwards, on stderr.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_disp="$(basename "${here}")"

_GN=$'\033[32m'; _BL=$'\033[36m'; _CL=$'\033[m'
debug() { [ "${TAPPAAS_DEBUG:-0}" = "1" ] && echo -e "${_BL}[Debug]${_CL} $*" || true; }

rc=0; _first=1; _fails=""
printf '%b[Info]%b   Updating %s/ components: ' "${_GN}" "${_CL}" "${_disp}"
for d in "${here}"/*/; do
    name="$(basename "${d}")"
    [ "${name}" = TEMPLATE ] && continue
    [ -x "${d}update.sh" ] || continue
    if out="$("${d}update.sh" "$@" 2>&1)"; then
        if [ -n "${out}" ]; then while IFS= read -r _l; do debug "  ${_l}"; done <<<"${out}"; fi
    else
        crc=$?; rc=$crc
        _fails="${_fails}
[${_disp}/${name}] update failed (rc=${crc}):
${out}"
    fi
    if [ "${_first}" -eq 1 ]; then printf '%s' "${name}"; _first=0; else printf ', %s' "${name}"; fi
done
printf '\n'
if [ -n "${_fails}" ]; then printf '%s\n' "${_fails}" >&2; fi
exit "${rc}"
