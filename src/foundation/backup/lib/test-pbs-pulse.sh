#!/usr/bin/env bash
# test-pbs-pulse.sh — the pulse's installer (ADR-031): where the backup node is
# reached, and the pulse.json it is given — buddies we pull from the PBS's own
# remotes, buddies that pull us from the remote peers, contacts from the peers.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $1 (got '$2', want '$3')"; fi; }
info() { :; }; warn() { :; }
# shellcheck source=pbs-pulse.sh
. "${HERE}/pbs-pulse.sh"

export PBS_CONFIG_DIR="${T}"
cat > "${T}/site.json" <<'EOF'
{ "name": "home", "email": "me@home.example", "hardware": { "nodes": [ { "name": "tappaas3" } ] } }
EOF
echo '{"kind":"machine","moduleSource":"/x/pvehost"}' > "${T}/tappaas3.json"
echo '{"kind":"machine","address":"10.0.0.50","moduleSource":"/x/debianhost"}' > "${T}/nas1.json"
echo '{"name":"lars","type":"tappaas","remoteHost":"10.255.2.1","contact":"l@buddy.example"}' > "${T}/pull-lars.json"
echo '{"name":"quiet","type":"tappaas","remoteHost":"10.255.2.5"}' > "${T}/pull-quiet.json"
echo '{"name":"rasmus","type":"remote","authId":"rasmus@pbs"}' > "${T}/remote-rasmus.json"
echo '{"name":"noauth","type":"remote","authId":""}' > "${T}/remote-noauth.json"

ck "a cluster node is reached by its mgmt name, though it is a machine module" "$(pulse_host_addr tappaas3)" "tappaas3.mgmt.internal"
ck "a debianhost machine by its address" "$(pulse_host_addr nas1)" "10.0.0.50"
ck "an address as it is" "$(pulse_host_addr 10.0.0.9.example)" "10.0.0.9.example"

# The PBS's remotes: lars and quiet are pull peers; "other" is a remote nobody declared a pull for.
stub() { [[ "$2" == proxmox-backup-manager* ]] && echo '[
  {"name":"lars","host":"10.255.2.1","port":8007,"fingerprint":"AA:BB"},
  {"name":"quiet","host":"10.255.2.5"},
  {"name":"other","host":"192.0.2.1"} ]'; }
# shellcheck disable=SC2034  # read by the sourced lib
PULSE_NODE_SSH=stub
J="$(pulse_config_json tappaas3)"
ck "the site and its operator" "$(jq -r '.site + " " + .email' <<< "${J}")" "home me@home.example"
ck "buddies: the pull peers among the PBS's remotes" "$(jq -r '[.buddies[].name] | join(",")' <<< "${J}")" "lars,quiet"
ck "…with the fingerprint and the contact" "$(jq -r '.buddies[0] | .fingerprint + " " + .contact' <<< "${J}")" "AA:BB l@buddy.example"
ck "…and port 8007 when the remote has none" "$(jq -r '.buddies[1].port' <<< "${J}")" "8007"
ck "pulledBy: the remote peers with a login" "$(jq -r '[.pulledBy[].name] | join(",")' <<< "${J}")" "rasmus"
ck "a remote peer without a contact has none" "$(jq -r '.pulledBy[0].contact // "none"' <<< "${J}")" "none"
stub() { return 1; }
J="$(pulse_config_json tappaas3)"
ck "a PBS that does not answer: no buddies, the rest stays" "$(jq -r '(.buddies | length | tostring) + " " + ([.pulledBy[].name] | join(","))' <<< "${J}")" "0 rasmus"

echo "Results: ${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]]
