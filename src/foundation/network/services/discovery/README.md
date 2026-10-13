# network:discovery service

Relays **mDNS and legacy broadcast discovery** across zone boundaries, so a
device on one VLAN can find a service on another without the two sharing a
broadcast domain.

mDNS is one group shared by the whole site: the zones with `"mdns": true` in
zones.json and, per module, its `zone0` plus the zones `discoveryMdns` names.
`mdns-manager` converges the firewall's repeater and its rule from all of them, so
adding or removing a module's declaration is a reconcile like any other. The UDP
relays are per module and port.

<!-- BEGIN GENERATED FIELDS -- edit the manifest, not this block -->

## Fields

`network:discovery` owns **2** declared field(s). Each table below carries the field's full definition and, where the service applies it, its ADR-020 change semantics.

### `discoveryMdns`

Consumer zones to bridge with zone0 in the mDNS repeater (os-mdns-repeater). zone0 is always included as the provider zone.

| Attribute | Value |
|---|---|
| Type | `array` |
| Default | *(none)* |
| Example | `home`, `srvHome` |
| Required by | *(none)* |
| Used by | `network:discovery` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Requires network:discovery in dependsOn. zone0 and these zones join the one mDNS group, together with every zone that has mdns: true in zones.json; mdns-manager converges the repeater from all of them. Boolean true is deprecated (zone0 only).

**Why this change class.** mDNS service types relayed across zones so a client in one zone can find this module in another. A relay change is a firewall/avahi reload, not a guest change.

### `discoveryUdpRelay`

UDP broadcast relay instances via os-udpbroadcastrelay. Each entry creates one relay identified by 'tappaas:<module>:<port>'.

| Attribute | Value |
|---|---|
| Type | `array` |
| Default | *(none)* |
| Example | `[{"port": 36549, "zones": ["home", "iotCloud"]}]` |
| Required by | *(none)* |
| Used by | `network:discovery` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Requires network:discovery in dependsOn. Idempotent: checks description before adding. Reload is triggered only when new entries are added.

**Why this change class.** UDP broadcast ports relayed across zones (discovery protocols that predate mDNS). Same cost.

<!-- END GENERATED FIELDS -->
