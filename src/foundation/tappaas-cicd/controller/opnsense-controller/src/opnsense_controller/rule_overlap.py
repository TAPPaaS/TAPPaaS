"""Overlap analysis of the firewall's rule set (#160).

Every TAPPaaS rule is `quick` on the interface where traffic arrives, so on one
interface the first rule that matches decides. Given the rules with their
addresses resolved — interface networks, alias contents, inverted sources — this
finds where that order makes a rule meaningless or lets order decide silently:

* **shadowed** — an earlier rule matches everything this one does, so it never
  decides anything. A pass behind a block is traffic someone meant to allow
  that is dropped (#386); a block behind a pass is a block that never blocks.
* **redundant** — a pass whose traffic a later, broader pass lets through
  anyway, with no block in between that would stop it (#256).
* **conflict** — part of a module rule's traffic is decided by an earlier rule
  of the other action; which one wins for that traffic depends on order alone.

Pure: the caller resolves names to addresses (`Resolver`); nothing here talks to
the firewall. Read-only by design — it reports, it never changes a rule.

The geometry: a rule matches a set of (family, protocol, source, destination,
destination port). Addresses are sets of integer intervals per family, ports are
intervals in 0–65535, protocols a set (`*` for any). Rule A *contains* rule B when
every part of B's set lies within A's; they *intersect* when some packet matches
both. Source ports are not compared — TAPPaaS never sets them.
"""

from __future__ import annotations

import ipaddress
from dataclasses import dataclass, field
from typing import Callable, Iterable

FAMILIES = (4, 6)
_UNIVERSE = {4: (0, 2**32 - 1), 6: (0, 2**128 - 1)}
ANY_PROTO = "*"
PORTLESS = {"icmp", "ipv6-icmp"}


# ── Interval sets ─────────────────────────────────────────────────────

def _norm(iv: Iterable[tuple[int, int]]) -> tuple[tuple[int, int], ...]:
    out: list[list[int]] = []
    for lo, hi in sorted(iv):
        if out and lo <= out[-1][1] + 1:
            out[-1][1] = max(out[-1][1], hi)
        else:
            out.append([lo, hi])
    return tuple((a, b) for a, b in out)


def _intersect(a, b) -> tuple[tuple[int, int], ...]:
    out, i, j = [], 0, 0
    while i < len(a) and j < len(b):
        lo, hi = max(a[i][0], b[j][0]), min(a[i][1], b[j][1])
        if lo <= hi:
            out.append((lo, hi))
        if a[i][1] < b[j][1]:
            i += 1
        else:
            j += 1
    return tuple(out)


def _complement(a, universe: tuple[int, int]) -> tuple[tuple[int, int], ...]:
    out, cur = [], universe[0]
    for lo, hi in a:
        if lo > cur:
            out.append((cur, lo - 1))
        cur = max(cur, hi + 1)
    if cur <= universe[1]:
        out.append((cur, universe[1]))
    return tuple(out)


def _subset(a, b) -> bool:
    """Every interval of a lies within b."""
    return _intersect(a, b) == _norm(a)


@dataclass(frozen=True)
class Addresses:
    """A set of addresses, per family: family -> normalised intervals."""
    by_family: tuple[tuple[int, tuple[tuple[int, int], ...]], ...]

    @staticmethod
    def of(networks: Iterable[str]) -> "Addresses":
        acc: dict[int, list[tuple[int, int]]] = {4: [], 6: []}
        for n in networks:
            net = ipaddress.ip_network(n, strict=False)
            acc[net.version].append((int(net.network_address), int(net.broadcast_address)))
        return Addresses(tuple((f, _norm(acc[f])) for f in FAMILIES))

    @staticmethod
    def any() -> "Addresses":
        return Addresses(tuple((f, (_UNIVERSE[f],)) for f in FAMILIES))

    def get(self, family: int):
        return dict(self.by_family).get(family, ())

    def inverted(self) -> "Addresses":
        return Addresses(tuple((f, _complement(self.get(f), _UNIVERSE[f])) for f in FAMILIES))


# ── Rules ─────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class Match:
    interface: str
    families: frozenset[int]
    protocols: frozenset[str]
    source: Addresses
    destination: Addresses
    ports: tuple[tuple[int, int], ...]           # destination ports

    def _ports_of(self, protos):
        # A rule only for protocols without ports matches every "port".
        return ((0, 65535),) if protos and protos <= PORTLESS else self.ports

    def contains(self, other: "Match") -> bool:
        if self.interface != other.interface:
            return False
        if ANY_PROTO not in self.protocols and (
                ANY_PROTO in other.protocols or not other.protocols <= self.protocols):
            return False
        if not _subset(other._ports_of(other.protocols), self._ports_of(self.protocols)):
            return False
        for f in other.families:
            if not other.source.get(f) and not other.destination.get(f):
                continue
            if f not in self.families:
                return False
            if not (_subset(other.source.get(f), self.source.get(f))
                    and _subset(other.destination.get(f), self.destination.get(f))):
                return False
        return True

    def intersects(self, other: "Match") -> bool:
        if self.interface != other.interface:
            return False
        if ANY_PROTO not in self.protocols and ANY_PROTO not in other.protocols \
                and not self.protocols & other.protocols:
            return False
        if not _intersect(self._ports_of(self.protocols), other._ports_of(other.protocols)):
            return False
        return any(_intersect(self.source.get(f), other.source.get(f))
                   and _intersect(self.destination.get(f), other.destination.get(f))
                   for f in self.families & other.families)


@dataclass(frozen=True)
class Rule:
    description: str
    sequence: int
    action: str                  # pass | block
    match: Match

    @property
    def is_module(self) -> bool:
        return self.description.startswith(("tappaas-module:", "tappaas-svcdep:"))


