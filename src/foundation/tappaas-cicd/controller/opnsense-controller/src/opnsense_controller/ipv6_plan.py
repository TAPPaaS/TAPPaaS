"""The site's IPv6 on the firewall, as a plan (ADR-030).

From what the site declares — `site.json` `ipv6` and `network.wan.ipv6`, and each
zone's `ipv6Subnet` — and what the firewall holds now, the changes that bring the
firewall to the declaration. Pure: no firewall, no files; `ipv6_cli` reads the
inputs and carries the plan out.

The rules it applies:

* `ipv6: false` — no zone gets IPv6 and no zone advertises (D1). The WAN is left
  as it is; the global switch (*Allow IPv6*) is ipv6_cli's own step.
* The WAN: `dynamic` (default) is DHCPv6 with a delegated prefix of
  `prefixLength`; `static` is a fixed address, a gateway and a routed prefix;
  `none` takes no IPv6 (D2).
* The site prefix must be /56 or larger; zones live in its first /56 (D3).
* A zone gets IPv6 when it is Active or Mandatory, its type can carry it, and it
  has an `ipv6Subnet` (D4): *track the WAN* with that prefix ID (dynamic), or
  `::1` of its /64 (static) (D5).
* Every such zone gets a dnsmasq IPv6 range in `ra-names` mode: dnsmasq sends the
  router advertisements (SLAAC) and gives every host with a DHCPv4 lease an AAAA
  record. No zone interface has a radvd entry — two daemons must not advertise
  on one interface (D6, v0.3).
"""

from __future__ import annotations

import ipaddress
from dataclasses import dataclass, field

NO_IPV6_TYPES = frozenset({"Management", "Overlay", "WAN"})
ENABLED_STATES = frozenset({"active", "mandatory"})
DEFAULT_PREFIX_LENGTH = 56
ZONE_PREFIX_LENGTH = 56          # zones are numbered within the site's first /56
STATIC_GATEWAY_NAME = "WAN_GWv6_TAPPAAS"


def pd_len_code(prefix_length: int) -> str:
    """OPNsense's `dhcp6-ia-pd-len` for a delegated prefix: 64 minus its length."""
    return str(64 - prefix_length)


@dataclass(frozen=True)
class WanV6:
    mode: str                          # dynamic | static | none
    prefix_length: int = DEFAULT_PREFIX_LENGTH
    address: str = ""                  # static: "2001:db8::2/64"
    gateway: str = ""                  # static: "2001:db8::1"
    prefix: str = ""                   # static: "2001:db8:6648::/48"


def wan_v6(site: dict) -> WanV6:
    """The WAN's IPv6 as the site declares it; absent is dynamic, /56."""
    d = ((site.get("network") or {}).get("wan") or {}).get("ipv6") or {}
    return WanV6(
        mode=d.get("mode", "dynamic"),
        prefix_length=int(d.get("prefixLength", DEFAULT_PREFIX_LENGTH)),
        address=d.get("address", ""),
        gateway=d.get("gateway", ""),
        prefix=d.get("prefix", ""),
    )


def zone_network(site_prefix: str, subnet: int) -> ipaddress.IPv6Network:
    """A zone's /64: number `subnet` within the first /56 of the site prefix."""
    net = ipaddress.IPv6Network(site_prefix, strict=False)
    base = int(net.network_address) >> (128 - ZONE_PREFIX_LENGTH) << (128 - ZONE_PREFIX_LENGTH)
    return ipaddress.IPv6Network((base + (subnet << 64), 64))


@dataclass(frozen=True)
class ZoneV6:
    """What a zone interface should carry. `config` is its `config.xml` keys."""
    zone: str
    config: tuple[tuple[str, str], ...]


@dataclass
class Desired:
    wan: WanV6 | None                          # None: leave the WAN alone
    zones: dict[str, ZoneV6] = field(default_factory=dict)   # interface -> ZoneV6
    site_prefix: str = ""
    problems: list[str] = field(default_factory=list)


def desired_state(site: dict, zones: dict, interfaces: dict[str, str],
                  delegated_prefix: str | None) -> Desired:
    """What the firewall should hold. `interfaces` maps zone name -> interface;
    `delegated_prefix` is what the WAN holds now (dynamic mode), or None."""
    if not site.get("ipv6"):
        return Desired(wan=None)
    wan = wan_v6(site)
    out = Desired(wan=wan)
    if wan.mode == "none":
        return out

    prefix = wan.prefix if wan.mode == "static" else (delegated_prefix or "")
    if not prefix:
        out.problems.append("the WAN has no delegated prefix yet — no zone gets IPv6 until it does")
        return out
    try:
        plen = ipaddress.IPv6Network(prefix, strict=False).prefixlen
    except ValueError:
        out.problems.append(f"the site prefix '{prefix}' is not an IPv6 network")
        return out
    if plen > ZONE_PREFIX_LENGTH:
        out.problems.append(
            f"the site prefix {prefix} is smaller than /{ZONE_PREFIX_LENGTH}: zones need a "
            f"/{ZONE_PREFIX_LENGTH} or larger — ask the ISP for one (no zone gets IPv6)")
        return out
    out.site_prefix = prefix

    for name, z in zones.items():
        if name.startswith("_") or not isinstance(z, dict):
            continue
        subnet = z.get("ipv6Subnet")
        if (not isinstance(subnet, int) or isinstance(subnet, bool)
                or not 0 <= subnet <= 255):
            continue
        if z.get("type") in NO_IPV6_TYPES:
            continue
        if str(z.get("state", "")).lower() not in ENABLED_STATES:
            continue
        iface = interfaces.get(name)
        if not iface:
            out.problems.append(f"zone {name} has no interface on the firewall — no IPv6 for it")
            continue
        if wan.mode == "static":
            net = zone_network(prefix, subnet)
            cfg = (("ipaddrv6", str(net[1])), ("subnetv6", "64"))
        else:
            cfg = (("ipaddrv6", "track6"), ("track6-interface", "wan"),
                   ("track6-prefix-id", str(subnet)))
        out.zones[iface] = ZoneV6(zone=name, config=cfg)
    return out


