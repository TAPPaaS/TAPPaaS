# network:discovery service

Relays **mDNS and legacy broadcast discovery** across zone boundaries, so a
device on one VLAN can find a service on another without the two sharing a
broadcast domain.

Both are lists of zone pairs, reconciled by rewriting the relay configuration and
reloading. Removing a relay is as ordinary as adding one, which is what puts them
on `reconcile`.

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

**About the field.** Requires network:discovery in dependsOn. Idempotently unions zone0 + declared consumer zones into the repeater interface list. Boolean true is deprecated.

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
