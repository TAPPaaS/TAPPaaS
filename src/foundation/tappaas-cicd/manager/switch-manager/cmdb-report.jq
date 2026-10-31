# cmdb-report.jq — switch-manager's reports to the CMDB (ADR-040 D4), from
# switch-configuration-actual.json (the input) and positions.json ($pos).
#
#   jq --argjson pos <positions.json or {}> --arg only <switch or ""> \
#      --argjson ended '[<switch>…]' --arg source switch-manager \
#      --arg kind observation|change --arg verb V --arg job J --arg actor A \
#      -f cmdb-report.jq switch-configuration-actual.json
#
# Prints an array of reports. The first holds what switch-manager owns: each
# switch as a `device` CI and its `network-device` asset (allocated-to the
# device), the asset's ports with their D9 kind and speed, and the cables
# between two switches' ports (recorded, MLAG peer links, LLDP). A cable in a
# redundancy (ADR-041 D3) carries `redundancyGroup`: an MLAG pair's peer links
# `<pair>:peer`, the legs of an MLAG LAG `<pair>:<lag>`. Each cable to
# a port another reporter owns (a node's NIC on its server asset) is a report
# of its own: the controller refuses a report whose reference it cannot
# resolve, and one such port must not take the switches with it.
#
# The asset is named by its tag in positions.json (the asset whose role is the
# switch), else by the switch's name; its vendor and serial, which key it, are
# the record's where it has them. A port's kind and speed are the actual's
# where the controller says, else the asset record's, else rj45 and 1g. MACs
# seen behind a port stay in the actual (the CMDB resolves no MAC yet, D5).
#
# With --slurpfile rows <list-ports --json> and --slurpfile lags <lag list --json>
# (the `report` verb; ADR-040 step 4) each port carries `assignment`, the row
# list-ports prints with the switch it is on and the actual's MLAG facts, and
# each switch its `lags`: what network-manager topology reads. A switch that
# names a location is `at` it, in a report of its own.
#
# With --argjson discover true and --argjson zones <zones.json> (report
# --discover, D15) one more report follows, the depth only a sweep reads: every
# port, used or not, with its link, negotiated speed, PoE, VLANs, STP state and
# what is seen behind it; every VLAN the switch has, declared in zones.json or
# not; the switch's address, firmware and uptime. What the controller does not
# report (switch/1's optional fields) is left out.