@dataclass(frozen=True)
class Finding:
    kind: str                    # shadowed | redundant | conflict
    rule: Rule                   # the rule the finding is about
    by: Rule                     # the rule that causes it
    interface: str

    def text(self) -> str:
        r, b = self.rule, self.by
        if self.kind == "shadowed":
            what = ("a pass that never passes" if r.action == "pass" else "a block that never blocks"
                    ) if r.action != b.action else f"a {r.action} that never matches first"
            return (f"{r.description} (seq {r.sequence}) is {what}: {b.description} "
                    f"(seq {b.sequence}, {b.action}) matches all of its traffic first")
        if self.kind == "redundant":
            return (f"{r.description} (seq {r.sequence}) is redundant: {b.description} "
                    f"(seq {b.sequence}) passes all of its traffic too, with no block between them")
        return (f"{r.description} (seq {r.sequence}, {r.action}) and {b.description} "
                f"(seq {b.sequence}, {b.action}) overlap in part — for the shared traffic "
                f"the earlier one decides")


def analyse(rules: Iterable[Rule]) -> list[Finding]:
    """Findings for one rule set (any number of interfaces)."""
    by_iface: dict[str, list[Rule]] = {}
    for r in rules:
        by_iface.setdefault(r.match.interface, []).append(r)
    findings: list[Finding] = []
    for iface, rs in sorted(by_iface.items()):
        rs = sorted(rs, key=lambda r: r.sequence)
        for i, b in enumerate(rs):
            earlier = rs[:i]
            # Shadowed: the first earlier rule that contains it decides all of it.
            shadow = next((a for a in earlier if a.match.contains(b.match)), None)
            if shadow is not None:
                findings.append(Finding("shadowed", b, shadow, iface))
                continue
            # Conflict: part of a module rule's traffic is decided by an earlier
            # rule of the other action. (A module pass ahead of a zone's later
            # block is the design — a pinhole is the exception to that block.)
            if b.is_module:
                for a in earlier:
                    if a.action != b.action and a.match.intersects(b.match):
                        findings.append(Finding("conflict", b, a, iface))
            # Redundant: a module pass that a later pass covers, nothing blocking between.
            if b.action == "pass" and b.is_module:
                for j in range(i + 1, len(rs)):
                    c = rs[j]
                    if c.action == "block" and c.match.intersects(b.match):
                        break
                    if c.action == "pass" and c.match.contains(b.match):
                        findings.append(Finding("redundant", b, c, iface))
                        break
    return findings


# ── From OPNsense rules ───────────────────────────────────────────────

Resolver = Callable[[str], "list[str] | None"]
"""Name -> its networks (CIDRs, both families); None when it cannot be resolved."""


def _protocols(value: str | None) -> frozenset[str]:
    v = (value or "").strip().lower()
    if v in ("", "any"):
        return frozenset({ANY_PROTO})
    if v in ("tcp/udp", "tcp-udp"):
        return frozenset({"tcp", "udp"})
    return frozenset({v})


def _ports(value: str | None) -> tuple[tuple[int, int], ...] | None:
    v = (value or "").strip()
    if not v or v.lower() == "any":
        return ((0, 65535),)
    out = []
    for part in v.split(","):
        part = part.strip()
        lo, _, hi = part.replace(":", "-").partition("-")
        if not lo.isdigit() or (hi and not hi.isdigit()):
            return None                     # a port alias: not analysed
        out.append((int(lo), int(hi or lo)))
    return _norm(out)


def _families(ip_protocol: str | None) -> frozenset[int]:
    v = (ip_protocol or "inet").lower()
    return frozenset({4, 6}) if v == "inet46" else frozenset({6}) if v == "inet6" else frozenset({4})


def _address(name: str, invert: bool, resolve: Resolver) -> Addresses | None:
    if not name or name.lower() == "any":
        a = Addresses.any()
    else:
        try:
            a = Addresses.of([name])
        except ValueError:
            nets = resolve(name)
            if nets is None:
                return None
            a = Addresses.of(nets)
    return a.inverted() if invert else a


def from_rule_info(info, resolve: Resolver) -> list[Rule] | None:
    """A FirewallRuleInfo as analysable rules (one per interface); None if a name
    in it cannot be resolved. Disabled rules and non-quick rules are left out."""
    if not info.enabled or not getattr(info, "quick", True):
        return []
    action = (info.action or "").lower()
    if action not in ("pass", "block", "reject"):
        return []
    src = _address(info.source_net, getattr(info, "source_invert", False), resolve)
    dst = _address(info.destination_net, getattr(info, "destination_invert", False), resolve)
    ports = _ports(info.destination_port)
    if src is None or dst is None or ports is None:
        return None
    out = []
    for iface in [i.strip() for i in (info.interface or "").split(",") if i.strip()]:
        out.append(Rule(
            description=info.description or info.uuid,
            sequence=info.sequence or 0,
            action="pass" if action == "pass" else "block",
            match=Match(iface, _families(info.ip_protocol), _protocols(info.protocol),
                        src, dst, ports),
        ))
    return out


@dataclass
class Report:
    findings: list[Finding] = field(default_factory=list)
    analysed: int = 0
    unresolved: list[str] = field(default_factory=list)   # descriptions left out


def report(infos: Iterable, resolve: Resolver, managed: Callable[[str], bool]) -> Report:
    """Analyse the rules `managed` selects (by description)."""
    rep = Report()
    rules: list[Rule] = []
    for i in infos:
        if not managed(i.description or ""):
            continue
        rs = from_rule_info(i, resolve)
        if rs is None:
            rep.unresolved.append(i.description)
            continue
        rules.extend(rs)
        rep.analysed += 1 if rs else 0
    rep.findings = analyse(rules)
    return rep
