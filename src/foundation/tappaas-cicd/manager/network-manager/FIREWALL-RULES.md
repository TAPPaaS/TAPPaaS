# Firewall Rules in TAPPaaS

How the zones a site declares, and the modules installed in them, become the rule set on the
OPNsense firewall: who writes which rules, in what order the firewall evaluates them, and what
each kind of rule is for. [ZONES.md](ZONES.md) describes the zones themselves — what a zone is,
the trust model it is meant to express, and the zone lifecycle. This page is the other half:
what the firewall actually does with them.

It describes the system **as built** (reviewed 2026-10-12 against the code, #816). Where the
code does less than the model promises, the gap is named in [Known gaps](#known-gaps) rather
than left out.

## In one paragraph

Every rule TAPPaaS writes is a **pass or block on the interface where traffic arrives**, marked
`quick` — the first rule that matches decides. The order is set by a **sequence number**, and
TAPPaaS keeps its rules in fixed bands: a zone's protective blocks first, then the per-module
pinholes, then each zone's own baseline (its gateway, the zones it may reach, a block on every
other private network, and the internet). Zone rules come from `zones.json`; module rules come
from each module's `network:rules` and its service dependencies. Everything not passed is
dropped by OPNsense's default deny.

## Who writes the rules

| Writer | Writes | From | Owns rules named |
|---|---|---|---|
| `zone-manager` (via `network-manager reconcile`) | each zone's baseline and protective rules, caddy-reach | `config/zones.effective.json` | `Zone <zone> …` |
| `rules-manager` | per-module ingress/egress, auto-pinholes from service dependencies, NFS egress | `config/<module>.json`, `services/*/pinhole.json`, `config/shares.json` | `tappaas-module:<vm>:…`, `tappaas-svcdep:<consumer>:…`; aliases `tm_*`, `nfs_*` |
| `nat-manager` / `snat-manager` | port forwards (rdr-pass on WAN), outbound NAT | module and zone declarations | — |
| Other components, directly | the admin VPN, satellite, backup-buddy and Caddy WAN rules | their own scripts | see [Rules written outside the managers](#rules-written-outside-the-managers) |

Each writer finds and replaces **only its own rules**, by their description. A rule an operator
adds in the OPNsense GUI with any other description is never touched.

## From `zones.json` to the rule set

1. **Authored** — `config/zones.json`: each zone's subnet, `access-to` (the zones it may reach,
   subnet to subnet), `pinhole-allowed-from` (the zones whose modules may open a pinhole into
   it), `serves`, `tier`, `isolated`.
2. **Effective** — `network-manager reconcile` renders `config/zones.effective.json`: the
   authored file plus the edges `serves` derives. A Client or Guest zone that serves an
   environment gets that environment's service zone in its `access-to`; an IoT zone gets it in
   its `pinhole-allowed-from`. The edge is added only to the zone that declares `serves`
   ([ZONES.md](ZONES.md#serves--linking-a-client-or-iot-zone-to-an-environment)).
3. **`all` expanded** — where a zone (only `mgmt`) says `all`, the controller reads it as
   `internet` plus every zone that is not `Disabled`, an `Overlay` or the `WAN` hand-off.
4. **Zone rules** — `zone-manager` writes the baseline of every `Active` or `Mandatory` zone
   with a non-empty `access-to`, removes the rules of disabled and deleted zones, and applies
   once.
5. **Module rules** — `rules-manager` compiles each module's declared ingress and egress and
   its service dependencies into rules and host aliases, checks them against the zones, and
   applies them. A module's install adds its rules; its update **reconciles** them (adds what
   is missing, removes what it no longer declares); its delete removes them.

`tier` and `isolated` do **not** feed the rules. They are checked by `network-manager validate`
(the invariants in [ZONES.md](ZONES.md#security-invariants-network-manager-validate)) and warn;
what the firewall enforces is `access-to` and `pinhole-allowed-from`.

## Evaluation order

All rules are `quick`: the **lowest sequence number that matches decides**. On a zone's
interface the order is:

| Order | Sequence | Rules | Written by |
|---|---|---|---|
| 1 | OPNsense | anti-lockout, DHCP, bogons and system rules | OPNsense |
| 2 | 970 | **anti-spoofing** — drop any source outside the zone's subnet | zone-manager |
| 3 | 980, 981 | **admin guard** — block TCP 8443 (GUI) and 22 (SSH) to every firewall address | zone-manager |
| 4 | 990, 991 | **caddy-reach** — pass TCP 443 and 80 to the DMZ gateway (`/32`), where Caddy listens | zone-manager |
| 5 | 10000–19999 | **module ingress** and **auto-pinholes** | rules-manager |
| 6 | 20000–29999 | **module egress** | rules-manager |
| 7 | 30000–39999 | the **zone baseline** (table below) | zone-manager |
| 8 | — | rules created without a sequence (other components, the GUI) | various |
| 9 | — | **default deny** | OPNsense |

Within the module bands each module has 100 slots, picked by a stable hash of its `vmname`;
within band 7 each zone has 100 slots by a hash of its name. The bands are why a pinhole
works: it is evaluated before the destination's private-network block that would otherwise
drop it.

## Zone rules

For each `Active`/`Mandatory` zone with a non-empty `access-to`, on the zone's own interface
(`base` = the zone's slot in band 7):

| Sequence | Rule | Action |
|---|---|---|
| 970 | `Zone Z block spoofed source` | block, source not in the zone's subnet |
| 980 / 981 | `Zone Z block firewall webgui` / `ssh` | block TCP 8443 / 22 to the firewall itself |
| 990 / 991 | `Zone Z -> caddy https` / `http` | pass TCP 443 / 80 to the DMZ gateway |
| base+0 | `Zone Z -> gateway dns` | pass TCP/UDP 53 to the zone's own gateway |
| base+1 … +85 | `Zone Z -> <zone>` | pass any, to each zone in `access-to` (whole subnet, every port) |
| base+86 / 87 / 88 | `Zone Z -> gateway ntp` / `dhcp` / `icmp` | pass UDP 123 / UDP 67 / ICMP to the gateway |
| base+90 … 92 | `Zone Z block rfc1918-10` / `172` / `192` | block every other private network (only when `internet` is in `access-to`) |
| base+99 | `Zone Z -> internet` | pass any (only when `internet` is in `access-to`) |

**What a zone may ask of the firewall.** Its gateway serves it DNS, NTP, DHCP and ICMP, and
nothing else: the admin GUI and SSH are blocked from every zone on every firewall address,
because an `access-to` edge grants a whole subnet and every zone's gateway *is* the firewall
(#384, #399). Fragments need no rule — OPNsense reassembles them before filtering.

**Caddy-reach** (ADR-021 D3). Split-horizon DNS answers every published name with the DMZ
gateway, where Caddy listens, and no zone may hold `access-to: dmz` (invariant I5, #618). So a
zone reaches Caddy by its own rule at 990/991 — ahead of its private-network block — on two
ports, to one address. It is reachability only: Caddy's `proxyAllowedZones` and the identity
gate decide who gets in. Candidates are a zone with `internet` (or `all`) in `access-to`, an
`Overlay` with a non-empty `access-to` (the admin VPN), and `dmz` itself.

**Manual zones get no zone rules.** `mgmt` reaches everything through the firewall's own LAN
rules and OPNsense's anti-lockout; the overlays (admin VPN, NetBird, edge) through the rules
their own components write. `mgmt`'s `all` is therefore a statement for the checks and for
SNAT, not a rule.

## Module rules

A module declares its traffic in its own JSON (`network:rules`; full schema and a worked
example in [network/DESIGN.md](../../../network/DESIGN.md#per-module-firewall-rules)):

- **Ingress** — who may reach this module, on which ports. From a zone: the rule is on that
  zone's interface and admits the **whole source zone**. From another module: only that
  module's addresses (its `tm_<module>` alias). From `alias:X` or `internet`: on the LAN or WAN.
  The source zone must be in the destination zone's `pinhole-allowed-from`.
- **Egress** — what this module may reach beyond its zone's `access-to`: a zone, a module, an
  alias, or `internet`. A target outside `access-to` is allowed and warned about.
- **Auto-pinholes** — when a module depends on another module's service (`dependsOn`,
  `integratesWith`), `rules-manager` opens the provider's ports from the consumer's address to
  the provider's, on the consumer's interface — if the provider's zone allows the consumer's
  zone in `pinhole-allowed-from`, and the consumer's `access-to` does not already cover it.
- **Aliases** — a module peer is an OPNsense host alias holding the peer's DNS name
  (`<vm>.<zone>.internal`), so a changed DHCP address needs no rule change.

Rule names carry their identity: `tappaas-module:<vm>:ingress:<peer>:<port>`,
`tappaas-svcdep:<consumer>:<service>:<provider>:<port>`, each followed by a human description.

## Address family

TAPPaaS rules are **IPv4 only** today. Whether a site supports IPv6 at all is `site.json`
`ipv6` (#149, default `false`): when it is false, the firewall drops all inbound and forwarded
IPv6 ahead of every TAPPaaS rule, and DNS resolves over IPv4 only. No zone has an IPv6 address.
Making every zone rule cover IPv6 too is #815; giving zones IPv6 is #26, behind its own ADR.

## Rules written outside the managers

These components write their own rules, by description, without a sequence number:

| Component | Rules |
|---|---|
| Admin VPN (`network-manager/wgvpn`) | `tappaas-admin admin->mgmt` (the VPN's peers reach `mgmt`), `tappaas-admin WAN :<port>` |
| Satellite | `tappaas-satellite edge->caddy`, `edge->admin-wg`, `edge->home-pbs`, `mgmt->pbs <name>` |
| Backup buddy | `buddy-<n> serve wg` (WAN), `buddy-<n> pull` (mgmt) |
| Caddy setup | `TAPPaaS: Allow HTTP/HTTPS to Caddy` (WAN) |

No component writes the NetBird rules; on a site that runs NetBird they are set by hand
(#385, #222 — pending a decision on NetBird's role).

## Checking it

```bash
network-manager validate --effective     # the zone model: references, tiers, invariants
zone-manager --summary                   # zones, their interfaces, pinhole policy warnings
rules-manager verify-rules <module>      # a module's declared rules vs what OPNsense holds
rules-manager expected-pinholes <module> # which auto-pinholes it should carry, and why any are not
rules-manager list-rules --orphans       # TAPPaaS rules nothing declares any more
ssh root@firewall.mgmt.internal 'pfctl -sr'   # the rules pf actually evaluates, in order
```

## Known gaps

Found by the 2026-10-12 review (#816; the full evidence is in
[docs/design/zone-rules-review.md](../../../../../docs/design/zone-rules-review.md)). Each is
tracked to be fixed or decided:

- **Stale protective rules.** Removing or renaming a zone leaves its anti-spoofing and admin-guard
  rules behind (D1). On an interface reused by a new zone, the old anti-spoofing rule would
  block all its traffic.
- **Changed rule properties are not repaired.** A rule is compared by name, source, destination
  and port only: a rule disabled in the GUI, or with a different protocol or address family,
  stays as it is (D2). This blocks #815.
- **The trust model is checked, not enforced.** Module egress is not checked against an
  `isolated` target or its `pinhole-allowed-from`; ingress from another module, an alias or the
  internet is not policy-checked; port forwards have no zone gate (D4–D6).
- **A zone with an empty `access-to`** (no egress, e.g. `iotLocal`) gets no rules at all — no
  anti-spoofing, no gateway DNS or NTP (D15). An `isolated` zone with internet egress gets the
  full set.
- **The private-network block is RFC 1918 only.** 100.64.0.0/10 (carrier-grade NAT, NetBird)
  and 169.254.0.0/16 are reachable from every zone with internet (D14).
- **Caddy-reach's source is `10.0.0.0/8`**, not the zone's subnet. Anti-spoofing narrows it on a
  VLAN; on the WireGuard interface group, which has no anti-spoofing, it admits every tunnel (T8).
