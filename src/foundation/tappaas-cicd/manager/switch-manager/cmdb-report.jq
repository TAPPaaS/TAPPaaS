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
# between two switches' ports (recorded, MLAG peer links, LLDP). Each cable to
# a port another reporter owns (a node's NIC on its server asset) is a report
# of its own: the controller refuses a report whose reference it cannot
# resolve, and one such port must not take the switches with it.
#
# The asset is named by its tag in positions.json (the asset whose role is the
# switch), else by the switch's name; its vendor and serial, which key it, are
# the record's where it has them. A port's kind and speed are the actual's
# where the controller says, else the asset record's, else rj45 and 1g. MACs
# seen behind a port stay in the actual (the CMDB resolves no MAC yet, D5).

def natkey: tostring | [scan("[0-9]+|[^0-9]+") | (tonumber? // .)];
def canon: ascii_downcase | gsub("[^a-z0-9]"; "");
def nonull: with_entries(select(.value != null and .value != ""));
def speedword:
    if . == null then null
    elif type == "number" then ({"1000": "1g", "2500": "2.5g", "10000": "10g", "25000": "25g"}[tostring] // null)
    else (tostring | ascii_downcase | gsub("\\s"; "") | sub("(gbps|gbit|gb)$"; "g")) end;
def speeds($kind): {rj45: ["1g", "2.5g", "10g"], sfp: ["1g", "10g", "25g"]}[$kind] // [];
def assetclass: {server: "server", switch: "network-device", "access-point": "network-device",
                 modem: "appliance", ont: "appliance", ups: "appliance",
                 "patch-panel": "passive-device", pdu: "passive-device"}[.] // "other-device";

($pos.assets // {}) as $assets
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
                        controller: $s.controller, description: $s.description} | nonull)
                      + {desired: {file: "switch-configuration-desired.json", key: $sw}})},
        {ref: "asset:\($tag)", class: "network-device", name: $tag,
         attributes: ({vendor: ($rec.value.vendor // $s.vendor), model: ($rec.value.model // $s.model),
                       serial: ($rec.value.serial // $s.serial), controller: $s.controller,
                       deviceType: "switch", ports: (($s.ports // {}) | length)} | nonull)},
        ( ($s.ports // {}) | to_entries | sort_by(.key | natkey)[]
          | .key as $p | .value as $v
          | ([ ($rec.value.ports // [])[] | select(.name == $p) ][0] // {}) as $rp
          | (if (["rj45", "sfp", "wifi", "usb-a", "usb-c"] | index($v.kind // "")) then $v.kind
             elif (($v.media // "") | test("sfp"; "i")) then "sfp"
             else ($rp.kind // "rj45") end) as $kind
          | ([($v.maxSpeed // $v.speedMax | speedword), ($rp.speed // null), "1g"]
             | map(select(. != null and (speeds($kind) | index(.)))) | .[0]) as $speed
          | {ref: pref($sw; $p), class: "port", name: $p,
             attributes: ({asset: {ref: "asset:\($tag)"}, kind: $kind, speed: $speed,
                           module: (if $kind == "sfp" then ($v.module // $rp.module) else null end),
                           mac: (($v.mac // "") | ascii_downcase)} | nonull)} )
    ] as $owned
  | ($owned | map(.ref)) as $refs
  | def have($r): ($refs | index($r)) != null;
    def linkspeed($v): ($v.linkSpeed // $v.speed | speedword);

  # Cables between two ports of this report: recorded, MLAG peer links, LLDP.
  [ $names[] as $sw | ($sws[$sw].ports // {}) | to_entries[] | .key as $p | .value as $v
    | ( (select(($v.type // "") == "switch" and ($v.target // "") != "" and ($v.targetPort // "") != "" and ($sws[$v.target] != null))
         | {to: pref($v.target; $v.targetPort | tostring), origin: "recorded"}),
        ( ($v.neighbors // [])[] | select(.lldp.name != null and .lldp.port != null)
          | .lldp as $l | ($sws | keys[] | select(canon == ($l.name | canon))) as $t
          | {to: pref($t; $l.port | tostring), origin: "lldp"} ) )
    | {type: "connects", from: pref($sw; $p), to: .to,
       attributes: ({origin: .origin, linkSpeed: linkspeed($v)} | nonull)} ]
  + [ (.mlagPairs // {})[] | select((.switches | length) == 2)
      | .switches as [$a, $b]
      | {type: "connects", from: pref($a; .peerPort[$a]), to: pref($b; .peerPort[$b]), attributes: {origin: "mlag-peer"}} ]
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
      | {from: pref($sw; $p), sw: $sw, p: $p, srv: $srv.key, nic: .nic, origin: .origin, speed: linkspeed($v)} ]
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
          relations: [ {type: "connects", from: .from, to: "nic", attributes: ({origin: .origin, linkSpeed: .speed} | nonull)} ] } ]
