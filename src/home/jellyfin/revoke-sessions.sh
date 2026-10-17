#!/usr/bin/env bash
# TAPPaaS Module: jellyfin — end a person's Jellyfin sessions
#
# Removing someone in Authentik stops their next sign-in, but Jellyfin keeps
# honouring the tokens it already gave their apps and TVs. identity-manager runs
# this after a reconcile takes access from a user (deleted, disabled, or out of
# a group): it deletes every device of the Jellyfin account of that name, which
# ends those sessions. Signing in again — if they still may — makes new ones.
#
# Runs on tappaas-cicd from the module directory, as the tappaas user. Uses the
# VM's TAPPaaS API key (jellyfin-tappaas-policy). A person with no Jellyfin
# account is not an error.
#
# Usage: ./revoke-sessions.sh <username>

set -euo pipefail

WHO="${1:?usage: revoke-sessions.sh <username>}"
. /home/tappaas/bin/common-install-routines.sh jellyfin 2>/dev/null || true
VMNAME="$(get_config_value 'vmname' 'jellyfin' 2>/dev/null || echo jellyfin)"
ZONE0="$(get_config_value 'zone0' 'srvHome' 2>/dev/null || echo srvHome)"

ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes \
    "tappaas@${VMNAME}.${ZONE0}.internal" "sudo bash -s -- $(printf '%q' "${WHO}")" <<'EOF'
set -euo pipefail
who="$1"
key="$(cat /var/lib/jellyfin-tappaas/api-key 2>/dev/null)" || { echo "no TAPPaaS API key on the VM (jellyfin-tappaas-policy has not run)" >&2; exit 1; }
api=http://localhost:8096
auth="Authorization: MediaBrowser Token=\"${key}\""
# User names are case-insensitive in Jellyfin 12.
id="$(curl -sf -H "${auth}" "${api}/Users" | jq -r --arg n "${who}" '.[] | select((.Name | ascii_downcase) == ($n | ascii_downcase)) | .Id')"
if [[ -z "${id}" ]]; then
    echo "jellyfin: no account '${who}' — nothing to end"
    exit 0
fi
n=0
for dev in $(curl -sf -H "${auth}" "${api}/Devices?userId=${id}" | jq -r '.Items[].Id'); do
    curl -sf -X DELETE -H "${auth}" "${api}/Devices?id=$(jq -rn --arg d "${dev}" '$d | @uri')" >/dev/null
    n=$((n + 1))
done
echo "jellyfin: ended ${n} session(s) of '${who}'"
EOF
