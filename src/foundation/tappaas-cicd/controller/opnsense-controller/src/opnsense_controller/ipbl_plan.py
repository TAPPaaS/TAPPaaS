"""IP blocklists from site.json: what the firewall should block, both ways.

`site.json` `ipBlocklists` (absent or empty: none) lists the URLs of address
lists their publishers maintain — Spamhaus DROP is the usual one:

    "ipBlocklists": ["https://www.spamhaus.org/drop/drop.txt"]

Each URL becomes an OPNsense URL-table alias the firewall refreshes daily
(`tappaas_ipbl_<hash of the URL>`, so reordering the list renames nothing). One
network alias, `tappaas_ipblocklists`, nests them, and two rules block it:

- arriving on the WAN, from an address on a list, ahead of every published
  service, port forward and other WAN rule;
- leaving any zone, to an address on a list, ahead of the module and zone
  passes (the zones' interfaces in one rule).

Both rules sit at sequence 960, before the zones' own protective rules (970+).
TAPPaaS owns the aliases and the two rules by name and description; none of
them is anyone else's.

Pure: the caller reads site.json and the zones, and talks to the firewall.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from urllib.parse import urlparse

ALIAS_PREFIX = "tappaas_ipbl_"
GROUP_ALIAS = "tappaas_ipblocklists"
WAN_RULE = "tappaas-ipbl: from the IP blocklists, on the WAN"
ZONES_RULE = "tappaas-ipbl: to the IP blocklists, from the zones"
SEQUENCE = 960
REFRESH_DAYS = "1"
# The zones whose traffic leaves through the firewall's rules: the Active and
# Mandatory ones TAPPaaS writes rules for, and mgmt. The WAN is the other rule;
# the overlays (admin VPN, NetBird, the satellite's edge) have no zone interface.
ZONE_STATES = ("Active", "Mandatory")
EXTRA_ZONE_TYPES = ("Management",)


class IpblError(ValueError):
    """A declaration that cannot be applied as written."""


@dataclass
class Desired:
    urls: list[str]
    zones: list[str]

    def aliases(self) -> dict[str, str]:
        """alias name → its URL."""
        return {alias_name(u): u for u in self.urls}


def alias_name(url: str) -> str:
    """The URL-table alias for `url`: within OPNsense's 32 characters."""
    return ALIAS_PREFIX + hashlib.sha256(url.encode()).hexdigest()[:10]


def is_ours(alias: str) -> bool:
    return alias == GROUP_ALIAS or alias.startswith(ALIAS_PREFIX)


def desired(site: dict, zones: dict) -> Desired | None:
    """The blocklists site.json asks for, or None (block nothing)."""
    decl = site.get("ipBlocklists")
    if decl in (None, [], ""):
        return None
    if not isinstance(decl, list):
        raise IpblError("ipBlocklists must be a list of URLs")
    urls: list[str] = []
    for u in decl:
        u = str(u).strip()
        p = urlparse(u)
        if p.scheme not in ("http", "https") or not p.netloc or any(c.isspace() for c in u):
            raise IpblError(f"ipBlocklists: '{u}' is not an http(s) URL")
        if u not in urls:
            urls.append(u)
    if not urls:
        return None
    return Desired(urls, filtered_zones(zones))


def filtered_zones(zones: dict) -> list[str]:
    """The zones whose outbound traffic the zones rule covers, sorted."""
    out = []
    for name, z in zones.items():
        if name.startswith("_") or not isinstance(z, dict):
            continue
        if z.get("type") == "WAN":
            continue
        if str(z.get("state", "")) in ZONE_STATES or z.get("type") in EXTRA_ZONE_TYPES:
            out.append(name)
    return sorted(out)


def urltable_item(name: str, url: str) -> dict:
    """The alias TAPPaaS writes for one list (firewall alias addItem's `alias`)."""
    return {"enabled": "1", "name": name, "type": "urltable", "content": url,
            "updatefreq": REFRESH_DAYS, "description": f"TAPPaaS: IP blocklist {url}"}


def stale_aliases(existing: list[str], want: Desired | None) -> list[str]:
    """The per-URL aliases of ours site.json no longer names (the group last)."""
    keep = set(want.aliases()) if want else set()
    stale = sorted(a for a in existing if a.startswith(ALIAS_PREFIX) and a not in keep)
    if want is None and GROUP_ALIAS in existing:
        # The group goes first: a nested alias cannot be deleted while the
        # group still holds it.
        stale.insert(0, GROUP_ALIAS)
    return stale
