# cmdb-report.jq — ap-manager's reports to the CMDB (ADR-040 D4), from
# switch-configuration-desired.json (the input: the APs and the site's SSIDs),
# switch-configuration-actual.json ($actual: what the APs answered) and
# positions.json ($pos).
#
#   jq --argjson actual <actual> --argjson pos <positions.json or {}> \
#      --arg only <ap or ""> --argjson ended '[<ap>…]' --argjson endedSsids '[<ssid>…]' \
#      --arg source ap-manager --arg kind observation|change --arg verb V --arg job J --arg actor A \
#      -f cmdb-report.jq switch-configuration-desired.json
#
# Prints an array of reports. The first holds what ap-manager owns: each AP as
# a `device` CI and its `network-device` asset (allocated-to the device), the
# asset's wired uplink port and its radio (`wifi`, D9), each SSID (security,
# zone, broadcastOn) and the radio's `connects` to every SSID the AP
# broadcasts. Each AP's cable to its switch port is a report of its own (the
# port is switch-manager's): one the CMDB does not have yet refuses only that.
#
# The asset is named by its tag in positions.json (the access point whose role
# is the AP), else by the AP's name. Its uplink and radio are the record's
# first rj45 and wifi ports where it has them, else `uplink` (rj45, 1g) and
# `wifi`. Wi-Fi clients stay in the actual: the CMDB resolves no MAC yet (D5).
#
# Each AP also carries what `ap-manager list` says of it, for network-manager
# topology (ADR-040 step 4): its vendor, uplink and SSIDs; one that names a
# location is `at` it, in a report of its own.
#
# With --argjson discover true (report --discover, D15) one more report follows:
# each AP's firmware, uptime and clients (MAC, SSID, signal), every radio as a
# `wifi` port (standard, band, channel, power), and an SSID the AP broadcasts
# that desired does not declare. What the controller does not report (ap/1's
# optional fields) is left out.

