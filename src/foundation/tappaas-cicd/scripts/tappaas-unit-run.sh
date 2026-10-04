#!/usr/bin/env bash
#
# tappaas-unit-run.sh — run a command the way update-tappaas.service runs its steps (#767).
#
# Code the sweep runs has failed three times in the unit after it worked from the
# tappaas console (#713 PATH, #742 sudo under NoNewPrivileges, #719 root's HOME).
# The unit now gives each step the console's context (ADR-017 D3, amended), but
# a systemd service is still not a terminal: no TTY, no SSH agent, no SUDO_* from
# a person, started by a timer. This runs a command in exactly that context, so a
# change to sweep code is verified where it will run — not only from the console.
#
# It reads the unit's own properties (User, Environment and any sandboxing) from
# the LIVE unit, so it stays faithful if the unit changes, and runs the command
# as the unit runs its steps:
#   default   as the unit's User, through a login shell     (like tappaas-self-prepare.sh)
#   --root    the same, then `sudo -n` the command           (like tappaas-self-rebuild.sh)
#
# Usage: tappaas-unit-run.sh [--unit <name>] [--root] [--print] -- <command> [args...]
#   --print   show the systemd-run command instead of running it (tests)
# Exit: the command's own exit code; 2 for usage or a unit that cannot be read.
set -uo pipefail

UNIT="update-tappaas.service"; ROOT=0; PRINT=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --unit)  UNIT="${2:?--unit needs a name}"; shift 2 ;;
        --root)  ROOT=1; shift ;;
        --print) PRINT=1; shift ;;
        --)      shift; break ;;
        -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)       break ;;
    esac
done
[[ $# -gt 0 ]] || { echo "tappaas-unit-run: a command is required (see --help)" >&2; exit 2; }

SYSTEMCTL="${TAPPAAS_SYSTEMCTL:-systemctl}"
prop() { "${SYSTEMCTL}" show "${UNIT}" -p "$1" --value 2>/dev/null; }
user="$(prop User)"
[[ -n "${user}" ]] || { echo "tappaas-unit-run: cannot read ${UNIT} (no User=)" >&2; exit 2; }

props=(-p "User=${user}")
for kv in $(prop Environment); do props+=(-p "Environment=${kv}"); done
# Sandboxing, when the unit has it: a context the command would really meet.
[[ "$(prop NoNewPrivileges)" == "yes" ]] && props+=(-p "NoNewPrivileges=yes")
[[ "$(prop PrivateTmp)" == "yes" ]] && props+=(-p "PrivateTmp=yes")
ps="$(prop ProtectSystem)"; [[ -n "${ps}" && "${ps}" != "no" ]] && props+=(-p "ProtectSystem=${ps}")
for rw in $(prop ReadWritePaths); do props+=(-p "ReadWritePaths=${rw}"); done

cmd="$(printf '%q ' "$@")"
(( ROOT )) && cmd="/run/wrappers/bin/sudo -n ${cmd}"
run=(/run/wrappers/bin/sudo -n systemd-run --quiet --wait --pipe --collect "${props[@]}"
     -- /run/current-system/sw/bin/bash -l -c "${cmd}")

if (( PRINT )); then
    printf '%q ' "${run[@]}"; echo
    exit 0
fi
"${run[@]}" </dev/null
