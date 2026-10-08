#!/usr/bin/env bash
#
# Unit tests for pbs-tunnel.sh (#796) and the named-instance helpers it adds to
# tappaas-cicd/lib/opnsense-wg.sh. OPNsense is a stateful fake behind _ow_api
# (JSON files; get* returns select-objects like the real API), the controller
# CLIs are stubs that log their argv, and key generation is stubbed — nothing
# here touches a firewall.
#
# Usage: ./test-pbs-tunnel.sh   (exit 0 = all passed)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT

export BT_PBS_IP="10.0.0.20" BT_BIN_DIR="${T}/bin" OPNSENSE_HOST="fw.test" OPNSENSE_PORT="8443"
# shellcheck source=pbs-tunnel.sh disable=SC1091
. "${SCRIPT_DIR}/pbs-tunnel.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (exp '$2' got '$3')"; FAIL=$((FAIL+1)); fi; }
has() { if grep -qF -- "$2" "$3"; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 ('$2' not in $(basename "$3"))"; FAIL=$((FAIL+1)); fi; }

# ── fakes ────────────────────────────────────────────────────────────
mkdir -p "${T}/bin"
for c in opnsense-firewall nat-manager snat-manager; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/cli.log"\n' "${c}" "${T}" > "${T}/bin/${c}"
    chmod +x "${T}/bin/${c}"
done
echo '{}' > "${T}/server.json"; echo '{}' > "${T}/client.json"; : > "${T}/api.log"; : > "${T}/cli.log"
# Counters live in files: the lib calls these inside $(…) subshells.
echo 0 > "${T}/n"
_next() { local n; n=$(( $(cat "${T}/n") + 1 )); echo "${n}" > "${T}/n"; echo "${n}"; }
echo 0 > "${T}/k"
ow_genkey() { local n; n=$(( $(cat "${T}/k") + 1 )); echo "${n}" > "${T}/k"; printf 'PRIV%s PUB%s' "${n}" "${n}"; }
_sel() {  # flat "a,b" -> select-object over the known uuids of <kind>
    jq -c --arg v "$1" '[to_entries[] | .key as $k | {key, value: {value: .value.name, selected: (if ($v|split(",")|index($k)) then 1 else 0 end)}}] | from_entries' "${T}/$2.json"
}
_ow_api() {
    local path="${!#}" body="" a; local -a args=("${@:1:$#-1}")
    for ((a = 0; a < ${#args[@]}; a++)); do [[ "${args[a]}" == "-d" ]] && body="${args[a+1]}"; done
    echo "${path} ${body}" >> "${T}/api.log"
    local kind="${path#/api/wireguard/}" verb uuid f; kind="${kind%%/*}"
    verb="${path##*/wireguard/"${kind}"/}"; uuid="${verb#*/}"; verb="${verb%%/*}"
    f="${T}/${kind}.json"
    case "${verb}" in
        searchServer|searchClient)
            jq -c '{rows: [to_entries[] | .value + {uuid: .key}]}' "${f}" ;;
        addServer|addClient)
            uuid="u$(_next)"
            jq --arg u "${uuid}" --argjson b "${body}" '.[$u] = ($b | to_entries[0].value)' "${f}" > "${f}.n" && mv "${f}.n" "${f}"
            echo "{\"result\":\"saved\",\"uuid\":\"${uuid}\"}" ;;
        setServer|setClient)
            jq --arg u "${uuid}" --argjson b "${body}" '.[$u] = ($b | to_entries[0].value)' "${f}" > "${f}.n" && mv "${f}.n" "${f}"
            echo '{"result":"saved"}' ;;
        getServer)
            jq -c --arg u "${uuid}" --argjson p "$(_sel "$(jq -r --arg u "${uuid}" '.[$u].peers // ""' "${f}")" client)" \
                '{server: (.[$u] + {peers: $p, instance: "7"})}' "${f}" ;;
        getClient)
            jq -c --arg u "${uuid}" --argjson s "$(_sel "$(jq -r --arg u "${uuid}" '.[$u].servers // ""' "${f}")" server)" \
                '{client: (.[$u] + {servers: $s})}' "${f}" ;;
        delServer|delClient)
            jq --arg u "${uuid}" 'del(.[$u])' "${f}" > "${f}.n" && mv "${f}.n" "${f}"; echo '{"result":"deleted"}' ;;
        show)
            jq -c '{rows: [to_entries[] | {type: "peer", "public-key": .value.pubkey, "peer-status": "online", "latest-handshake-age": "12"}]}' "${T}/client.json" ;;
        *) echo '{"result":"ok"}' ;;
    esac
}