def natkey: tostring | [scan("[0-9]+|[^0-9]+") | (tonumber? // .)];
def canon: ascii_downcase | gsub("[^a-z0-9]"; "");
def nonull: with_entries(select(.value != null and .value != ""));
def speedword:
    if . == null then null
    elif type == "number" then ({"100": "100m", "1000": "1g", "2500": "2.5g", "10000": "10g", "25000": "25g"}[tostring] // null)
    else (tostring | ascii_downcase | gsub("\\s"; "") | sub("(gbps|gbit|gb)$"; "g")) end;
def speeds($kind): {rj45: ["1g", "2.5g", "10g"], sfp: ["1g", "10g", "25g"]}[$kind] // [];
def assetclass: {server: "server", switch: "network-device", "access-point": "network-device",
                 modem: "appliance", ont: "appliance", ups: "appliance",
                 "patch-panel": "passive-device", pdu: "passive-device"}[.] // "other-device";

($pos.assets // {}) as $assets
| (.controllers // {}) as $controllers
| (.mlagPairs // {}) as $pairs
| (($ARGS.named.rows // [[]])[0] | map({key: .switch, value: (.ports | map({key: .port, value: .}) | from_entries)}) | from_entries) as $rows
| (($ARGS.named.lags // [[]])[0]) as $lagRows
| def record($role; $kinds):
    [ $assets | to_entries[]
      | select(.value.role == $role and ((.value.kind // "") as $k | $kinds | index($k)) and (.value.stage // "") != "disposed") ][0];
  def tag($sw): (record($sw; ["switch"]) // {key: $sw}).key;
  def pref($sw; $p): "port:\(tag($sw))/\($p)";

  (.switches // {}) as $sws
  | ($sws | keys | map(select($only == "" or . == $only))) as $names

  # ── what switch-manager owns ──
  | [ $names[] as $sw | $sws[$sw] as $s
      | record($sw; ["switch"]) as $rec
      | tag($sw) as $tag
      | {ref: "device:\($sw)", class: "device", name: $sw,
         attributes: (({model: $s.model, firmware: $s.firmware, managementAddress: $s.managementIp,
                        controller: $s.controller, description: $s.description,
                        vendor: $s.vendor, managed: $s.managed, order: ($sws | keys_unsorted | index($sw)),
                        controllerAddress: $controllers[$s.controller // ""].managementIp,
                        mlag: (($pairs | to_entries | map(select(.value.switches | index($sw)))[0]) as $pair
                               | if $s.mlag or $pair then ($s.mlag // {}) + (if $pair then {pair: ({name: $pair.key} + $pair.value)} else {} end) else null end),
                        lags: (if $ARGS.named.lags then [$lagRows[] | select(.switch == $sw)] else null end)} | nonull)
                      + {deviceType: "switch", desired: {file: "switch-configuration-desired.json", key: $sw}})},
        {ref: "asset:\($tag)", class: "network-device", name: $tag,
         attributes: ({vendor: ($rec.value.vendor // $s.vendor), model: ($rec.value.model // $s.model),
                       serial: ($rec.value.serial // $s.serial), controller: $s.controller,
                       deviceType: "switch", ports: (($s.ports // {}) | length)} | nonull)},
        ( ($s.ports // {}) | to_entries | sort_by(.key | natkey)[]
          | .key as $p | .value as $v
          | ([ ($rec.value.ports // [])[] | select(.name == $p) ][0] // {}) as $rp
          | (if (["rj45", "sfp", "wifi", "usb-a", "usb-c"] | index($v.kind // "")) then $v.kind
             elif (($v.media // "") + " " + $p | test("sfp"; "i")) then "sfp"
             else ($rp.kind // "rj45") end) as $kind
          | ([($v.maxSpeed // $v.speedMax | speedword), ($rp.speed // null)]
             | map(select(. != null and (speeds($kind) | index(.)))) | .[0]) as $speed
          | {ref: pref($sw; $p), class: "port", name: $p,
             attributes: ({asset: {ref: "asset:\($tag)"}, kind: $kind, speed: $speed,
                           module: (if $kind == "sfp" then ($v.module // $rp.module) else null end),
                           mac: (($v.mac // "") | ascii_downcase),
                           assignment: ($rows[$sw][$p] as $row
                             | if $row then ($row | del(.port))
                                 + {switch: $sw, actual: ($v | {lag, mlagId, liveMlagId, peerLink, bridged, disabled, bond} | nonull)}
                               else null end)} | nonull)} )
    ] as $owned
  | ($owned | map(.ref)) as $refs
  | def have($r): ($refs | index($r)) != null;
    def linkspeed($v): ($v.linkSpeed // $v.speed | speedword);
    # Redundancy (ADR-041 D3): the MLAG pair a switch is in, and the group a
    # cable from its port is in — the pair's peer links, or the two legs of an
    # MLAG LAG (a lag with an mlagId); else none.
    def pairof($sw): [ $pairs | to_entries[] | select(.value.switches | index($sw)) | .key ][0];
    def peerport($sw; $p): pairof($sw) as $pr
      | $pr != null and ((($pairs[$pr].peerPort // {})[$sw] // null) == $p or (($sws[$sw].ports // {})[$p].peerLink // false) == true);
    def lagleg($sw; $p): (($sws[$sw].ports // {})[$p] // {}) as $v | pairof($sw) as $pr
      | if $pr != null and ($v.mlagId // null) != null and ($v.lag // "") != "" then "\($pr):\($v.lag)" else null end;
    def group($a; $p; $b; $q):
      if pairof($a) != null and pairof($a) == pairof($b) and $a != $b and (peerport($a; $p) or peerport($b; $q))
      then "\(pairof($a)):peer" else (lagleg($a; $p) // lagleg($b; $q)) end;

  # Cables between two ports of this report: recorded, MLAG peer links, LLDP.
  [ $names[] as $sw | ($sws[$sw].ports // {}) | to_entries[] | .key as $p | .value as $v
    | ( (select(($v.type // "") == "switch" and ($v.target // "") != "" and ($v.targetPort // "") != "" and ($sws[$v.target] != null))
         | {sw: $v.target, port: ($v.targetPort | tostring), origin: "recorded"}),
        ( ($v.neighbors // [])[] | select(.lldp.name != null and .lldp.port != null)
          | .lldp as $l | ($sws | keys[] | select(canon == ($l.name | canon))) as $t
          | {sw: $t, port: ($l.port | tostring), origin: "lldp"} ) )
    | {type: "connects", from: pref($sw; $p), to: pref(.sw; .port),
       attributes: ({origin: .origin, linkSpeed: linkspeed($v), redundancyGroup: group($sw; $p; .sw; .port)} | nonull)} ]
  + [ $pairs | to_entries[] | select((.value.switches | length) == 2)
      | .key as $pr | .value.switches as [$a, $b] | .value.peerPort as $pp
      | {type: "connects", from: pref($a; $pp[$a]), to: pref($b; $pp[$b]), attributes: {origin: "mlag-peer", redundancyGroup: "\($pr):peer"}} ]
  | map(select(have(.from) and have(.to)))
  # A cable is one relation, whichever end reported it.
  | map(if .from > .to then .from as $f | .from = .to | .to = $f else . end)
  | unique_by([.from, .to]) as $cables
  | [ $names[] | {type: "allocated-to", from: "asset:\(tag(.))", to: "device:\(.)"} ] as $alloc

  # A node's NIC: the port on its server asset, by the record's tag.
  | [ $names[] as $sw | ($sws[$sw].ports // {}) | to_entries[] | .key as $p | .value as $v
      | ( (select(($v.type // "") == "node" and ($v.target // "") != "" and ($v.targetPort // "") != "")
           | {node: $v.target, nic: ($v.targetPort | tostring), origin: "recorded"}),
          ( ($v.neighbors // [])[] | select(.lldp.name != null and .lldp.port != null and ($sws[.lldp.name] == null))
            | {node: .lldp.name, nic: (.lldp.port | tostring), origin: "lldp"} ) )
      | record(.node; ["server"]) as $srv
      | select($srv != null)
      | {from: pref($sw; $p), sw: $sw, p: $p, srv: $srv.key, nic: .nic, origin: .origin, speed: linkspeed($v), group: lagleg($sw; $p)} ]
  | unique_by([.from, .srv, .nic]) as $nics

  | def head: {source: $source, kind: $kind}
      + (if $kind == "change" then ({verb: $verb, job: $job, actor: $actor} | nonull) else {} end);

  [ head + {objects: ($owned + [ $ended[] | {class: "device", name: ., end: true} ]), relations: ($alloc + $cables)} ]
  + [ $nics[]
      | head + {
          objects: [
            {ref: "asset:\(tag(.sw))", class: "network-device", name: tag(.sw)},
            {ref: .from, class: "port", name: .p, attributes: {asset: {ref: "asset:\(tag(.sw))"}}},
            {ref: "nic", class: "port", name: .nic, attributes: {asset: {class: "server", name: .srv}}} ],
          relations: [ {type: "connects", from: .from, to: "nic", attributes: ({origin: .origin, linkSpeed: .speed, redundancyGroup: .group} | nonull)} ] } ]
  + [ $names[] as $sw | select(($sws[$sw].location // "") != "")
      | head + {
          objects: [ {ref: "loc", class: "location", name: $sws[$sw].location}, {ref: "device:\($sw)", class: "device", name: $sw} ],
          relations: [ {type: "at", from: "device:\($sw)", to: "loc"} ] } ]
  + (if ($ARGS.named.discover // false) then
      ([ ($ARGS.named.zones // {}) | to_entries[] | .value | objects | .vlantag | numbers | select(. > 0) ]) as $declared
      | [ head + {
          objects: [ $names[] as $sw | $sws[$sw] as $s | tag($sw) as $tag
            | ([ (($s.vlans // [])[] | if type == "object" then {tag: (.id // .tag), name: .name} else {tag: .} end),
                 (($s.ports // {})[] | ((.nativeVlan // 0), (.taggedVlans // [])[]) | {tag: .}) ]
               | map(select((.tag // 0) > 0)) | group_by(.tag)
               | map({tag: .[0].tag, name: (map(.name // empty) | first // null), declared: ((.[0].tag) as $t | ($declared | index($t)) != null)} | nonull)) as $vlans
            | {class: "device", name: $sw,
               attributes: (({managementAddress: $s.managementIp, firmware: $s.firmware, uptime: $s.uptime} | nonull) + {vlans: $vlans})},
              {ref: "asset:\($tag)", class: "network-device", name: $tag},
              ( ($s.ports // {}) | to_entries | sort_by(.key | natkey)[]
                | .key as $p | .value as $v
                | {class: "port", name: $p,
                   attributes: (({asset: {ref: "asset:\($tag)"}, link: $v.link, linkSpeed: linkspeed($v), poe: $v.poe, stp: $v.stp} | nonull)
                     + {vlans: ({mode: $v.mode, native: $v.nativeVlan, tagged: $v.taggedVlans} | nonull),
                        seen: [ ($v.neighbors // [])[] | {mac: (.mac | ascii_downcase), lldp: .lldp, lease: .lease} | nonull ]})} ) ],
          relations: [] } ]
    else [] end)
