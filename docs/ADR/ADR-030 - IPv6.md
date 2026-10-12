# ADR-030 — IPv6: the WAN, the site prefix and a subnet per zone

| | |
|---|---|
| **Status** | **Proposed** (v0.1, 2026-10-12) |
| **Version** | 0.1 |
| **Date** | 2026-10-12 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Related** | **#26** (IPv6, opt-in per site) · **#149** (`site.json` `ipv6`, the site's switch — built) · **#815** (firewall rules cover IPv6 — built) · **#383** (public DNS that follows the WAN) · **#223** (OPNsense interface assignment API) · [ADR-014](<ADR-014 - Zone and Environment Lifecycle.md>) (zones, `changeClass`) · [ADR-021](<ADR-021 - Split-Horizon DNS and Service Reachability.md>) (split-horizon DNS, Caddy) · [ADR-025](<ADR-025 - Config migrations and the upgrade path.md>) (migrations) |
| **Changelog** | v0.1 — first draft, from the operator discussion of 2026-10-12. |

A site turns IPv6 on with one switch. Its WAN then gets IPv6 the way the site declares —
**dynamic** (DHCPv6 with a delegated prefix) by default, **static** where the ISP offers it —
and every zone that carries an **IPv6 subnet number** gets its own `/64` from the site
prefix, with addresses by SLAAC. Zones get a subnet number by default; a zone that should stay
IPv4-only has it removed.

---

## Context

**What is there today.**

- The firewall's WAN takes IPv6 by DHCPv6 because the install template says so
  (`network/firewall-config.xml.template`: `ipaddrv6 dhcp6`, prefix-delegation hint 0). Nothing
  in TAPPaaS declares or converges the WAN afterwards; it lives only in OPNsense's
  `config.xml`. On hrossen the WAN holds a `/128` and a delegated `/56`, and nothing uses them.
