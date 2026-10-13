#!/usr/bin/env python3
"""mdns-manager — mDNS discovery across zones (#257).

mDNS (printers, media players, smart-home hubs announcing themselves on
224.0.0.251 port 5353) does not cross a VLAN on its own. The firewall's
os-mdns-repeater relays it among a set of interfaces; this converges that set
from the declarations:

  * every Active/Mandatory zone with `"mdns": true` in zones.json, and
  * per module, as before: the module's zone0 plus the zones its
    `discoveryMdns` names (a list; the deprecated `true` names none).

The repeater is one group: every interface in it hears every other. With fewer
than two interfaces there is nothing to relay and the repeater is switched off.
TAPPaaS owns the repeater's interface list; an interface added by hand is
removed at the next apply.

The repeater listens on the firewall itself, so each interface in the group
also needs a pass for 224.0.0.251:5353 — one rule, `TAPPaaS: mDNS to the
repeater`, on all of them (sequence 975: after anti-spoofing, so only the
zone's own sources reach it). The rule passes discovery only; whether a device
may then connect to what it found is the zone rules and pinholes, as ever.

IPv4 only: mdns-repeater does not relay IPv6 mDNS (ff02::fb). Devices announce
over both, so discovery works over IPv4 and the connection uses either family.

Commands:
  mdns-manager status
  mdns-manager apply [--config-dir DIR] [--without MODULE] [--check-mode]

`--without` leaves one module's declaration out — its delete-service runs
apply before its config file is removed.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

from .cli_globals import StrictArgumentParser, make_global_parent, parse_with_globals
from .config import Config

PLUGIN = "os-mdns-repeater"
RULE_DESC = "TAPPaaS: mDNS to the repeater"
RULE_SEQUENCE = 975
MDNS_GROUP = "224.0.0.251"
MDNS_PORT = "5353"
EXCLUDED_TYPES = {"Management", "WAN", "Overlay"}
ACTIVE = {"Active", "Mandatory"}


# ── The declaration (pure) ────────────────────────────────────────────

@dataclass
class Declared:
    zones: dict[str, list[str]] = field(default_factory=dict)   # zone -> who asked
    warnings: list[str] = field(default_factory=list)

    def add(self, zone: str, by: str) -> None:
        self.zones.setdefault(zone, [])
        if by not in self.zones[zone]:
            self.zones[zone].append(by)


def declared_zones(zones: dict, modules: dict[str, dict], without: str | None = None) -> Declared:
    """The zones in the mDNS group, each with what put it there."""
    d = Declared()

    def usable(name: str, by: str) -> bool:
        z = zones.get(name)
        if not isinstance(z, dict):
            d.warnings.append(f"{by}: zone '{name}' is not in zones.json — left out")
            return False
        if str(z.get("state", "")) not in ACTIVE:
            d.warnings.append(f"{by}: zone '{name}' is not active — left out")
            return False
        if str(z.get("type", "")) in EXCLUDED_TYPES or not z.get("vlantag"):
            d.warnings.append(f"{by}: zone '{name}' cannot take part in mDNS "
                              f"(only VLAN zones that are not Management, WAN or Overlay)")
            return False
        return True

    for name, z in zones.items():
        if name.startswith("_") or not isinstance(z, dict) or z.get("mdns") is not True:
            continue
        if usable(name, "zones.json"):
            d.add(name, "zones.json")
    for mod, cfg in sorted(modules.items()):
        if mod == without:
            continue
        val = cfg.get("discoveryMdns")
        if val in (None, False, []):
            continue
        by = f"module {mod}"
        zone0 = cfg.get("zone0")
        if not zone0:
            d.warnings.append(f"{by}: discoveryMdns without zone0 — left out")
            continue
        names = [zone0] + ([z for z in val if isinstance(z, str)] if isinstance(val, list) else [])
        for name in names:
            if usable(name, by):
                d.add(name, by)
    return d


def load_modules(config_dir: Path) -> dict[str, dict]:
    """Module configs that declare discoveryMdns (others are not needed here)."""
    out = {}
    for f in sorted(config_dir.glob("*.json")):
        try:
            cfg = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        if isinstance(cfg, dict) and "discoveryMdns" in cfg:
            out[f.stem] = cfg
    return out


@dataclass
class Plan:
    enabled: bool
    interfaces: list[str]          # sorted, what the repeater and the rule carry
    settings_change: bool
    rule_change: str               # "" | "create" | "update" | "delete"


def plan(want_ifaces: set[str], current_enabled: bool, current_ifaces: set[str],
         rule: dict | None) -> Plan:
    """What to change, given the wanted interface set and what the firewall has.

    `rule` is the current rule as {"interfaces": set, "sequence": int,
    "destination": str, "port": str, "protocol": str, "family": str}, or None.
    """
    enabled = len(want_ifaces) >= 2
    ifaces = sorted(want_ifaces) if enabled else []
    if enabled:
        settings_change = not current_enabled or current_ifaces != set(ifaces)
    else:
        settings_change = current_enabled
    if not enabled:
        rule_change = "delete" if rule is not None else ""
    elif rule is None:
        rule_change = "create"
    elif (rule.get("interfaces") != set(ifaces) or rule.get("sequence") != RULE_SEQUENCE
          or rule.get("destination") != MDNS_GROUP or rule.get("port") != MDNS_PORT
          or str(rule.get("protocol", "")).upper() != "UDP"
          or (rule.get("family") or "inet") != "inet"):
        rule_change = "update"
    else:
        rule_change = ""
    return Plan(enabled, ifaces, settings_change, rule_change)


# ── The firewall ──────────────────────────────────────────────────────

def _raw(client, module: str, controller: str, command: str, action: str = "get",
         data: dict | None = None, params: list[str] | None = None) -> dict:
    p: dict = {"module": module, "controller": controller, "command": command, "action": action}
    if data is not None:
        p["data"] = data
    if params:
        p["params"] = params
    return (client.run_module("raw", params=p).get("result") or {}).get("response") or {}


def read_repeater(client) -> tuple[bool, set[str]] | None:
    """(enabled, selected interfaces), or None when the plugin is not installed."""
    try:
        node = _raw(client, "mdnsrepeater", "settings", "get").get("mdnsrepeater")
    except Exception:  # noqa: BLE001 — "Endpoint not found" surfaces as an error
        return None
    if not isinstance(node, dict) or not isinstance(node.get("interfaces"), dict):
        return None
    sel = {k for k, v in node["interfaces"].items() if isinstance(v, dict) and str(v.get("selected")) == "1"}
    return str(node.get("enabled")) == "1", sel


def install_plugin(client, timeout: float = 300.0) -> None:
    """Install os-mdns-repeater through the firmware API and wait for it."""
    r = _raw(client, "core", "firmware", "install", "post", params=[PLUGIN])
    if str(r.get("status", "")).lower() not in ("ok", ""):
        raise RuntimeError(f"firmware install {PLUGIN}: {r}")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        time.sleep(3)
        s = _raw(client, "core", "firmware", "upgradestatus")
        if str(s.get("status", "")).lower() == "done":
            break
    if read_repeater(client) is None:
        raise RuntimeError(f"{PLUGIN} is not available after installing it")


def write_repeater(client, enabled: bool, ifaces: list[str]) -> None:
    data = {"mdnsrepeater": {"enabled": "1" if enabled else "0"}}
    if enabled:
        data["mdnsrepeater"]["interfaces"] = ",".join(ifaces)
    saved = _raw(client, "mdnsrepeater", "settings", "set", "post", data)
    if saved.get("result") != "saved":
        raise RuntimeError(f"mdnsrepeater/settings/set did not save: {saved}")
    _raw(client, "mdnsrepeater", "service", "reconfigure", "post")


def _rule_view(info) -> dict | None:
    if info is None:
        return None
    return {
        "interfaces": {i.strip() for i in (info.interface or "").split(",") if i.strip()},
        "sequence": info.sequence,
        "destination": info.destination_net,
        "port": str(info.destination_port or ""),
        "protocol": info.protocol,
        "family": info.ip_protocol,
    }


def converge(config: Config, config_dir: Path, check_mode: bool, without: str | None = None) -> bool:
    from .firewall_manager import FirewallManager, FirewallRule, IpProtocol, Protocol, RuleAction
    from .ipv6_cli import load_site_and_zones, zone_interfaces

    _, zones = load_site_and_zones(config_dir)
    decl = declared_zones(zones, load_modules(config_dir), without)
    for w in decl.warnings:
        print(f"mdns: {w}")
    by_zone = zone_interfaces(config, zones)
    want: dict[str, str] = {}
    for z in decl.zones:
        if z in by_zone:
            want[by_zone[z]] = z
        else:
            print(f"mdns: zone '{z}' has no interface on the firewall yet — left out")
    if len(want) == 1:
        print(f"mdns: only zone {next(iter(want.values()))} takes part — nothing to relay")

    with FirewallManager(config) as fm:
        client = fm.client
        cur = read_repeater(client)
        if cur is None and len(want) < 2:
            print("mdns: no zone relays mDNS")
            return True
        if cur is None:
            print(f"mdns: {'would install' if check_mode else 'installing'} {PLUGIN}")
            if check_mode:
                cur = (False, set())
            else:
                install_plugin(client)
                cur = read_repeater(client)
        p = plan(set(want), cur[0], cur[1], _rule_view(fm.get_rule_by_description(RULE_DESC)))
        names = ", ".join(sorted(want[i] for i in p.interfaces))
        verb = "would " if check_mode else ""
        if p.settings_change:
            print(f"mdns: {verb}relay among {names}" if p.enabled else f"mdns: {verb}switch the repeater off")
        if p.rule_change:
            print(f"mdns: {verb}{p.rule_change} rule '{RULE_DESC}'")
        if not p.settings_change and not p.rule_change:
            print(f"mdns: relaying among {names}" if p.enabled else "mdns: no zone relays mDNS")
            return True
        if check_mode:
            return True
        # Rule first when relaying starts, repeater first when it stops: the
        # repeater never listens on an interface that drops what it relays.
        if p.rule_change == "delete" and p.settings_change:
            write_repeater(client, False, [])
        if p.rule_change == "delete":
            fm.delete_rule(RULE_DESC, apply=True)
        elif p.rule_change:
            fm.create_rule(FirewallRule(
                description=RULE_DESC, action=RuleAction.PASS, interface=p.interfaces,
                ip_protocol=IpProtocol.IPV4, protocol=Protocol.UDP,
                source_net="any", destination_net=MDNS_GROUP, destination_port=MDNS_PORT,
                log=False, quick=True, sequence=RULE_SEQUENCE), apply=True)
        if p.settings_change and p.enabled:
            write_repeater(client, True, p.interfaces)
    return True


def status(config: Config) -> None:
    from .firewall_manager import FirewallManager
    with FirewallManager(config) as fm:
        cur = read_repeater(fm.client)
        rule = _rule_view(fm.get_rule_by_description(RULE_DESC))
    if cur is None:
        print(f"mdns: {PLUGIN} is not installed")
    else:
        print(f"mdns: repeater {'on' if cur[0] else 'off'}, interfaces: {', '.join(sorted(cur[1])) or '-'}")
    print(f"mdns: rule: {', '.join(sorted(rule['interfaces'])) if rule else 'none'}")


def main():
    gp = make_global_parent()
    gp.add_argument("--firewall", help="Firewall IP/hostname (default: firewall.mgmt.internal)")
    gp.add_argument("--port", type=int, help="API port (default: probe 443/8443)")
    gp.add_argument("--credential-file", help="Path to credential file")
    gp.add_argument("--no-ssl-verify", action="store_true", help="Disable SSL verification")
    gp.add_argument("--debug", action="store_true", help="Enable debug logging")
    gp.add_argument("--check-mode", action="store_true", help="Dry-run (no changes)")

    parser = StrictArgumentParser(
        description="mDNS discovery across zones: os-mdns-repeater and its rule (#257)",
        parents=[gp], formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  mdns-manager status
  mdns-manager apply --check-mode
  mdns-manager apply --without printer-hub     # a module's delete-service
""",
    )
    sub = parser.add_subparsers(dest="command", help="Command")
    sub.add_parser("status", parents=[gp], help="The repeater's interfaces and the rule")
    p_apply = sub.add_parser("apply", parents=[gp], help="Converge the repeater from zones.json and the modules")
    p_apply.add_argument("--config-dir", default=os.environ.get("CONFIG_DIR", "/home/tappaas/config"),
                         help="where zones.json and module configs are (default: /home/tappaas/config)")
    p_apply.add_argument("--without", help="leave this module's discoveryMdns out")

    args = parse_with_globals(parser, {
        "firewall": "firewall.mgmt.internal", "port": None,
        "credential_file": None, "no_ssl_verify": False,
        "debug": False, "check_mode": False,
    })
    if not args.command:
        parser.print_help()
        sys.exit(1)
    kw = {"firewall": args.firewall, "ssl_verify": not args.no_ssl_verify, "debug": args.debug}
    if args.port is not None:
        kw["port"] = args.port
    if args.credential_file:
        kw["credential_file"] = args.credential_file
    config = Config(**kw)
    try:
        if args.command == "status":
            status(config)
            ok = True
        else:
            ok = converge(config, Path(args.config_dir), args.check_mode, args.without)
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: {exc}", file=sys.stderr)
        if args.debug:
            raise
        sys.exit(1)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
