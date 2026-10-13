# IPv6 in TAPPaaS

How a site runs IPv6 next to IPv4: how to turn it on, where its addresses come from, what
changes on the firewall, the guests and the reverse proxy, and how to turn it off again.
[ZONES.md](ZONES.md) describes the zones and [FIREWALL-RULES.md](FIREWALL-RULES.md) the rule
set; both cover IPv4 and IPv6 alike. This page covers what is particular to IPv6.

IPv4 is always there. IPv6 is added beside it, per site and per zone, and everything that
works over IPv6 also works over IPv4.

## In one paragraph

A site has IPv6 when `site.json` says `"ipv6": true` and its internet connection provides
it. The firewall then takes an IPv6 prefix from the WAN — delegated by the ISP, or declared —
and gives every zone that has an `ipv6Subnet` its own `/64` from it. Devices in the zone
configure themselves (SLAAC). Every VM's name resolves to its IPv6 address as well as its
IPv4 one, the firewall rules apply to both, and names published through the reverse proxy
answer over IPv6 too. All of it is applied by the update of the `network` module, and taken
away again when `ipv6` goes back to `false`.

## Turning it on

Set the switch in `config/site.json` and update the `network` module:

```jsonc
{
  "ipv6": true,                          // default false
  "network": {
    "wan": {
      "ipv6": { "mode": "dynamic" }      // optional: dynamic is the default
    }
  }
}
```

```bash
module-manager update network
```

The update sweep runs the same step, so the switch is applied by the next sweep as well.

### The WAN: dynamic, static or none

`network.wan.ipv6.mode` says how the firewall's WAN gets its IPv6:

| Mode | What the firewall does | Fields |
|---|---|---|
| `dynamic` (default) | Asks the ISP for an address and a delegated prefix (DHCPv6 with prefix delegation). | `prefixLength`: the prefix size to ask for, 48–56, default `56`. |
| `static` | Uses a fixed WAN address and the prefix the ISP routes to it. | `address` (CIDR, e.g. `2001:db8:1::2/64`), `gateway`, `prefix` (e.g. `2001:db8:6648::/48`). |
| `none` | Takes no IPv6 on the WAN, so no zone gets IPv6. | — |

A dynamic prefix can change when the ISP renumbers; a static one does not. Where the ISP
offers a static prefix, use it: addresses, names and the firewall's trust in them stay the
same.

**The site prefix must be a `/56` or larger.** Zones are numbered within the first `/56` of
it, which gives room for 256 zones. With a smaller prefix (a `/60` or a `/64`) no zone gets
IPv6, and the network update says so.

## Which zones get IPv6

A zone carries IPv6 when all of these hold:

- it has an **`ipv6Subnet`** — its number within the site's `/56`, 0–255;
- it is `Active` or `Mandatory`;
- its type can carry IPv6. `Management`, `Overlay` and `WAN` zones never do: the control
  plane stays on IPv4.

Every zone that can carry IPv6 gets an `ipv6Subnet` by default: `network-manager add`
assigns one, and existing zones were given one when the site was updated. The number is the
zone's VLAN tag read as hexadecimal where that fits — VLAN 310 becomes `0x31` — so a zone's
network is easy to recognise:

| Zone | VLAN | `ipv6Subnet` | Network (site prefix `2001:db8:a210:8200::/56`) |
|---|---|---|---|
| `rossen` | 200 | 32 (`0x20`) | `2001:db8:a210:8220::/64` |
| `home` | 310 | 49 (`0x31`) | `2001:db8:a210:8231::/64` |
| `dmz` | 610 | 97 (`0x61`) | `2001:db8:a210:8261::/64` |

Where the VLAN tag does not fit, or the number is taken, the zone gets the lowest free number.

**To keep a zone IPv4-only**, remove its number:

```bash
network-manager modify <zone> --unset ipv6Subnet
module-manager update network
```

The number cannot be changed in place, because that renumbers every device in the zone. To
give a zone IPv6 again, add `"ipv6Subnet": <n>` to the zone in `config/zones.json` (a number
no other zone uses — `network-manager validate` checks it) and update the `network` module.

## Addresses and names

**The firewall** takes an address in each zone's `/64`: with a dynamic WAN an address formed
from its interface's MAC address, with a static WAN `::1`. It is the zone's IPv6 gateway, the
same role its `.1` IPv4 address has.

**Devices** configure their own address from the firewall's router advertisements (SLAAC).
There is no DHCPv6 server. The DNS server they are told about is the firewall.

**VMs** use the address formed from their MAC address (EUI-64), with no temporary addresses.
Proxmox fixes a VM's MAC address, so with a static prefix its IPv6 address never changes. A VM
that was running before IPv6 was turned on takes that address at its next start; until then
it has no IPv6 name.

**Names.** For every device that has a DHCP lease, the firewall computes the IPv6 address its
MAC address gives, checks that the device answers on it, and adds an AAAA record under the
same name. So `forgejo.rossen.internal` resolves to the VM's IPv4 and IPv6 addresses, with no
registration step. Phones and laptops use temporary (privacy) addresses and get no AAAA
record; they are clients, not services.

## What travels over IPv6

