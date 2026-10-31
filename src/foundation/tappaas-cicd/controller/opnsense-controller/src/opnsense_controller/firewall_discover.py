"""One pass over the firewall for `network-manager report --discover` (ADR-040 D15).

Everything the firewall holds, whether or not TAPPaaS declared it: interfaces and
VLANs, firewall rules and aliases by UUID, NAT, DHCP, DNS overrides, WireGuard
peers with their last handshake, routes, certificates, packages and the OPNsense
version. Read-only. A section the firewall does not answer is an empty list and a
line in ``errors``: a plugin that is not installed costs that section, not the pass.
"""
from __future__ import annotations

from .segments import parse_interfaces, parse_vlans


def _response(client, module: str, controller: str, command: str) -> dict:
    r = client.run_module("raw", params={
        "module": module, "controller": controller, "command": command, "action": "get"})
    resp = ((r or {}).get("result") or {}).get("response")
    return resp if isinstance(resp, dict) else {}


def _rows(client, module: str, controller: str, command: str) -> list[dict]:
    return _response(client, module, controller, command).get("rows") or []


def _selected(v) -> str:
    """A select field of a model `get`: the keys marked selected, comma-joined."""
    if isinstance(v, dict):
        return ",".join(k for k, o in v.items() if isinstance(o, dict) and o.get("selected"))
    return "" if v is None else str(v)


def shape_rules(model: dict) -> list[dict]:
    """The filter's rules in the order the firewall evaluates them, each with its position.

    The model keeps them in the order they were written; OPNsense renders
    them by sequence (checked against /tmp/rules.debug on hrossen).
    """
    rules = ((model.get("filter") or {}).get("rules") or {}).get("rule") or {}
    if not isinstance(rules, dict):  # an empty model is a list
        return []
    def sequence(item: tuple) -> float:
        seq = str(item[1].get("sequence") or "")
        return int(seq) if seq.isdigit() else float("inf")

    out = []
    for pos, (uuid, d) in enumerate(sorted(rules.items(), key=sequence), start=1):
        seq = str(d.get("sequence") or "")
        out.append({
            "uuid": uuid, "position": pos, "sequence": int(seq) if seq.isdigit() else None,
            "enabled": str(d.get("enabled", "1")) == "1", "action": _selected(d.get("action")),
            "interface": _selected(d.get("interface")), "protocol": _selected(d.get("protocol")),
            "source": _selected(d.get("source_net")), "destination": _selected(d.get("destination_net")),
            "destinationPort": str(d.get("destination_port") or ""), "description": d.get("description") or "",
        })
    return out


def _nat_enabled(d: dict) -> bool:
    """Source NAT says ``enabled``; a port forward says ``disabled`` (1 = off)."""
    if "enabled" in d:
        return str(d.get("enabled")) != "0"
    return str(d.get("disabled", "0")) != "1"


def shape_nat(model: dict, section: str, kind: str) -> list[dict]:
    rules = ((model.get(section) or {}).get("rule")) or ((model.get("filter") or {}).get(section) or {}).get("rule") or {}
    if not isinstance(rules, dict):
        return []
    return [{"uuid": u, "kind": kind, "position": i, "enabled": _nat_enabled(d),
             "description": d.get("descr") or d.get("description") or "",
             "target": str(d.get("target") or "")}
            for i, (u, d) in enumerate(rules.items(), start=1)]


def shape_peers(clients: list[dict], status: list[dict]) -> list[dict]:
    """The WireGuard peers, with the handshake `service/show` reports for each key."""
    seen = {s.get("public-key") or s.get("pubkey"): s for s in status if s.get("type") in (None, "peer")}
    out = []
    for c in clients:
        s = seen.get(c.get("pubkey")) or {}
        out.append({"name": c.get("name") or "", "publicKey": c.get("pubkey") or "",
                    "tunneladdress": c.get("tunneladdress") or "",
                    "endpoint": s.get("endpoint") or "",
                    "lastHandshake": s.get("latest-handshake-age") or s.get("latest-handshake") or None})
    return out