- `site.json` `ipv6` (#149, default `false`) is the site's switch. It sets OPNsense's global
  *Allow IPv6*: off drops all inbound and forwarded IPv6 and makes Unbound resolve over IPv4.
- The firewall rules cover IPv6 (#815): zone and module rules name interfaces, so they follow
  whatever addresses a zone carries; an alias of every zone's network keeps zones apart over
  IPv6; ICMPv6 reaches the gateway. Anti-spoofing is IPv4 only (see D9).
- **No zone has an IPv6 address.** Guests accept router advertisements (the NixOS baseline is
  SLAAC) but nothing sends them.

**What the ISPs offer.** Netnørden, hrossen's ISP, is typical
([FAQ](https://netnoerden.dk/faq/22)):

| | Dynamic (recommended by the ISP) | Static |
|---|---|---|
| WAN | DHCPv6, a random `/128` | a fixed `/64`, router `::2`, gateway `::1` |
| Prefix | a random `/56` out of the customer's `/48` | the whole `/48`, routed to the WAN address |
| Lifetime | changes after an outage of more than about an hour, or a router swap | never changes |

Dynamic is what most sites will have; static is what a site that publishes services wants,
because its AAAA records and its devices' addresses then never change.

## Decision

### D1 — `site.json` `ipv6` stays the switch

`ipv6: false` (the default) means everything in this ADR is off: no IPv6 on any zone, the
firewall's *Allow IPv6* off. `ipv6: true` turns it on, and the WAN then gets IPv6 as D2 says.

### D2 — The WAN is declared in `site.json`

```jsonc
"network": {
  "isp": "Netnørden",
  "publicIp": "auto",
  "wan": {
    "ipv4": { "mode": "dhcp" },
    "ipv6": { "mode": "dynamic", "prefixLength": 56 }
  }
}
```

| `wan.ipv4.mode` | Fields | Meaning |
|---|---|---|
| `dhcp` (default) | — | the WAN takes its IPv4 address by DHCP |
| `static` | `address` (CIDR), `gateway` | a fixed IPv4 address |

| `wan.ipv6.mode` | Fields | Meaning |
|---|---|---|
| `dynamic` (**default when `ipv6` is true**) | `prefixLength` (default 56) | DHCPv6 for the WAN address, and a delegated prefix, asked for at that size |
| `static` | `address` (CIDR), `gateway`, `prefix` (CIDR) | a fixed WAN address, and the prefix the ISP routes to it |
| `none` | — | no IPv6 on the WAN, even with `ipv6: true` (no zone gets IPv6 either) |

An absent `wan` reads as `ipv4: dhcp` and, when `ipv6` is true, `ipv6: dynamic` — what the
install template does today, so no existing site changes by this ADR alone.

`wan` is the declaration; OPNsense's WAN interface is converged to it (D7). A WAN edited by
hand in the OPNsense GUI is drift, and the next network update puts it back.

### D3 — The site prefix must be `/56` or larger

Zones draw their `/64`s from the **first `/56`** of the site prefix: 256 subnets, more zones
than a site will ever have. A prefix smaller than `/56` (a `/60`, a `/64`) — stated in
`static`, or delegated in `dynamic` — is refused: the WAN keeps its own address, no zone gets
IPv6, and the network update says why and what to ask the ISP for. A `/48` uses its first
`/56` and leaves the rest free.

In `dynamic` mode the prefix is learned, not declared; the network update reads the delegated
prefix from the firewall and applies the same check.

### D4 — A zone carries an IPv6 subnet number, by default

```jsonc
"home": { "vlantag": 310, "ip": "10.3.10.0/24", "ipv6Subnet": 16, … }
```

- `ipv6Subnet` is a number, 0–255: the zone's `/64` within the site's first `/56`.
- **Every zone gets one by default.** The template carries them, `network-manager add`
  allocates the next free number (as it allocates VLAN tags), and a config migration stamps
  the zones of existing sites once. Numbers are unique per site.
- **A zone without `ipv6Subnet` gets no IPv6.** An operator keeps a zone IPv4-only by removing
  the field (`network-manager modify <zone> --unset ipv6Subnet`).
- It is `immutable` (ADR-014 `changeClass`), like `ip`: a new number renumbers every device in
  the zone. Changing it is delete-and-re-add, as for `ip`.
- `mgmt`, the overlays and the WAN hand-off get no number: the control plane stays on IPv4.

### D5 — A zone's IPv6 network

| Mode | The zone's `/64` | The firewall's address on it |
|---|---|---|
| `static` | the site prefix's first `/56`, with `ipv6Subnet` as its last 8 bits | `::1` in that `/64` |
| `dynamic` | OPNsense *Track interface* on the WAN, **prefix ID = `ipv6Subnet`** | chosen by OPNsense (EUI-64 or `::1`) |

Worked example, static `2a13:e747:6648::/48`: `home`, `ipv6Subnet` 16 (`0x10`) →
`2a13:e747:6648:10::/64`, firewall `2a13:e747:6648:10::1`. With a delegated
`2a13:e747:a210:8200::/56`, the same zone is `2a13:e747:a210:8210::/64`.

The same number means the same position in both modes, so a site that moves from dynamic to
static keeps each zone's place in its prefix.

### D6 — Devices configure themselves (SLAAC)

Every zone with IPv6 sends router advertisements (*unmanaged*: SLAAC, no DHCPv6 server),
with the firewall's address on the zone as the DNS server (RDNSS). Internal names stay A
records only: split-horizon DNS (ADR-021) is unchanged, and IPv6 inside the site is used by
name through Caddy and for internet egress. A DHCPv6 server, for devices that cannot do SLAAC,
is not part of v1.

### D7 — One converging step, in the network update

`ipv6-manager` (#149) grows from *Allow IPv6* to the whole of this ADR. The network module's
update runs it, so it applies on every sweep and on `module-manager update network`:

1. *Allow IPv6* from `ipv6` (as today).
2. The WAN's IPv4 and IPv6 configuration from `network.wan`.
3. The site prefix: the declared one (`static`) or the delegated one (`dynamic`), checked
   against D3.
4. Per zone with `ipv6Subnet`: its IPv6 interface configuration (D5) and router
   advertisements (D6). Per zone without: none, and no advertisements.

It changes only what differs, and like today it checks that the resolver still answers. A
change to the WAN or to a zone's IPv6 reloads that interface only.

### D8 — Turning it off, and changing mode

- `ipv6: false`, `wan.ipv6.mode: none`, or removing a zone's `ipv6Subnet`: the IPv6
  configuration is removed and router advertisements stop with a zero router lifetime, so
  devices drop their addresses promptly instead of at their lifetime's end.
- `dynamic` → `static`: every zone renumbers into the static prefix (same `ipv6Subnet`). Old
  addresses are deprecated by the advertisements; nothing else changes, because the firewall
  rules name interfaces.

### D9 — What stays to be built on the firewall

- **IPv6 anti-spoofing.** A negated interface network in OPNsense also covers link-local
  (`fe80::/10`), so the IPv4 rule's form would block traffic IPv6 needs. v1 writes it as a block
  of sources outside the zone's network *table* (`__optN_network`, which holds no link-local),
  after a pass for link-local sources to the firewall.
- **Public names.** A published name gets an AAAA record: the DMZ's IPv6 address. Static: set
  once. Dynamic: kept current by the same path that follows a changing WAN IPv4 address (#383).
- **Inbound from the internet.** IPv6 has no port forwarding. The Caddy entry on the WAN gets an
  IPv6 pass to the DMZ address, and a module's `natRules` (only in a zone that accepts the
  internet) become IPv6 passes to its address. Nothing else is reachable from outside.

## Consequences

**Positive**
- One switch, and IPv6 works on a site with the ISP's default service, with no further input.
- A site with a static prefix gets stable addresses and AAAA records, and states the prefix once.
- The rules already in place (#815) need no change; only anti-spoofing is added.
- A zone opts out with one field.

**Negative**
- On a dynamic prefix, devices renumber when the ISP changes the prefix; anything that stores
  an IPv6 address (not a name) breaks. Published names follow; internal names are IPv4.
- The WAN becomes TAPPaaS-managed: a hand edit in the GUI is reverted by the next update.
- A config migration touches every site's `zones.json` once (stamping `ipv6Subnet`), and
  `site.json` gains `network.wan`.

**Open**
- **OPNsense's API for interface IPv6 settings** (WAN mode, *Track interface*, static IPv6 on a
  VLAN interface, router advertisements). If it is thin (cf. #223), D7 edits `config.xml` over
  ssh and reloads the interface, as other foundation scripts do. **Spike this first.**
- How a site's IPv4 range can be smaller than `10.0.0.0/8` (a `site.json` base the zones'
  `ip` is computed from) — the same shape as this ADR, decided separately.

## Rollout

1. Spike the OPNsense API (D7, open point), on hrossen, on an unused zone.
2. Schema: `site.json` `network.wan`, `zones.json` `ipv6Subnet`; the migration that stamps it.
3. `ipv6-manager`: WAN, prefix check, per-zone configuration and advertisements.
4. hrossen: Netnørden switches the line to static; `site.json` gets the static `wan.ipv6`; one
   zone first (`test`), then the rest.
5. AAAA for published names; IPv6 anti-spoofing; the Caddy WAN entry.