# ── /30 arithmetic ───────────────────────────────────────────────────
ck "hosts of a /30"            "10.255.2.5 10.255.2.6" "$(bt_hosts 10.255.2.4/30)"
bt_hosts 10.255.2.5/30 >/dev/null 2>&1; ck "misaligned /30 refused" 1 $?
bt_hosts 10.255.2.0/24 >/dev/null 2>&1; ck "a /24 refused"          1 $?

# ── serve without the puller's key yet ───────────────────────────────
pub="$(bt_serve_up anna 10.255.2.0/30 51830 1340)"
ck "serve echoes our public key" "PUB1" "${pub}"
srv="$(jq -r 'to_entries[0].key' "${T}/server.json")"
ck "instance named buddy-anna-serve" "buddy-anna-serve" "$(jq -r '.[].name' "${T}/server.json")"
ck "…listens on the given port"      "51830" "$(jq -r '.[].port' "${T}/server.json")"
ck "…holds .1/30"                    "10.255.2.1/30" "$(jq -r '.[].tunneladdress' "${T}/server.json")"
ck "…with the MTU"                   "1340" "$(jq -r '.[].mtu' "${T}/server.json")"
ck "no peer without a key"           "0" "$(jq 'length' "${T}/client.json")"
has "WAN rule opens the udp port"     "--description buddy-anna serve wg --interface wan --action pass --protocol udp --log --source any --destination wanip --destination-port 51830" "${T}/cli.log"
has "port-forward only from .2 to .1:8007 -> our PBS" "--interface wireguard --protocol tcp --source 10.255.2.2/32 --destination 10.255.2.1 --external-port 8007 --target 10.0.0.20 --internal-port 8007" "${T}/cli.log"
has "CLIs pinned to the REST port (#418)" "--firewall fw.test --port 8443 --no-ssl-verify" "${T}/cli.log"

# ── re-run with the key: same instance, same key, peer linked ────────
pub="$(bt_serve_up anna 10.255.2.0/30 51830 1340 PUBX)"
ck "re-run keeps our key"              "PUB1" "${pub}"
ck "…and the one instance"             "1" "$(jq 'length' "${T}/server.json")"
ck "peer admits only .2/32"            "10.255.2.2/32" "$(jq -r '.[].tunneladdress' "${T}/client.json")"
ck "peer has no endpoint (they dial)"  "" "$(jq -r '.[].serveraddress' "${T}/client.json")"
cli="$(jq -r 'to_entries[0].key' "${T}/client.json")"
ck "server's peer list is that peer"   "${cli}" "$(jq -r --arg s "${srv}" '.[$s].peers' "${T}/server.json")"
ck "…and its port survived the update" "51830" "$(jq -r --arg s "${srv}" '.[$s].port' "${T}/server.json")"
ck "…its private key too"              "PRIV1" "$(jq -r --arg s "${srv}" '.[$s].privkey' "${T}/server.json")"
ck "update sends no read-only field"   "" "$(jq -r --arg s "${srv}" '.[$s].instance // ""' "${T}/server.json")"
ck "status: handshake"                 "buddy-anna-serve pubkey=PUB1 peer=online hs=12" "$(bt_status serve anna)"

