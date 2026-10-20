"""What the firewall carries per L2 segment, read-only (#862).

A VLAN tag or an IPv4 subnet can be in use on the firewall without any zone in
zones.json knowing: a segment built by hand in OPNsense (a NAS VLAN), or one a
deleted zone left behind. Every authoring path in network-manager (add, zones
init, zones merge) checked a tag against zones.json only, so the template's
``wan`` (VLAN 100) landed beside a site's own VLAN 100, and reconcile then
adopted that interface by tag. ``opnsense-firewall segments --json`` is what
network-manager asks before it authors; the parsers here are pure so they can
be pinned against the API's row shapes.

Two listings, as the GUI shows them:
- vlans: the VLAN devices (interfaces/vlan_settings), tag, device, parent and
  description — a device exists whether or not an interface is assigned on it;
- interfaces: the assigned interfaces (interfaces/overview), their label (the
  assignment's description), device, VLAN tag when the device is a VLAN, and
  the IPv4 network they hold.
"""
from __future__ import annotations

import ipaddress


def _int_or_none(v) -> int | None:
    if v in (None, "", False):
        return None
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def parse_vlans(rows: list[dict]) -> list[dict]:
    """VLAN devices from ``interfaces/vlan_settings/searchItem`` rows."""
    out = []
    for r in rows:
        tag = _int_or_none(r.get("tag"))
        if not tag or tag <= 0:
            continue
        out.append({
            "tag": tag,
            "device": r.get("vlanif") or None,
            "parent": r.get("if") or None,
            "description": r.get("descr") or "",
        })
    return out


def parse_interfaces(rows: list[dict]) -> list[dict]:
    """Assigned interfaces from ``interfaces/overview/interfacesInfo`` rows."""
    out = []
    for r in rows:
        ident = r.get("identifier") or ""
        if not ident:
            continue
        net = None
        for a in r.get("ipv4") or []:
            try:
                net = str(ipaddress.IPv4Interface((a or {}).get("ipaddr", "")).network)
                break
            except ValueError:
                continue
        out.append({
            "identifier": ident,
            "description": r.get("description") or "",
            "device": r.get("device") or None,
            "tag": _int_or_none(r.get("vlan_tag")),
            "ipv4": net,
            "enabled": bool(r.get("enabled", False)),
        })
    return out


def _rows(r: dict) -> list[dict]:
    return (((r or {}).get("result") or {}).get("response") or {}).get("rows") or []


def read_segments(client) -> dict:
    """Both listings from the firewall (an oxl Client): {"vlans", "interfaces"}."""
    vlans = client.run_module("raw", params={
        "module": "interfaces", "controller": "vlan_settings",
        "command": "searchItem", "action": "get"})
    ifaces = client.run_module("raw", params={
        "module": "interfaces", "controller": "overview",
        "command": "interfacesInfo", "action": "get"})
    return {"vlans": parse_vlans(_rows(vlans)), "interfaces": parse_interfaces(_rows(ifaces))}
