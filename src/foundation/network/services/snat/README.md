# network:snat service

Provides source-NAT (masquerade) rules on OPNsense so traffic entering this
module's zone arrives with the zone gateway's address instead of the client's
own.

This exists for one narrow class of device: appliances whose firmware accepts
TCP sessions only from their own `/24`. A firewall rule that permits the
traffic is not enough — the packets are passed, and the *device* drops them.
The Alfen NG5 charger is the reference case (#239): reachable from inside
`iotCloud`, silently unreachable from `home`, with the OPNsense log showing
every packet passed.

`network:snat` is **source** NAT. `network:nat` (#285) is **destination** NAT
— port-forwards that expose an inside port to the outside. The names are one
letter apart and the directions are opposite; if you are publishing a port,
you want `network:nat`.

## The zone consents, the module requests

Masquerading into a zone affects **every device in it**, not just the module
that asked: the target zone loses client attribution for all masqueraded
sessions, and no logging layer downstream can recover it. So the permission
lives with the zone, exactly as `pinhole-allowed-from` does:

```jsonc
// zones.json
"iotCloud": {
  "pinhole-allowed-from": ["srvHome", "home"],
  "snat-allowed-from":    ["srvHome", "home"]   // must be a subset
}
```

A module's `snatFrom` is a *request*. The effective set is
`snatFrom ∩ zone.snat-allowed-from`, and a zone named outside the gate is
**refused, not trimmed** — silently narrowing a request would hand back a
half-working masquerade and call it success, which is the failure mode this
service was built to end.

A zone with no `snat-allowed-from` refuses everything. Opt-in, always.

## How a module uses it

Add `network:snat` to `dependsOn` and declare the request:

```jsonc
{
  "vmname": "alfen",
  "zone0": "iotCloud",
  "dependsOn": [
    "network:rules",
    "network:snat"
  ],
  "config": {
    "network:snat": {
      "snatFrom": ["home", "srvHome"],
      "snatReason": "Alfen NG5 firmware rejects sessions sourced outside iotCloud"
    }
  }
}
```

The destination is always the module's own `zone0`; a module cannot masquerade
into a zone it does not live in. `snatReason` is mandatory and free text — it
travels with the rule so the next operator learns why a zone lost attribution.

## The outbound-mode prerequisite

OPNsense will accept a source-NAT rule into its config and then never enforce
it, depending on a firewall-wide setting this service does not own:

| `snat_mode` | Auto rules | Custom rules |
|---|---|---|
| `automatic` | generated | **ignored — accepted into config, never enforced** |
| `hybrid` | generated | evaluated, ahead of the auto ones |
| `advanced` (GUI: "Manual") | **not generated** | the only ones |
| `disabled` | none | none |

`automatic` only ever generates *internal → WAN* rules; it has no concept of
VLAN-to-VLAN masquerade, so the rule this service needs can never come from
automatic generation and is inert while that mode is set.

`network-manager snat verify` therefore asserts **enforcement, not presence** —
a rule that exists in config under `automatic` is a failure, not a pass. That
distinction is the whole point: #239 reported success for three weeks on a
masquerade that was never in the ruleset.

Moving to `hybrid` is additive — the automatic per-interface rules keep being
generated exactly as before. `advanced` replaces them entirely and can drop
outbound connectivity site-wide, so it is never set automatically.

## Lifecycle

| Hook | Behaviour |
|---|---|
| `install-service.sh` | Apply the gated request; **fatal** on refusal |
| `update-service.sh` | Re-assert, picking up edits to `snatFrom` or the zone gate |
| `delete-service.sh` | Remove this module's rules unconditionally |
| `test-service.sh` | Assert declared == live **and enforced** |

Install failing hard is deliberate. A module whose only working path is the
masquerade, installed "successfully" without it, is #239.

## Implementation

`network-manager snat` owns the verbs and the zone gate; it shells out to
`opnsense-controller`, which wraps `firewall/source_nat`. The module never
touches the OPNsense API.

Rules are keyed by description — `tappaas-snat:<module>:<from>-><zone0>` —
which is both the idempotency key and the ownership marker, the same scheme
`rules-manager` and `nat-manager` already use. A rule matching the prefix that
no module declares is reported as unowned; it is never silently deleted.

<!-- BEGIN GENERATED FIELDS -- edit the manifest, not this block -->

## Fields

`network:snat` owns **2** declared field(s). Each table below carries the field's full definition and, where the service applies it, its ADR-020 change semantics.

### `snatFrom`

Zones whose traffic to this module's zone0 is masqueraded to the zone0 gateway address, so the module's device sees a source inside its own subnet. Required by appliances whose firmware rejects sessions originating outside their /24 — the Alfen NG5 charger is the reference case. Each entry becomes one OPNsense source-NAT rule on the zone0 interface. The request is intersected with the target zone's snat-allowed-from gate in zones.json; naming a zone outside that gate is refused, not trimmed, because a module must never widen its own permission.

| Attribute | Value |
|---|---|
| Type | `array` |
| Default | *(none)* |
| Example | `home`, `srvHome` |
| Required by | `network:snat` |
| Used by | `network:snat` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Zone names as spelled in zones.json (camelCase). The destination is always this module's zone0 — a module cannot masquerade into a zone it does not live in. An empty list is a no-op, not an error, so a module can carry the dependency without requesting anything yet.

**Why this change class.** Adding a zone starts rewriting the source address of every session it sends to this zone; removing one stops. It is a live firewall change — existing connections may reset, no guest is rebooted — so it needs no disruption authorization. The rule is only ENFORCED while the firewall's outbound mode is hybrid or advanced; network:snat reports the mode rather than assuming it, because a rule accepted into config under automatic mode is silently inert.

### `snatReason`

Why this module needs masquerade, in the operator's own words. Recorded because source NAT costs the target zone its client attribution: the device, and anything reading its logs, sees the zone gateway address instead of the real client for every masqueraded session. That loss is irreversible downstream, so the reason travels with the rule — it appears in snat list output and in the OPNsense rule description context, where the next operator will actually meet it.

| Attribute | Value |
|---|---|
| Type | `string` |
| Example | `Alfen NG5 firmware rejects sessions sourced outside iotCloud` |
| Required by | `network:snat` |
| Used by | `network:snat` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Required whenever snatFrom is non-empty. Free text, one line; it is documentation, not a key, and nothing parses it.

**Why this change class.** Documentation carried alongside the rule. Rewriting it re-descriptions the live rules on the next reconcile and changes no traffic.

<!-- END GENERATED FIELDS -->