def nonull: with_entries(select(.value != null and .value != ""));
($pos.assets // {}) as $assets
| def record($role; $kind):
    [ $assets | to_entries[] | select(.value.role == $role and .value.kind == $kind and (.value.stage // "") != "disposed") ][0];
  def tag($name; $kind): (record($name; $kind) // {key: $name}).key;

  (.accessPoints // {}) as $aps
  | (.ssids // {}) as $ssids
  | ($aps | keys) as $all
  | ($all | map(select($only == "" or . == $only))) as $names
  | def head: {source: $source, kind: $kind}
      + (if $kind == "change" then ({verb: $verb, job: $job, actor: $actor} | nonull) else {} end);
    def broadcasters($s): if ($s.broadcastOn // "all") == "all" then $all else [ $s.broadcastOn[] | select(($all | index(.)) != null) ] end;

  [ $names[] as $ap
    | ($aps[$ap] // {}) as $d | (($actual.accessPoints // {})[$ap] // {}) as $a
    | record($ap; "access-point") as $rec
    | tag($ap; "access-point") as $tag
    | ([ ($rec.value.ports // [])[] | select(.kind == "rj45") ][0] // {name: "uplink", kind: "rj45", speed: "1g"}) as $up
    | ([ ($rec.value.ports // [])[] | select(.kind == "wifi") ][0] // {name: "wifi", kind: "wifi"}) as $radio
    | { objects: [
          {ref: "device:\($ap)", class: "device", name: $ap,
           attributes: (({model: ($a.model // $d.model), firmware: $a.firmware, managementAddress: ($a.managementIp // $d.managementIp),
                          controller: $a.controller, description: $d.description,
                          vendor: ($d.vendor // $a.vendor),
                          uplink: (($d.uplinkSwitch // "") as $us | if $us != "" then {switch: $us, port: ($d.uplinkPort | tostring)} else null end)} | nonull)
                        + {deviceType: "access-point", ssids: [ ($d.ssids // {}) | to_entries[] | {name: .key} + .value ],
                           desired: {file: "switch-configuration-desired.json", key: "accessPoints.\($ap)"}})},
          {ref: "asset:\($tag)", class: "network-device", name: $tag,
           attributes: ({vendor: ($rec.value.vendor // $a.vendor // $d.vendor), model: ($rec.value.model // $a.model // $d.model),
                         serial: ($rec.value.serial // $a.serial), controller: $a.controller, deviceType: "access-point"} | nonull)},
          {ref: "port:\($tag)/\($up.name)", class: "port", name: $up.name,
           attributes: ({asset: {ref: "asset:\($tag)"}, kind: "rj45", speed: (($up.speed // "1g") as $sp | if (["1g", "2.5g", "10g"] | index($sp)) then $sp else "1g" end)} | nonull)},
          {ref: "port:\($tag)/\($radio.name)", class: "port", name: $radio.name,
           attributes: ({asset: {ref: "asset:\($tag)"}, kind: "wifi", standard: $radio.standard, bands: $radio.bands} | nonull)} ],
        relations: (
          [ {type: "allocated-to", from: "asset:\($tag)", to: "device:\($ap)"} ]
          + [ $ssids | to_entries[] | select(broadcasters(.value) | index($ap))
              | {type: "connects", from: "port:\($tag)/\($radio.name)", to: "ssid:\(.key)", attributes: {origin: "broadcast"}} ]),
        uplink: (if ($d.uplinkSwitch // $a.uplinkSwitch // "") != "" and ($d.uplinkPort // $a.uplinkPort // "") != "" then
                   {sw: ($d.uplinkSwitch // $a.uplinkSwitch), port: (($d.uplinkPort // $a.uplinkPort) | tostring),
                    from: "port:\($tag)/\($up.name)", tag: $tag, name: $up.name}
                 else null end) } ] as $per

  | [ $ssids | to_entries[] | select($only == "" or (broadcasters(.value) | index($only)))
      | {ref: "ssid:\(.key)", class: "ssid", name: .key,
         attributes: (({security: .value.security, zone: .value.zone} | nonull) + {broadcastOn: broadcasters(.value)})}
    ] as $ssidObjs

  | [ head + {
        objects: ($ssidObjs + [ $per[].objects[] ]
                  + [ $ended[] | {class: "device", name: ., end: true} ]
                  + [ $endedSsids[] | {class: "ssid", name: ., end: true} ]),
        relations: [ $per[].relations[] ] } ]
  + [ $per[] | .uplink | select(. != null)
      | tag(.sw; "switch") as $swtag
      | head + {
          objects: [
            {ref: "asset:\(.tag)", class: "network-device", name: .tag},
            {ref: .from, class: "port", name: .name, attributes: {asset: {ref: "asset:\(.tag)"}}},
            {ref: "swasset", class: "network-device", name: $swtag},
            {ref: "swport", class: "port", name: .port, attributes: {asset: {ref: "swasset"}}} ],
          relations: [ {type: "connects", from: "swport", to: .from, attributes: {origin: "recorded"}} ] } ]
  + [ $names[] as $ap | select(($aps[$ap].location // "") != "")
      | head + {
          objects: [ {ref: "loc", class: "location", name: $aps[$ap].location}, {ref: "device:\($ap)", class: "device", name: $ap} ],
          relations: [ {type: "at", from: "device:\($ap)", to: "loc"} ] } ]
  + (if ($ARGS.named.discover // false) then
      [ head + (
          [ $names[] as $ap | (($actual.accessPoints // {})[$ap] // {}) as $a | tag($ap; "access-point") as $tag
            | ([ ($a.radios // [])[] | . + {port: (.name // "radio-\(.band // "0")")} ]) as $radios
            | { objects: (
                  [ {class: "device", name: $ap,
                     attributes: (({managementAddress: ($a.managementIp // $aps[$ap].managementIp), firmware: $a.firmware, uptime: $a.uptime} | nonull)
                       + {clients: [ ($a.clients // [])[] | {mac: (.mac | ascii_downcase), ssid: .ssid, signal: .signal} | nonull ]})},
                    {ref: "asset:\($tag)", class: "network-device", name: $tag} ]
                  + [ $radios[] | {ref: "port:\($tag)/\(.port)", class: "port", name: .port,
                      attributes: (({asset: {ref: "asset:\($tag)"}, kind: "wifi",
                                    standard: (.standard as $st | if (["wifi5", "wifi6", "wifi7"] | index($st)) then $st else null end),
                                    channel: .channel, power: .power} | nonull)
                        + (if .band then {bands: [.band | tostring]} else {} end))} ]
                  + [ ($a.ssids // {}) | keys[] | select($ssids[.] == null)
                      | {ref: "ssid:\(.)", class: "ssid", name: ., attributes: {broadcastOn: [$ap]}} ]),
                relations: [ ($a.ssids // {}) | keys[] | . as $s | select($radios | length > 0) | $radios[]
                  | {type: "connects", from: "port:\($tag)/\(.port)", to: {class: "ssid", name: $s}, attributes: {origin: "seen"}}
                  | if $ssids[$s] == null then .to = "ssid:\($s)" else . end ] } ]
          | {objects: [ .[].objects[] ], relations: [ .[].relations[] ]}) ]
    else [] end)
