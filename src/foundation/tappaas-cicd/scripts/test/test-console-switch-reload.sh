#!/usr/bin/env bash
# test-console-switch-reload.sh — a NixOS switch that changes tappaas-console
# does not restart it: the switch is often run from a console job (`module
# update tappaas-cicd`), and the restart cut that job off (lab2 2026-11-03).
# The unit is reloaded instead; the reload leaves the marker the console takes
# when its runner is idle (ui/src/jobs.ts RESTART_MARKER). Static: reads files.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
NIX="${CICD}/tappaas-cicd.nix"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
has() { if grep -qE "$2" <<<"${blk}"; then ck "$1" ok ok; else ck "$1" ok missing; fi; }

blk="$(sed -n '/systemd.services.tappaas-console = {/,/^  };/p' "${NIX}")"
has "the console unit is reloaded, not restarted, when a switch changes it" 'reloadIfChanged = true;'
if grep -qE 'restartIfChanged = false' <<<"${blk}"; then ck "…and not skipped (restartIfChanged = false would leave no marker)" ok present
else ck "…and not skipped (restartIfChanged = false would leave no marker)" ok ok; fi
has "an exit after the reload brings it back (Restart=always)" 'Restart = "always";'

state="$(grep -oE 'StateDirectory = "[^"]+"' <<<"${blk}" | sed -E 's/.*"(.*)"/\1/')"
marker="$(grep -oE 'RESTART_MARKER = "[^"]+"' "${CICD}/ui/src/jobs.ts" | sed -E 's/.*"(.*)"/\1/')"
reload="$(grep -oE 'ExecReload = "[^"]+"' <<<"${blk}" | sed -E 's/.*touch ([^"]+)"/\1/')"
ck "the reload touches the marker the console takes" "/var/lib/${state}/${marker}" "${reload}"

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
