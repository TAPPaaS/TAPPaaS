# ADR-030 — IPv6: the WAN, the site prefix and a subnet per zone

| | |
|---|---|
| **Status** | **Proposed** (v0.4, 2026-10-12) |
| **Version** | 0.3 |
| **Date** | 2026-10-12 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Related** | **#26** (IPv6, opt-in per site) · **#149** (`site.json` `ipv6`, the site's switch — built) · **#815** (firewall rules cover IPv6 — built) · **#383** (public DNS that follows the WAN) · **#223** (OPNsense interface assignment API) · [ADR-014](<ADR-014 - Zone and Environment Lifecycle.md>) (zones, `changeClass`) · [ADR-021](<ADR-021 - Split-Horizon DNS and Service Reachability.md>) (split-horizon DNS, Caddy) · [ADR-025](<ADR-025 - Config migrations and the upgrade path.md>) (migrations) |
| **Changelog** | v0.4 (2026-10-12) — **published names inside the site are dual-stack (built)**: every split-horizon A record that points at a firewall interface gets an AAAA for that interface's IPv6 address, and every TAPPaaS Caddy access list gets the IPv6 network of each zone it names by IPv4. Both are read from the interfaces, so a changed prefix or IPv6 switched off is followed on the next network update; the writers (`unbound-manager add`, `caddy-manager add-accesslist`) add them at once. Proven on hrossen: client → Caddy → service over IPv6, same answers as IPv4 for every published name. v0.3 (2026-10-12, operator request after the first rollout on hrossen) — **internal names resolve to IPv6 too**: router advertisements move from radvd to dnsmasq in `ra-names` mode, which gives every VM with a DHCPv4 lease an AAAA record from its EUI-64 address; the NixOS baseline switches to EUI-64 without temporary addresses. VM to VM and Caddy to a service then work over IPv6 by name; the internal split-horizon answer for a published name gains the DMZ's IPv6 address. Proven by a spike on hrossen's test zone. v0.2 (2026-10-12) — the OPNsense spike on hrossen settles D7's open point: interface IPv6 is `config.xml` through OPNsense's PHP config library, router advertisements are the Radvd API; the WAN's delegation size must be written, a tracked zone's firewall address is EUI-64, a tracked interface advertises *managed* unless told otherwise, and removing IPv6 leaves the address behind. v0.1 — first draft, from the operator discussion of 2026-10-12. |

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
  allocates one (as it allocates VLAN tags), and config migration 0016 stamps the zones of
  existing sites once, in VLAN order. The number is the VLAN tag read as hex where that fits
  (VLAN 310 → `0x31`, so `home`'s network ends in `…31::/64`), else the lowest free number.
  Numbers are unique per site.
- **A zone without `ipv6Subnet` gets no IPv6.** An operator keeps a zone IPv4-only by removing
  the field (`network-manager modify <zone> --unset ipv6Subnet`).
- It is `immutable` (ADR-014 `changeClass`), like `ip`: a new number renumbers every device in
  the zone. Changing it is delete-and-re-add, as for `ip`.
- `mgmt`, the overlays and the WAN hand-off get no number: the control plane stays on IPv4.

### D5 — A zone's IPv6 network

| Mode | The zone's `/64` | The firewall's address on it |
|---|---|---|
| `static` | the site prefix's first `/56`, with `ipv6Subnet` as its last 8 bits | `::1` in that `/64` |
| `dynamic` | OPNsense *Track interface* on the WAN, **prefix ID = `ipv6Subnet`** | EUI-64, from the interface's MAC (the spike: `…8210:98:34ff:fe69:901a`) |

Worked example, static `2a13:e747:6648::/48`: `home`, `ipv6Subnet` 16 (`0x10`) →
`2a13:e747:6648:10::/64`, firewall `2a13:e747:6648:10::1`. With a delegated
`2a13:e747:a210:8200::/56`, the same zone is `2a13:e747:a210:8210::/64`.

The same number means the same position in both modes, so a site that moves from dynamic to
static keeps each zone's place in its prefix.

### D6 — Devices configure themselves, and internal names get AAAA records

**dnsmasq** — which already serves DHCPv4 and the internal names (`<vm>.<zone>.internal`,
reached through Unbound's `internal` forward) — sends the router advertisements, one IPv6 range
per zone in **`ra-names`** mode, built from the zone interface's prefix (`constructor`), so it
follows a changing prefix:

```
dhcp-range=tag:vlan0.299,::,constructor:vlan0.299,ra-names,64,86400
```

Devices take addresses by SLAAC. For every host with a DHCPv4 lease, dnsmasq computes the
EUI-64 address its MAC gives in the zone's `/64`, pings it, and on an answer adds an **AAAA
record under the same name**. So a VM's name resolves to both families with no registration
step, and its address is stable: Proxmox fixes the MAC, and a static prefix fixes the rest.

- **The NixOS baseline uses EUI-64 and no temporary addresses** (NetworkManager
  `ipv6.addr-gen-mode = eui64`, `ipv6.ip6-privacy = 0`) — the address dnsmasq computes is the
  address the VM has. Client devices (phones, laptops) keep their privacy addresses and get no
  AAAA, which is right: names matter for servers.
- **No DHCPv6 server.** Stateful DHCPv6 would name hosts too, but Android does not do it and it
  would be a second way to hand out addresses.
- radvd is not used for zones: two daemons advertising on one interface conflict.

What follows from names with both families:

- **VM to VM** over IPv6, by name: zone rules are dual-stack (#815), and a module's host alias
  (`tm_<vm>`) resolves A *and* AAAA — OPNsense's alias resolver asks for both — so every pinhole
  covers IPv6 within the alias's refresh (300 s).
- **Caddy to a service** over IPv6: Caddy reaches upstreams by name and tries IPv6 first,
  falling back to IPv4 at once (Go's dialer). A service that listens on IPv4 only (`0.0.0.0`)
  keeps working over IPv4; one that listens on `[::]` is reached over IPv6.
- **Services listen on both families**, and **trust Caddy by its IPv6 address too.** Over
  IPv6, Caddy's requests come from the firewall's address in the service's zone, which
  follows the prefix. `ipv6-manager gateway <zone>` reads it from the interface, and the
  deploy adds it to the module's companion JSON as `proxySourceV6`. A module that trusts its
  proxy by address (Nextcloud `trusted_proxies`, Immich `IMMICH_TRUSTED_PROXIES`) trusts that
  one `/128` beside its IPv4 rule. After a prefix change it is picked up by the next update;
  until then the service sees the proxy as the client. Two stay IPv4, and Caddy reaches
  them over IPv4: a container on a Podman bridge network (Euro-Office), whose port mapping
  forwards IPv4 only, and a single-worker uvicorn (Open WebUI), which on `::` binds IPv6 *only*
  (asyncio sets `IPV6_V6ONLY`) and would refuse IPv4.

### D7 — One converging step, in the network update

How each part is written, as the spike on hrossen (2026-10-12) found it on OPNsense 26.1:

| Part | Written through | Notes |
|---|---|---|
| WAN IPv6 mode, address, gateway | `config.xml` (`interfaces/wan`: `ipaddrv6`, `subnetv6`, `gatewayv6`) via OPNsense's PHP config library, then `configctl interface reconfigure wan` | no MVC API; a WAN reconfigure renews IPv4 too, so it runs only on a change |
| Delegated prefix size | `config.xml` `interfaces/wan/dhcp6-ia-pd-len` (`/56` = 8, `/48` = 16; `0` means `/64`) | **must match** `prefixLength`: at the template's `0`, OPNsense ignores every prefix ID and a tracked zone gets the whole `/56` |
| A zone's IPv6 | `config.xml` (`ipaddrv6` = `track6`, `track6-interface`, `track6-prefix-id`; or a static `ipaddrv6`/`subnetv6`), then `configctl interface reconfigure <optN>` | reloads that zone only. Verified: prefix ID 16 on a `/56` gives `…:8210::/64` |
| Router advertisements and AAAA names | the dnsmasq API, `dnsmasq/settings/addRange` (payload key `range`: `interface`, `start_addr` `::`, `constructor` = the interface, `ra_mode` `ra-names`), then `dnsmasq/service/reconfigure` | spike 2026-10-12: the AAAA appeared within seconds of the host's DHCPv4 request. A tracked interface without an explicit RA source gets radvd's *managed* default — so no radvd entry, and the dnsmasq range present |
| Turning a zone's IPv6 off | remove the `config.xml` keys and the dnsmasq IPv6 range, reconfigure, **then delete the address from the interface** and refresh the aliases | the reconfigure leaves the tracked address on the interface until its lifetime ends; removing the range removes the zone's AAAA records |

What the step does:

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
- **Published names, inside the site — built (v0.4).** Split-horizon DNS (ADR-021) answers a
  published name with the DMZ gateway's IPv4 address, and AAAA with the DMZ interface's IPv6
  address. The AAAA follows the A: any A record pointing at a firewall interface gets one,
  marked ` [IPv6]` in its description, for that interface's global IPv6 address, read from the
  interface rather than computed. Caddy's access lists name zones by IPv4; each zone they name
  gets its IPv6 network beside it, or a client in it that arrives over IPv6 is refused.
  `unbound-manager add` and `caddy-manager add-accesslist` write the counterparts at once;
  `ipv6-manager apply` brings all of them up to date on every network update (a new prefix,
  IPv6 off). The caddy-reach rule already covers IPv6; Caddy reaches its upstreams by name and
  so over IPv6 where the service listens on it.
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
- How a site's IPv4 range can be smaller than `10.0.0.0/8` (a `site.json` base the zones'
  `ip` is computed from) — the same shape as this ADR, decided separately.

## Rollout

1. ~~Spike the OPNsense API~~ — done 2026-10-12, findings in D7.
2. Schema: `site.json` `network.wan`, `zones.json` `ipv6Subnet`; the migration that stamps it.
3. `ipv6-manager`: WAN, prefix check, per-zone configuration and advertisements.
4. hrossen: Netnørden switches the line to static; `site.json` gets the static `wan.ipv6`; one
   zone first (`test`), then the rest.
5. AAAA for published names; IPv6 anti-spoofing; the Caddy WAN entry.
