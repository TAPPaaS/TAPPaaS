#!/usr/bin/env bash
#
# satellite check-config — what a satellite's config may not say.
#
# module-manager runs a module's check-config.sh on the config it is about to
# install (`module add`) or write (`module modify --set`), before anything is
# provisioned or written, and refuses the change when it exits non-zero; what it
# prints is the reason. install, update and test.sh run the same check on the
# deployed config.
#
# sshPort (ADR-010 §4.4.2) puts the mothership's sshd on the internet through
# the satellite, so it is only accepted with an allow-list: sshAllow, a
# non-empty list of IPv4 addresses or networks. Also refused: a port the
# satellite already uses, and sshPort on a locked-down satellite.
#
# Usage: check-config.sh <config.json>
set -euo pipefail

cfg="${1:?usage: check-config.sh <config.json>}"
jq empty "${cfg}" 2>/dev/null || { echo "satellite: cannot read the config ${cfg}" >&2; exit 2; }
# shellcheck source=lib/provision.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/provision.sh"
sat_check_ssh_config "${cfg}"