- **VM to VM, by name.** The zone rules and every module's firewall rules apply to both
  families. A module's address alias holds both of its addresses, so a rule that lets one VM
  reach another covers IPv6 as soon as the name has an AAAA record.
- **Clients to published names.** A name published through the reverse proxy (Caddy, on the
  firewall's DMZ address) has an AAAA record next to its A record inside the site: the DMZ
  interface's IPv6 address. A client with IPv6 reaches Caddy over IPv6, and Caddy terminates
  TLS there as it does over IPv4.
- **Caddy to the service.** Caddy reaches a service by its internal name and tries IPv6 first.
  A service that listens on IPv6 is reached over IPv6; one that listens on IPv4 only refuses
  the IPv6 attempt at once, and Caddy uses IPv4 with no delay.
- **The internet.** Devices in a zone with IPv6 reach the internet over IPv6 directly — there
  is no address translation for IPv6.

### Access lists and trusted proxies

A published service that is limited to some zones names them by their IPv4 networks. Each of
those zones' IPv6 networks is allowed beside it, so a client in an allowed zone is let in over
either family. A client from any other zone is refused over both.

Some services read the real client address from the reverse proxy, and trust that header only
from the proxy's own address (Nextcloud, Immich). Over IPv6 Caddy's requests come from the
firewall's IPv6 address in the service's zone. That one address is trusted beside the IPv4
rule; it is read from the firewall at every update of the module, so a changed prefix is
picked up by the next update.

### Services that stay on IPv4

| Service | Why |
|---|---|
| Euro-Office | Runs in a container whose port mapping forwards IPv4 only. |
| Open WebUI | Its server, asked to listen on IPv6, listens on IPv6 *only* and would refuse IPv4. |

Both are reached over IPv4: Caddy falls back for them at once, and a client reaching them
through Caddy may still use IPv6 to Caddy.

### Reaching Caddy from the internet

While the site runs IPv6 and the WAN holds an IPv6 address, the firewall lets the internet reach
Caddy on the WAN's IPv6 address, on the same two ports as over IPv4 (80 and 443) — and nothing
else. `ipv6-manager apply` reports the address:

```
ipv6: Caddy answers on the WAN over IPv6 at 2001:db8:978c::aba — the public AAAA for published names
```

Publish it as the AAAA record of each published name (or of the wildcard), next to the A
record. With a dynamic WAN the address can change when the ISP renumbers; a static WAN keeps it.
Switching IPv6 off makes the entry IPv4-only again.

## When IPv6 is not available

IPv4 is used wherever IPv6 does not work, without anyone having to notice:

- A device in a zone without IPv6 gets no IPv6 address and uses IPv4 for everything.
- A device whose IPv6 is broken — no route, or packets dropped — falls back to IPv4. With no
  route the fallback is immediate; when packets are dropped, browsers and most clients switch
  after about a quarter of a second.
- A service that does not listen on IPv6 is reached over IPv4, as above.

## Turning it off

Set `"ipv6": false` in `site.json` (or remove one zone's `ipv6Subnet`) and update the `network`
module. In that order:

1. The zone's router advertisements announce that the firewall is **no longer an IPv6 router**.
   Devices drop their IPv6 default route within seconds, and from then on use IPv4 without any
   delay.
2. The zone's IPv6 address and advertisements are removed, and its devices' AAAA records go
   with them.
3. For the whole site: the AAAA records of published names and the IPv6 entries of the access
   lists are removed, and the firewall's global *Allow IPv6* is switched off, which blocks all
   IPv6 through the firewall.

Devices keep their IPv6 address until it expires (about an hour), but without a route it is
not used. A service that trusts Caddy's IPv6 address keeps it until its next update; with no
IPv6 traffic that has no effect.

Turning IPv6 on again restores all of it in one network update.

## Commands

`ipv6-manager` carries out everything on the firewall; the network update calls it. It can be
run by hand:

| Command | What it does |
|---|---|
| `ipv6-manager apply --check-mode` | Shows what the network update would change: the WAN, each zone, the AAAA records of published names, the access lists. |
| `ipv6-manager apply` | Makes those changes. |
| `ipv6-manager status` | Whether the firewall allows IPv6. |
| `ipv6-manager gateway <zone>` | The firewall's IPv6 address in a zone — the source of Caddy's requests to services there. Exit code 3 when the zone has no IPv6. |

On a converged site `ipv6-manager apply --check-mode` ends with:

```
ipv6: the WAN and the zones match the declaration
ipv6: published names and access lists match the interfaces
```

## Current limitations

- **Inbound from the internet — the public AAAA is yours to set.** Caddy is reachable from the
  internet over IPv6 (see *Reaching Caddy from the internet* above), but TAPPaaS does not write
  public DNS: add the AAAA record wherever the public A record is kept. A module's port forward
  (`natRules`) is IPv4-only; nothing but Caddy is reachable from outside over IPv6.
- **Spoofed sources.** The firewall blocks IPv4 packets whose source is not in the zone they
  arrive from; it does not yet do the same for IPv6.
- **The WAN's IPv4.** `network.wan.ipv4` is part of the schema, but the network update does not
  yet apply it: the WAN's IPv4 is as installed.
