"""The `all` sentinel in a zone's `access-to` (#375).

`mgmt.access-to: ["internet", "all"]` replaces a hand-kept list of every zone,
which drifted the moment a zone was added or removed by any path that forgot to
edit it (#372, #373). `all` means what that list was meant to say: `internet`
and every other standard zone — not `Disabled`, and not one of the tier-exempt
types (`Overlay`, `WAN`: WireGuard segments and the switch-internal ISP
hand-off, which no mgmt list ever named).

It is expanded once, where a zones file is read, so every consumer — the zone
rules, the pinhole and egress checks, the SNAT reachability gate — sees exactly
the set an explicit list would give, and no consumer has to know the sentinel.
Validation (`network-manager validate`, I2) permits it only in `mgmt`.
"""

from __future__ import annotations

ACCESS_ALL = "all"

# Not reached through `all`: schemas/zones-fields.json `tier_exempt_types`
# (network-manager's TIER_EXEMPT_TYPES).
NOT_IN_ALL_TYPES = ("Overlay", "WAN")


def _is_zone(name: str, entry: object) -> bool:
    return not name.startswith("_") and isinstance(entry, dict)


def expand_access_all(data: dict) -> dict:
    """Return ``data`` with each `all` in an `access-to` replaced by its set.

    The set is `internet` plus every other zone whose state is not `Disabled`
    and whose type is not in NOT_IN_ALL_TYPES, in file order, after the entries
    the zone names itself (no duplicates).
    Zones without the sentinel, and documentation keys, are returned as they
    are; ``data`` itself is not modified.
    """
    others = [
        name for name, entry in data.items()
        if _is_zone(name, entry) and entry.get("state") != "Disabled"
        and entry.get("type") not in NOT_IN_ALL_TYPES
    ]
    out = dict(data)
    for name, entry in data.items():
        if not _is_zone(name, entry):
            continue
        access = entry.get("access-to") or []
        if not isinstance(access, list) or ACCESS_ALL not in access:
            continue
        expanded = [t for t in access if t != ACCESS_ALL]
        for target in ["internet", *others]:
            if target != name and target not in expanded:
                expanded.append(target)
        out[name] = {**entry, "access-to": expanded}
    return out
