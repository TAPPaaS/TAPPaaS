"""DNS blocklists from site.json (#157): what Unbound's DNSBL should hold.

`site.json` `dnsBlocklists` (absent: none) names the lists — OPNsense's own
catalogue codes (`hgz013` hagezi threat intelligence Mini, `oisd1` OISD big, `ag`
AdGuard, ...) — the zones whose clients are filtered, and names that are never
blocked:

    "dnsBlocklists": {"lists": ["hgz013"], "zones": ["home", "guest"], "allow": ["example.org"]}

A code the firewall no longer offers (OPNsense drops lists from its catalogue,
as it did ThreatFox `atf` in 26.7.8) is skipped with a warning; the rest still
apply. The lists are refreshed daily by a cron job TAPPaaS owns while any
blocklist entry exists (`cron_plan`).

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
# OPNsense's configd action for "Update Unbound DNSBLs" (the cron's command).
CRON_COMMAND = "unbound dnsbl"
CRON_DESCRIPTION = "TAPPaaS: refresh the DNS blocklists"
# Daily, at a quiet hour: the lists are a few MB from their publishers.
CRON_SCHEDULE = {"minutes": "17", "hours": "4", "days": "*", "months": "*", "weekdays": "*"}


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
    nets: list[str] = []
    warnings: list[str] = []
    unknown = [x for x in lists if x not in known_lists]
    if unknown:
        lists = [x for x in lists if x in known_lists]
        if not lists:
            # Removing the entry would stop all blocking; keep it as it is.
            raise DnsblError(f"none of the blocklists {', '.join(unknown)} is offered by this "
                             f"firewall — it offers: {', '.join(sorted(known_lists))}")
        warnings.append(f"skipped {', '.join(unknown)}: not offered by this firewall "
                        "(remove from site.json dnsBlocklists.lists)")
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


def cron_plan(jobs: list[dict], want: bool) -> tuple[bool, list[str]]:
    """(add ours?, uuids of ours to delete) for the daily refresh job.

    `jobs` are cron searchJobs rows. Wanted while any blocklist entry exists.
    An operator's own refresh job counts: TAPPaaS then keeps none of its own.
    One of ours that was disabled or rescheduled is replaced.
    """
    ours = [j for j in jobs if (j.get("description") or "") == CRON_DESCRIPTION]
    theirs = [j for j in jobs if (j.get("description") or "") != CRON_DESCRIPTION
              and str(j.get("enabled", "1")) == "1" and _is_refresh(j.get("command"))]
    if not want or theirs:
        return False, [j.get("uuid", "") for j in ours]
    good = [j for j in ours if _as_wanted(j)]
    keep = good[0] if good else None
    return keep is None, [j.get("uuid", "") for j in ours if j is not keep]


def cron_job() -> dict:
    """The job TAPPaaS writes (cron addJob's `job`)."""
    return {"enabled": "1", **CRON_SCHEDULE, "command": CRON_COMMAND, "parameters": "",
            "description": CRON_DESCRIPTION}


def _as_wanted(job: dict) -> bool:
    return (str(job.get("enabled", "")) == "1" and _is_refresh(job.get("command"))
            and all(str(job.get(k, "")) == v for k, v in CRON_SCHEDULE.items()))


def _is_refresh(command) -> bool:
    """A cron row's command, as the key or as OPNsense's label for it."""
    c = str(command or "").strip().lower()
    return c == CRON_COMMAND or c == "update unbound dnsbls"