def read_discover(client) -> dict:
    """Every section of the pass, plus ``errors``: [{section, error}]."""
    errors: list[dict] = []

    def section(name: str, fn, empty):
        try:
            return fn()
        except Exception as e:  # noqa: BLE001 — one section's failure is reported, the pass goes on
            errors.append({"section": name, "error": str(e)})
            return empty

    vlans = section("vlans", lambda: parse_vlans(_rows(client, "interfaces", "vlan_settings", "searchItem")), [])
    interfaces = section("interfaces", lambda: parse_interfaces(_rows(client, "interfaces", "overview", "interfacesInfo")), [])
    rules = section("rules", lambda: shape_rules(_response(client, "firewall", "filter", "get")), [])
    aliases = section("aliases", lambda: [
        {"uuid": a.get("uuid"), "name": a.get("name"), "type": a.get("type"), "enabled": str(a.get("enabled", "1")) == "1",
         "content": a.get("content") or "", "description": a.get("description") or ""}
        for a in _rows(client, "firewall", "alias", "searchItem")], [])
    nat = section("nat", lambda: (
        shape_nat(_response(client, "firewall", "d_nat", "get"), "DNat", "port-forward")
        + shape_nat(_response(client, "firewall", "source_nat", "get"), "snatrules", "source")), [])
    ranges = section("dhcpRanges", lambda: _rows(client, "dnsmasq", "settings", "searchRange"), [])
    hosts = section("dhcpHosts", lambda: _rows(client, "dnsmasq", "settings", "searchHost"), [])
    leases = section("leases", lambda: [
        {"ip": r.get("address"), "mac": r.get("hwaddr"), "hostname": r.get("hostname") or "",
         "zone": r.get("if_descr") or r.get("if_name") or "", "expire": r.get("expire")}
        for r in _rows(client, "dnsmasq", "leases", "search")], [])
    overrides = section("dnsOverrides", lambda: [
        {"uuid": r.get("uuid"), "fqdn": ".".join(x for x in (r.get("hostname"), r.get("domain")) if x),
         "target": r.get("server") or "", "enabled": str(r.get("enabled", "1")) == "1"}
        for r in _rows(client, "unbound", "settings", "searchHostOverride")], [])
    peers = section("wireguard", lambda: shape_peers(
        _rows(client, "wireguard", "client", "searchClient"), _rows(client, "wireguard", "service", "show")), [])
    routes = section("routes", lambda: [
        {"destination": r.get("destination"), "gateway": r.get("gateway"), "interface": r.get("intf") or r.get("netif"),
         "flags": r.get("flags") or ""}
        for r in (client.run_module("raw", params={
            "module": "diagnostics", "controller": "interface", "command": "getRoutes", "action": "get",
        }).get("result", {}).get("response") or [])], [])
    certs = section("certificates", lambda: [
        {"uuid": c.get("uuid"), "name": c.get("descr") or "", "commonName": c.get("commonname") or "",
         "validTo": c.get("valid_to") or None}
        for c in _rows(client, "trust", "cert", "search")], [])
    firmware = section("firmware", lambda: _response(client, "core", "firmware", "info"), {})
    return {
        "version": firmware.get("product_version") or (firmware.get("product") or {}).get("product_version"),
        "packages": [{"name": p.get("name"), "version": p.get("version")}
                     for p in (firmware.get("package") or []) if str(p.get("installed", "1")) == "1"],
        "interfaces": interfaces,
        "vlans": vlans, "rules": rules, "aliases": aliases, "nat": nat,
        "dhcpRanges": ranges, "dhcpHosts": hosts, "leases": leases, "dnsOverrides": overrides,
        "wireguard": peers, "routes": routes, "certificates": certs, "errors": errors,
    }