# The config.xml keys a zone's IPv6 consists of — what "clear" removes.
ZONE_V6_KEYS = ("ipaddrv6", "subnetv6", "track6-interface", "track6-prefix-id")


@dataclass(frozen=True)
class Action:
    kind: str          # wan | zone-set | zone-clear | names-add | names-set | names-del | radvd-del
    target: str        # interface, or "wan"
    detail: dict

    def describe(self) -> str:
        return {
            "wan": "WAN IPv6",
            "zone-set": "zone IPv6",
            "zone-clear": "remove zone IPv6",
            "names-add": "start advertisements and AAAA names",
            "names-set": "correct advertisements and AAAA names",
            "names-del": "stop advertisements and AAAA names",
            "radvd-del": "remove the radvd entry",
        }[self.kind] + f" on {self.target}: {self.detail.get('summary', '')}".rstrip(": ")


def wan_config(wan: WanV6) -> dict[str, str | None]:
    """The WAN's `config.xml` IPv6 keys for the declared mode (None = remove)."""
    if wan.mode == "dynamic":
        return {"ipaddrv6": "dhcp6", "dhcp6-ia-pd-len": pd_len_code(wan.prefix_length),
                "subnetv6": None, "gatewayv6": None}
    if wan.mode == "static":
        iface = ipaddress.IPv6Interface(wan.address)
        return {"ipaddrv6": str(iface.ip), "subnetv6": str(iface.network.prefixlen),
                "gatewayv6": STATIC_GATEWAY_NAME, "dhcp6-ia-pd-len": None}
    return {"ipaddrv6": None, "subnetv6": None, "gatewayv6": None, "dhcp6-ia-pd-len": None}


def plan(desired: Desired, current_ifaces: dict[str, dict], zone_interfaces: set[str],
         ra_entries: list[dict], dhcp_ranges: list[dict] | None = None) -> list[Action]:
    """The changes from what the firewall holds to what is desired.

    `current_ifaces` is `config.xml` `interfaces/<id>` per interface (wan
    included); `zone_interfaces` the interfaces of the site's zones — the only
    ones this touches; `ra_entries` the radvd entries; `dhcp_ranges` the dnsmasq
    ranges (interface, start_addr, constructor, ra_mode).
    """
    dhcp_ranges = dhcp_ranges or []
    actions: list[Action] = []

    if desired.wan is not None:
        want = wan_config(desired.wan)
        cur = current_ifaces.get("wan", {})
        diff = {k: v for k, v in want.items() if (cur.get(k) or None) != v}
        if diff:
            actions.append(Action("wan", "wan", {
                "set": diff, "mode": desired.wan.mode,
                "gateway": desired.wan.gateway if desired.wan.mode == "static" else "",
                "summary": f"{desired.wan.mode} ({', '.join(f'{k}={v}' for k, v in diff.items())})",
            }))

    for iface in sorted(zone_interfaces):
        cur = current_ifaces.get(iface, {})
        want = desired.zones.get(iface)
        cur_v6 = {k: cur.get(k) for k in ZONE_V6_KEYS if cur.get(k)}
        if want is not None:
            target = dict(want.config)
            if cur_v6 != target:
                actions.append(Action("zone-set", iface, {
                    "zone": want.zone, "set": target, "device": cur.get("if", ""),
                    "summary": f"{want.zone} → " + ", ".join(f"{k}={v}" for k, v in target.items()),
                }))
        elif cur_v6:
            actions.append(Action("zone-clear", iface, {
                "device": cur.get("if", ""), "summary": "no ipv6Subnet, or IPv6 off"}))

    # dnsmasq IPv6 ranges (start "::") on zone interfaces — the zone's
    # advertisements and AAAA names. An IPv4 range is never touched.
    ranges = {r.get("interface"): r for r in dhcp_ranges
              if r.get("start_addr") == "::" and r.get("interface") in zone_interfaces}
    for iface in sorted(zone_interfaces):
        rng = ranges.get(iface)
        wanted = iface in desired.zones
        if wanted and rng is None:
            actions.append(Action("names-add", iface, {"summary": "ra-names (SLAAC, AAAA by name)"}))
        elif wanted and (rng.get("constructor") != iface or rng.get("ra_mode") != "ra-names"):
            actions.append(Action("names-set", iface, {"uuid": rng.get("uuid"),
                                                       "summary": "ra-names (SLAAC, AAAA by name)"}))
        elif not wanted and rng is not None:
            actions.append(Action("names-del", iface, {"uuid": rng.get("uuid")}))

    # radvd is not used for zones: any entry on a zone interface goes.
    for e in ra_entries:
        if e.get("interface") in zone_interfaces:
            actions.append(Action("radvd-del", e.get("interface"), {"uuid": e.get("uuid")}))
    return actions
