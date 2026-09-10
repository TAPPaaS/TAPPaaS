"""Zone-gate policy for source NAT (ADR-016 D1/D2).

A module *requests* masquerade; the destination zone *grants* it. This module
holds the arithmetic between the two, deliberately as pure functions over
plain data: no OPNsense connection is needed to decide what a module is
entitled to, so the decision is testable on its own and the same answer comes
back whether or not a firewall is reachable.

The gate mirrors ``pinhole-allowed-from``, which ``rules_manager`` enforces the
same way and in the same layer. Masquerading into a zone costs *every* device
in it its client attribution — the device, and anything reading its logs, sees
the zone gateway instead of the real client — so the zone, not the module, is
the right place for the consent.

Three rules from the ADR, and R3 is the one that matters most:

* **R1** — ``snat-allowed-from`` MUST be a subset of ``pinhole-allowed-from``.
  Masquerade without reachability is meaningless, and permitting it separately
  would make source NAT a second, weaker way into a zone.
* **R2** — no ``snat-allowed-from`` means no masquerade. Opt-in, always.
* **R3** — a request naming a zone outside the gate is **refused, not
  trimmed**. Silently narrowing it would hand back a half-working masquerade
  and report success, which is precisely how #239 stayed broken for weeks.
"""

import json
from dataclasses import dataclass, field
from pathlib import Path

# Where a module's snat request lives inside its deployed JSON. Pattern A
# (#207) nests a service's fields under its coordinate; a top-level spelling is
# accepted as a fallback the same way the other services accept one.
SERVICE_COORDINATE = "network:snat"

# Description prefix: idempotency key and ownership marker in one, matching
# the scheme rules_manager ("tappaas-module:") and nat_manager ("TAPPaaS: ")
# already use. Deliberately NOT the Community module's "tappaas-nat:" — those
# rules predate the zone gate and are reported as unowned rather than adopted.
DESC_PREFIX = "tappaas-snat:"


@dataclass
class ZoneSpec:
    """Minimal zone view used by the source-NAT policy."""

    name: str
    ip_network: str
    bridge: str
    vlan_tag: int
    pinhole_allowed_from: list[str] = field(default_factory=list)
    snat_allowed_from: list[str] = field(default_factory=list)


@dataclass
class SnatRequest:
    """What a module asks for."""

    module: str
    zone0: str
    snat_from: list[str] = field(default_factory=list)
    reason: str = ""


@dataclass
class GateResult:
    """The outcome of intersecting a request with the zone's grant."""

    allowed: list[str] = field(default_factory=list)
    refused: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        """True when the request can proceed in full.

        A refusal is not a partial success: R3 makes the whole request fail,
        so a caller never has to decide whether a half-applied gate is good
        enough.
        """
        return not self.refused and not self.errors


def load_zones(path: Path) -> dict[str, ZoneSpec]:
    """Load zones.json into a name->ZoneSpec map."""
    with open(path) as f:
        data = json.load(f)
    result: dict[str, ZoneSpec] = {}
    for name, entry in data.items():
        # Keys beginning with '_' (e.g. _README) are documentation, not zones.
        if name.startswith("_") or not isinstance(entry, dict):
            continue
        result[name] = ZoneSpec(
            name=name,
            ip_network=entry.get("ip", "") or "",
            bridge=entry.get("bridge", "lan") or "lan",
            vlan_tag=int(entry.get("vlantag", 0) or 0),
            pinhole_allowed_from=entry.get("pinhole-allowed-from", []) or [],
            snat_allowed_from=entry.get("snat-allowed-from", []) or [],
        )
    return result


def load_request(config_dir: Path, module: str) -> SnatRequest:
    """Read a module's deployed JSON into a SnatRequest.

    Accepts the field under ``config."network:snat"`` (Pattern A) and falls
    back to the top level, so a module authored either way is understood.
    """
    path = Path(config_dir) / f"{module}.json"
    if not path.is_file():
        raise FileNotFoundError(f"module config not found: {path}")
    with open(path) as f:
        data = json.load(f)

    nested = (data.get("config", {}) or {}).get(SERVICE_COORDINATE, {}) or {}

    def pick(key: str, default):
        value = nested.get(key, data.get(key, default))
        return default if value is None else value

    return SnatRequest(
        module=data.get("vmname", module),
        zone0=data.get("zone0", "") or "",
        snat_from=list(pick("snatFrom", []) or []),
        reason=str(pick("snatReason", "") or ""),
    )


def rule_description(module: str, from_zone: str, zone0: str) -> str:
    """Canonical description for one masquerade rule.

    Both the idempotency key and the ownership marker; nothing else may write
    a rule with this prefix, and anything found carrying it that no module
    declares is reported as unowned rather than deleted.
    """
    return f"{DESC_PREFIX}{module}:{from_zone}->{zone0}"


def validate_zone_gate(zones: dict[str, ZoneSpec]) -> list[str]:
    """Check R1 across every zone: snat-allowed-from subset of pinhole-allowed-from.

    Returns one message per violation; an empty list means the file is
    consistent. Offered separately from the apply path so ``validate`` can run
    it offline, before anything is pushed.
    """
    problems: list[str] = []
    for zone in zones.values():
        for src in zone.snat_allowed_from:
            if src not in zones:
                problems.append(
                    f"zone '{zone.name}': snat-allowed-from names '{src}', "
                    f"which is not a zone in zones.json"
                )
            elif src not in zone.pinhole_allowed_from:
                problems.append(
                    f"zone '{zone.name}': snat-allowed-from includes '{src}' but "
                    f"pinhole-allowed-from does not (R1). Masquerade without "
                    f"reachability is meaningless — add '{src}' to "
                    f"{zone.name}.pinhole-allowed-from, or remove it from "
                    f"snat-allowed-from."
                )
    return problems