# ── dial ─────────────────────────────────────────────────────────────
: > "${T}/cli.log"
pub="$(bt_dial_up bo 10.255.2.4/30 203.0.113.7:51831 PUBY 1340)"
ck "dial echoes our public key" "PUB2" "${pub}"
ck "dial instance holds .2/30"  "10.255.2.6/30" "$(jq -r '.[] | select(.name=="buddy-bo-pull") | .tunneladdress' "${T}/server.json")"
ck "…peer AllowedIPs .1/32"     "10.255.2.5/32" "$(jq -r '.[] | select(.name=="buddy-bo-pull-peer") | .tunneladdress' "${T}/client.json")"
ck "…endpoint host"             "203.0.113.7"   "$(jq -r '.[] | select(.name=="buddy-bo-pull-peer") | .serveraddress' "${T}/client.json")"
ck "…endpoint port"             "51831"         "$(jq -r '.[] | select(.name=="buddy-bo-pull-peer") | .serverport' "${T}/client.json")"
ck "…keepalive"                 "25"            "$(jq -r '.[] | select(.name=="buddy-bo-pull-peer") | .keepalive' "${T}/client.json")"
has "out-NAT our PBS to .2 toward .1" "snat-manager add-rule --firewall fw.test --port 8443 --no-ssl-verify --description buddy-bo pull nat --interface wireguard --source 10.0.0.20/32 --destination 10.255.2.5/32 --target 10.255.2.6" "${T}/cli.log"
has "pass our PBS -> .1 tcp/8007 only" "--interface lan --action pass --protocol tcp --no-log --source 10.0.0.20 --destination 10.255.2.5 --destination-port 8007" "${T}/cli.log"
bt_dial_up bo 10.255.2.4/30 203.0.113.7 PUBY "" >/dev/null 2>&1; ck "dial needs host:port" 1 $?
bt_dial_up bo 10.255.2.4/30 203.0.113.7:1 "" "" >/dev/null 2>&1; ck "dial needs their key" 1 $?

# ── teardown removes exactly its own ─────────────────────────────────
: > "${T}/cli.log"
bt_serve_down anna
ck "serve down: instance gone"    "" "$(jq -r '.[] | select(.name=="buddy-anna-serve") | .name' "${T}/server.json")"
ck "…its peer gone"               "" "$(jq -r '.[] | select(.name=="buddy-anna-serve-peer") | .name' "${T}/client.json")"
ck "…the dial tunnel untouched"   "buddy-bo-pull" "$(jq -r '.[].name' "${T}/server.json")"
has "…its rdr rule removed"       "nat-manager delete-rule --firewall fw.test --port 8443 --no-ssl-verify --description buddy-anna serve pbs" "${T}/cli.log"
has "…its WAN rule removed"       "opnsense-firewall delete-rule --firewall fw.test --port 8443 --no-ssl-verify --description buddy-anna serve wg" "${T}/cli.log"
bt_dial_down bo
ck "dial down: nothing left"      "0 0" "$(jq 'length' "${T}/server.json") $(jq 'length' "${T}/client.json")"
has "…its NAT removed"            "snat-manager delete-rule --firewall fw.test --port 8443 --no-ssl-verify --description buddy-bo pull nat" "${T}/cli.log"
bt_dial_down bo; ck "down is idempotent" 0 $?
bt_status dial bo >/dev/null; ck "status of an absent tunnel fails" 1 $?

# ── the dial command printed for the buddy ───────────────────────────
echo '{"name":"hrossen","location":{"country":"DK","city":"Kgs. Lyngby"}}' > "${T}/site.json"
cmd="$(bt_dial_command "${T}/site.json" tappaas_backup 10.255.2.0/30 PUBK 51830 1340)"
has "names us as their peer, with our store"   "peer add pull hrossen --store tappaas_backup" <(echo "${cmd}")
has "…our location from site.json, quoted"     "--country 'DK' --city 'Kgs. Lyngby'" <(echo "${cmd}")
has "…the /30, endpoint port to fill in"       "--tunnel-net 10.255.2.0/30 --endpoint <our public IP or satellite IP>:51830" <(echo "${cmd}")
has "…our key and the MTU"                     "--peer-key PUBK --mtu 1340" <(echo "${cmd}")
echo '{"name":"bare"}' > "${T}/site.json"
cmd="$(bt_dial_command "${T}/site.json" s 10.255.2.4/30 K 51831)"
has "no location: a placeholder, not a guess"  "--store s --country <CC> \\" <(echo "${cmd}")
ck  "no MTU: none passed"                      "0" "$(grep -c -- '--mtu' <<<"${cmd}")"

echo ""
echo "pbs-tunnel: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
