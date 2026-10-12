"""IPv6 next to IPv4 for what TAPPaaS publishes inside the site (ADR-030 D9).

Published names and Caddy's access lists are written in IPv4: a name's
split-horizon A record points at a firewall interface (the DMZ gateway, where
Caddy listens), and an access list names zones by their IPv4 networks. When the
site has IPv6, each of those has an IPv6 counterpart on the same interface:

* an A record that points at an interface's IPv4 address gets an AAAA record
  for that interface's global IPv6 address;
* an access-list entry that is an interface's IPv4 network gets that
  interface's global IPv6 network next to it.

The counterparts are read from the firewall's interfaces, not computed from a
prefix, so a static WAN, a delegated prefix that changes and IPv6 switched off
are all the same case: what the interfaces hold now. The planning here is pure;
`read_interfaces` is the one call to the firewall.
"""

from __future__ import annotations

import ipaddress
from dataclasses import dataclass, field

# The description an AAAA record written here carries, after the A record's own:
# how ours are told apart from an operator's.
AAAA_MARK = " [IPv6]"


@dataclass(frozen=True)
class IfaceAddr:
    identifier: str
    v4: ipaddress.IPv4Interface | None
    v6: tuple[ipaddress.IPv6Interface, ...] = ()       # global addresses only


def parse_overview(rows: list[dict]) -> list[IfaceAddr]:
    """Interfaces from `interfaces/overview/interfacesInfo` rows."""
    out = []
    for r in rows:
        v4 = None
        for a in r.get("ipv4") or []:
            try:
                v4 = ipaddress.IPv4Interface(a.get("ipaddr", ""))
                break
            except ValueError:
                continue
        v6 = []
        for a in r.get("ipv6") or []:
            try:
                i = ipaddress.IPv6Interface(a.get("ipaddr", ""))
            except ValueError:
                continue
            if i.ip.is_global:
                v6.append(i)
        out.append(IfaceAddr(r.get("identifier", ""), v4, tuple(v6)))
    return out


def read_interfaces(client) -> list[IfaceAddr]:
    """The firewall's interfaces and their addresses (an oxl Client)."""
    r = client.run_module("raw", params={
        "module": "interfaces", "controller": "overview",
        "command": "interfacesInfo", "action": "get"})
    return parse_overview(((r.get("result") or {}).get("response") or {}).get("rows") or [])


def _v6_networks(cidr: str, ifaces: list[IfaceAddr]) -> list[str]:
    try:
        net = ipaddress.IPv4Network(cidr, strict=False)
    except ValueError:
        return []
    return [str(a.network) for i in ifaces if i.v4 is not None and i.v4.network == net
            for a in i.v6]


def with_v6(client_ips: list[str], ifaces: list[IfaceAddr]) -> list[str]:
    """`client_ips` plus the IPv6 network of every zone named by its IPv4 one."""
    out = list(client_ips)
    for c in client_ips:
        for n in _v6_networks(c, ifaces):
            if n not in out:
                out.append(n)
    return out


def derived_v6(client_ips: list[str], ifaces: list[IfaceAddr]) -> list[str]:
    """An access list whose IPv6 part is entirely derived: its non-IPv6 entries
    plus their counterparts. Any IPv6 entry it held before is replaced."""
    base = [c for c in client_ips if ":" not in c]
    return with_v6(base, ifaces)


def v6_for(ip: str, ifaces: list[IfaceAddr]) -> str | None:
    """The global IPv6 address of the interface whose IPv4 address is `ip`."""
    for i in ifaces:
        if i.v4 is not None and str(i.v4.ip) == ip and i.v6:
            return str(i.v6[0].ip)
    return None


def v6_on_network(cidr: str, ifaces: list[IfaceAddr]) -> str | None:
    """The firewall's global IPv6 address on the interface whose IPv4 network is
    `cidr` — in a zone, the address Caddy and the gateway use over IPv6."""
    try:
        net = ipaddress.IPv4Network(cidr, strict=False)
    except ValueError:
        return None
    for i in ifaces:
        if i.v4 is not None and i.v4.network == net and i.v6:
            return str(i.v6[0].ip)
    return None


@dataclass
class AaaaPlan:
    add: list[dict] = field(default_factory=list)      # {hostname, domain, server, description}
    delete: list[dict] = field(default_factory=list)   # rows to remove (uuid, hostname, domain)

    def __bool__(self) -> bool:
        return bool(self.add or self.delete)


def _key(r: dict) -> tuple[str, str]:
    return ((r.get("hostname") or "").lower(), (r.get("domain") or "").lower().rstrip("."))


def aaaa_plan(rows: list[dict], ifaces: list[IfaceAddr],
              only: tuple[str, str] | None = None) -> AaaaPlan:
    """The AAAA records the A records that point at the firewall call for.

    `rows` are Unbound host overrides. An A record whose address is an
    interface's IPv4 address gets an AAAA, marked as ours, for that interface's
    IPv6 address; ours that are wrong, duplicated or no longer called for go. An
    AAAA the operator wrote (unmarked) is left alone, and its name gets none of
    ours. `only` limits the plan to one (hostname, domain).
    """
    if only is not None:
        only = (only[0].lower(), only[1].lower().rstrip("."))
    want: dict[tuple[str, str], dict] = {}
    for r in rows:
        if str(r.get("rr", "")) != "A":
            continue
        v6 = v6_for(str(r.get("server", "")), ifaces)
        if v6:
            want[_key(r)] = {"hostname": r.get("hostname", ""), "domain": r.get("domain", ""),
                             "server": v6,
                             "description": (r.get("description") or _fqdn(r)) + AAAA_MARK}
    theirs = {_key(r) for r in rows
              if str(r.get("rr", "")) == "AAAA" and not str(r.get("description", "")).endswith(AAAA_MARK)}
    out = AaaaPlan()
    kept: set[tuple[str, str]] = set()
    for r in rows:
        if str(r.get("rr", "")) != "AAAA" or not str(r.get("description", "")).endswith(AAAA_MARK):
            continue
        k = _key(r)
        if only is not None and k != only:
            continue
        w = want.get(k)
        if w and k not in theirs and k not in kept and str(r.get("server", "")) == w["server"]:
            kept.add(k)
        else:
            out.delete.append(r)
    for k, w in sorted(want.items()):
        if (only is None or k == only) and k not in kept and k not in theirs:
            out.add.append(w)
    return out


def _fqdn(r: dict) -> str:
    h, d = r.get("hostname") or "", r.get("domain") or ""
    return f"{h}.{d}" if h else d
