#!/usr/bin/env bash
#
# build-facts.sh — the Nextcloud major this guest runs, for the build that picks
# its next major (#797). Runs ON the guest as root; update-os.sh feeds it over ssh
# (`sudo bash -s`) and writes the output to /etc/nixos/tappaas-build-facts.env,
# which nc-major.nix reads. The build happens on the mothership (#774), where
# config.php does not exist — and it holds the instance's secrets, so only the
# major leaves the guest.
#
#   NEXTCLOUD_INSTALLED_MAJOR   the major from config.php's 'version',
#                               none    — no config.php and no data: a fresh install,
#                               unknown — an instance whose version cannot be read.
#
# FACTS_ROOT prefixes every path (tests).
set -uo pipefail
R="${FACTS_ROOT:-}"
home="${R}/var/lib/nextcloud"
cfg="${home}/config/config.php"

major=""
[[ -r "${cfg}" ]] && major="$(sed -nE "s/^[[:space:]]*'version'[[:space:]]*=>[[:space:]]*'([0-9]+)\..*/\1/p" "${cfg}" | head -n1)"
if [[ -n "${major}" ]]; then
    :
elif [[ -e "${cfg}" || -n "$(ls -A "${home}/data" 2>/dev/null)" ]]; then
    major="unknown"
else
    major="none"
fi
echo "NEXTCLOUD_INSTALLED_MAJOR=${major}"
