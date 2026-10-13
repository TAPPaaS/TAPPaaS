"""DNS blocklists from site.json (#157): what Unbound's DNSBL should hold.

`site.json` `dnsBlocklists` (absent: none) names the lists — OPNsense's own
catalogue codes (`atf` abuse.ch ThreatFox, `hgz011` hagezi threat feeds, `oisd1`,
...) — the zones whose clients are filtered, and names that are never blocked:

    "dnsBlocklists": {"lists": ["atf", "hgz011"], "zones": ["home", "guest"], "allow": ["example.org"]}

TAPPaaS owns the DNSBL entries described `TAPPaaS: site blocklists…`; entries
an operator adds by hand are left alone. OPNsense requires one entry's networks
to share a family and a prefix length, so the zones' IPv4 networks are one entry
and their IPv6 networks another (one more per other prefix length). Filtering applies to the listed zones' networks,
IPv4 and IPv6 — so a service zone, whose modules fetch updates and models,
keeps an unfiltered resolver unless it is listed. No zones listed: every client.
A blocked name answers NXDOMAIN.

Pure: the caller reads site.json, the zones, the interfaces and the firewall.
"""

from __future__ import annotations

import ipaddress
from dataclasses import dataclass, field

DESCRIPTION = "TAPPaaS: site blocklists"


class DnsblError(ValueError):
    """A declaration that cannot be applied as written."""


@dataclass
class Desired:
    lists: list[str]
    allow: list[str]
    source_nets: list[str]
    warnings: list[str] = field(default_factory=list)

    def groups(self) -> dict[str, list[str]]:
        """description → its networks: one group per family and prefix length."""
        if not self.source_nets:
            return {DESCRIPTION: []}
        out: dict[str, list[str]] = {}
        for n in self.source_nets:
            net = ipaddress.ip_network(n, strict=False)
            key = f"{DESCRIPTION} (IPv{net.version} /{net.prefixlen})"
            out.setdefault(key, []).append(n)
        return out

    def items(self) -> dict[str, dict]:
        """description → the entry TAPPaaS writes."""
        return {d: {
            "enabled": "1",
            "type": ",".join(self.lists),
            "allowlists": ",".join(self.allow),
            "source_nets": ",".join(nets),
            "nxdomain": "1",
            "description": d,
        } for d, nets in self.groups().items()}


def desired(site: dict, zones: dict, known_lists: set[str], v6_for_zone) -> Desired | None:
    """The entry site.json asks for, or None (no blocklists).

    `v6_for_zone(cidr)` gives a zone network's IPv4 and IPv6 networks.
    """
    decl = site.get("dnsBlocklists")
    if decl in (None, {}, []):
        return None
    if not isinstance(decl, dict):
        raise DnsblError("dnsBlocklists must be an object: {lists, zones, allow}")
    lists = [str(x) for x in decl.get("lists") or []]
    if not lists:
        return None
    unknown = [x for x in lists if x not in known_lists]
    if unknown:
        raise DnsblError(f"unknown blocklist(s) {', '.join(unknown)} — this firewall offers: "
                         f"{', '.join(sorted(known_lists))}")
    nets: list[str] = []
    warnings: list[str] = []
    for z in decl.get("zones") or []:
        zd = zones.get(z)
        if not isinstance(zd, dict) or not zd.get("ip"):
            raise DnsblError(f"dnsBlocklists zone '{z}' is not a zone with an ip in zones.json")
        if str(zd.get("state", "")) not in ("Active", "Mandatory"):
            warnings.append(f"zone '{z}' is not active — its network is filtered once it is")
        for n in v6_for_zone(zd["ip"]):
            if n not in nets:
                nets.append(n)
    allow = [str(x).strip() for x in decl.get("allow") or [] if str(x).strip()]
    return Desired(sorted(dict.fromkeys(lists)), sorted(dict.fromkeys(allow)), nets, warnings)


def _selected(v) -> list[str]:
    """An OPNsense field as the list of its values: an option/CSV/network field
    comes as {key: {value, selected}}, a plain one as "a,b"."""
    if isinstance(v, dict):
        return sorted(k for k, o in v.items() if isinstance(o, dict) and str(o.get("selected")) == "1" and k)
    if isinstance(v, list):
        return sorted(str(x) for x in v if str(x))
    return sorted(x for x in str(v or "").split(",") if x)


def current_view(item: dict) -> dict:
    """The fields TAPPaaS sets, normalised, from a getDnsbl answer."""
    return {
        "enabled": str(item.get("enabled", "")),
        "type": _selected(item.get("type")),
        "allowlists": _selected(item.get("allowlists")),
        "source_nets": _selected(item.get("source_nets")),
        "nxdomain": str(item.get("nxdomain", "")),
    }


def is_ours(description: str) -> bool:
    return description == DESCRIPTION or description.startswith(DESCRIPTION + " (")


def needs_change(item: dict, have: dict) -> bool:
    """Does the entry on the firewall differ from the one TAPPaaS would write?"""
    split = lambda v: sorted(x for x in v.split(",") if x)  # noqa: E731
    return current_view(have) != {
        "enabled": "1",
        "type": split(item["type"]),
        "allowlists": split(item["allowlists"]),
        "source_nets": split(item["source_nets"]),
        "nxdomain": "1",
    }