def apply_gate(request: SnatRequest, zones: dict[str, ZoneSpec]) -> GateResult:
    """Intersect a module's request with its destination zone's grant."""
    result = GateResult()

    if not request.zone0:
        result.errors.append(f"{request.module}: no zone0 — cannot place a source-NAT rule")
        return result

    dest = zones.get(request.zone0)
    if dest is None:
        result.errors.append(
            f"{request.module}: zone0 '{request.zone0}' is not a zone in zones.json"
        )
        return result

    if request.snat_from and not request.reason:
        # Required alongside a non-empty request: the attribution loss is
        # permanent and the next operator deserves to meet the reason where
        # the rule is, not in a commit message.
        result.errors.append(
            f"{request.module}: snatFrom is set but snatReason is empty — "
            f"state why this zone gives up client attribution"
        )

    if not dest.ip_network:
        result.errors.append(
            f"{request.module}: zone '{dest.name}' defines no 'ip' subnet in "
            f"zones.json — a masquerade rule needs its CIDR"
        )

    for src in request.snat_from:
        if src == request.zone0:
            result.errors.append(
                f"{request.module}: cannot masquerade '{src}' into itself"
            )
            continue
        source_zone = zones.get(src)
        if source_zone is None:
            result.errors.append(
                f"{request.module}: snatFrom names '{src}', which is not a zone "
                f"in zones.json"
            )
            continue
        if not source_zone.ip_network:
            result.errors.append(
                f"{request.module}: source zone '{src}' defines no 'ip' subnet "
                f"in zones.json"
            )
            continue
        if src in dest.snat_allowed_from:
            result.allowed.append(src)
        else:
            result.refused.append(src)

    if result.refused:
        result.errors.append(
            f"{request.module}: zone '{dest.name}' does not permit masquerade from "
            f"{result.refused} — its snat-allowed-from is {dest.snat_allowed_from}. "
            f"Add the zone there to grant it; the request is refused, not trimmed, "
            f"because a module must never widen its own permission."
        )

    return result


def owned_prefix(module: str) -> str:
    """Description prefix owning every rule this module declares."""
    return f"{DESC_PREFIX}{module}:"


def desired_rules(
    request: SnatRequest,
    zones: dict[str, ZoneSpec],
    allowed: list[str],
    iface_for,
) -> list[dict]:
    """Build the rule set a granted request implies, as plain dicts.

    ``iface_for`` maps a ZoneSpec to its OPNsense interface identifier; it is
    injected rather than imported so this stays decidable without a firewall.
    The dicts are handed to SnatRule by the caller — keeping the API dataclass
    out of the policy layer is what lets the whole gate be unit-tested.
    """
    dest = zones[request.zone0]
    dest_iface = iface_for(dest)
    rules: list[dict] = []
    for src in allowed:
        rules.append(
            {
                "description": rule_description(request.module, src, request.zone0),
                "interface": dest_iface,
                "source_net": zones[src].ip_network,
                "destination_net": dest.ip_network,
                # The zone gateway address on its own interface. OPNsense
                # spells it "<iface>ip", which tracks the address rather than
                # pinning it, so a renumbered zone does not strand the rule.
                "target": f"{dest_iface}ip",
            }
        )
    return rules


@dataclass
class ReconcilePlan:
    """What must change to bring live rules in line with the declaration.

    Computed before anything is written so update-service.sh can report, and
    an operator can inspect, the removals as well as the additions. A dropped
    zone that leaves its rule behind is drift that looks like success — the
    same shape as #239 — so removals are first-class here, not a side effect.
    """

    to_apply: list[dict] = field(default_factory=list)
    to_delete: list[str] = field(default_factory=list)
    unchanged: list[str] = field(default_factory=list)

    @property
    def empty(self) -> bool:
        return not self.to_apply and not self.to_delete


def plan_reconcile(desired: list[dict], live: list) -> ReconcilePlan:
    """Diff desired rules against the live ones this module owns.

    ``live`` is a list of SnatRuleInfo already filtered to the module's own
    prefix; anything in it that the declaration no longer names is removed.
    """
    plan = ReconcilePlan()
    live_by_desc = {r.description: r for r in live}
    desired_by_desc = {r["description"]: r for r in desired}

    for desc, rule in desired_by_desc.items():
        existing = live_by_desc.get(desc)
        if existing is None:
            plan.to_apply.append(rule)
        elif (
            existing.source_net != rule["source_net"]
            or existing.destination_net != rule["destination_net"]
            or existing.target != rule["target"]
            or existing.interface != rule["interface"]
            or not existing.enabled
        ):
            # Same identity, different body — a zone renumbered, an interface
            # reassigned, or the rule disabled by hand. Re-apply over it.
            plan.to_apply.append(rule)
        else:
            plan.unchanged.append(desc)

    for desc in live_by_desc:
        if desc not in desired_by_desc:
            plan.to_delete.append(desc)

    return plan
