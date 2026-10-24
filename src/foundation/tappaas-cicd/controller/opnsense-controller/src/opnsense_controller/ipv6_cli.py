#!/usr/bin/env python3
"""ipv6-manager — the site's IPv6 stance on the firewall (#149).

site.json `ipv6` (default false) says whether a site supports IPv6. On OPNsense
that is one global switch, Interfaces > Settings > "Allow IPv6" (stored negated,
as `disableipv6`). When IPv6 is not allowed, the filter drops every inbound and
forwarded IPv6 packet first (`block drop in quick inet6 all`), and Unbound runs
with `do-ip6: no` (unbound.inc derives it from the same switch) — the #149 fix:
on a site without IPv6 upstream, Unbound no longer tries the root servers over
IPv6. A WAN address the firewall already holds stays until the WAN is next
reconfigured; the filter blocks traffic to and through it meanwhile.

Allowing IPv6 gives no zone an IPv6 address; that is #26, behind its own ADR.

Commands:
  ipv6-manager status
  ipv6-manager apply [--allow true|false] [--config-dir DIR] [--check-mode]
  ipv6-manager wan [--json]

`wan` reads the WAN's IPv6 router, default route, gateway and prefix (ssh only,
no change) — what the ipv6-egress health gate reads.

`apply` converges the whole of ADR-030 from config/site.json and the zones: the
switch, the WAN's IPv6, the site prefix, each zone's IPv6 and its router
advertisements (see ipv6_plan for the rules). `--allow` overrides site.json
`ipv6` for the switch (tests, and a one-off).

`apply` changes nothing when the firewall already agrees. A change applies the
global interface settings, reloads the filter, restarts Unbound so `do-ip6`
follows, and checks that the resolver still answers. Measured on hrossen
2026-10-12: no interruption to IPv4 or DNS.
"""

import argparse
import base64
import ipaddress
import json
import os
import sys
import time
from pathlib import Path
from typing import Callable

from .cli_globals import StrictArgumentParser, make_global_parent, parse_with_globals
from .config import Config
from .dhcp_manager import DhcpManager  # reused only as a connected-Client provider
from .dual_stack import derived_v6, read_interfaces, v6_on_network
from .ipv6_plan import STATIC_GATEWAY_NAME, ZONE_V6_KEYS, Action, desired_state, plan
from .service_health import _firewall_ssh, check_unbound_dns, filter_reload, unbound_restart
from .vlan_manager import VlanManager
from .wan6 import GATEWAY_NAME, Advert, WanState, parse_adverts, parse_wan, READ_SH, SOLICIT_SH


def _client(args):
    """A connected oxl Client from CLI args (same shape as unbound-manager)."""
    config_kwargs = {
        "firewall": args.firewall,
        "ssl_verify": not args.no_ssl_verify,
        "debug": args.debug,
    }
    if args.port is not None:
        config_kwargs["port"] = args.port
    if args.credential_file:
        config_kwargs["credential_file"] = args.credential_file
    return DhcpManager(Config(**config_kwargs))


def _raw(mgr, command: str, action: str, data: dict | None = None) -> dict:
    params: dict = {
        "module": "interfaces",
        "controller": "settings",
        "command": command,
        "action": action,
    }
    if data is not None:
        params["data"] = data
    result = mgr.client.run_module("raw", params=params)
    return (result.get("result") or {}).get("response") or {}


def read_allowed(mgr) -> bool:
    """Does the firewall allow IPv6 now? Refuses to guess from an odd answer."""
    settings = _raw(mgr, "get", "get").get("settings")
    if not isinstance(settings, dict) or "disableipv6" not in settings:
        raise RuntimeError("interfaces/settings/get returned no 'disableipv6' — "
                           "is this an OPNsense with the Interfaces settings model (24.7+)?")
    return str(settings["disableipv6"]) != "1"


def write_allowed(mgr, allowed: bool) -> None:
    """Store the switch and apply it (one networking reload)."""
    saved = _raw(mgr, "set", "post", {"settings": {"disableipv6": "0" if allowed else "1"}})
    if saved.get("result") != "saved":
        raise RuntimeError(f"interfaces/settings/set did not save: {saved}")
    applied = _raw(mgr, "reconfigure", "post")
    if str(applied.get("status", "")).lower() != "ok":
        raise RuntimeError(f"interfaces/settings/reconfigure did not apply: {applied}")


def _yn(v: bool) -> str:
    return "yes" if v else "no"


def converge(mgr, allowed: bool, check_mode: bool,
             restart: Callable[[], bool], resolver_ok: Callable[[], bool],
             reload_filter: Callable[[], bool]) -> bool:
    """Bring the firewall's "Allow IPv6" to `allowed`. True on success."""
    current = read_allowed(mgr)
    if current == allowed:
        print(f"ipv6: firewall allows IPv6: {_yn(current)} — matches site.json ipv6={str(allowed).lower()}")
        return True
    what = f"Allow IPv6 {_yn(current)} -> {_yn(allowed)} (site.json ipv6={str(allowed).lower()})"
    if check_mode:
        print(f"ipv6: would change {what} — reloads the filter and Unbound once")
        return True
    print(f"ipv6: changing {what} — reloading the filter and Unbound")
    write_allowed(mgr, allowed)
    if read_allowed(mgr) != allowed:
        print("ERROR: the firewall still reports the old value after the change", file=sys.stderr)
        return False
    # The filter reads the switch when it renders: the settings apply does not
    # reload pf, so without this the IPv6 block appears only at the next reload.
    if not reload_filter():
        print("ERROR: 'configctl filter reload' failed — the IPv6 change is stored but not in pf yet",
              file=sys.stderr)
        return False
    # unbound.inc reads the switch when it renders do-ip6; restart through
    # configctl (pluginctl), the start path that works (network/DESIGN.md, #387).
    if not restart():
        print("WARNING: 'configctl unbound restart' did not report success — checking the resolver",
              file=sys.stderr)
    if not resolver_ok():
        print("ERROR: Unbound stopped answering after the IPv6 change. Cluster DNS is DOWN; "
              "recover on the firewall by IP: pluginctl -c unbound_start", file=sys.stderr)
        return False
    print(f"ipv6: firewall allows IPv6: {_yn(allowed)}; Unbound answers")
    return True


def _probe_ip(firewall: str) -> str:
    """The resolver's IP: the firewall if given as an IP, else its mgmt address."""
    try:
        ipaddress.ip_address(firewall)
        return firewall
    except ValueError:
        return "10.0.0.1"


def _parse_bool(v: str) -> bool:
    if v.lower() in ("true", "yes", "1"):
        return True
    if v.lower() in ("false", "no", "0"):
        return False
    raise argparse.ArgumentTypeError(f"expected true or false, got '{v}'")


# ── ADR-030: the WAN, the prefix and the zones ─────────────────────────

# Read back every key the plan compares — the zone keys included, or a written
# key reads as missing and every run rewrites it.
# How long a zone's zero-lifetime advertisements run before its IPv6 goes:
# dnsmasq sends them on reload, guests drop the route within seconds (ADR-030 D8).
DRAIN_SECONDS = 10


def _v6_range(iface: str, router_lifetime: str = "") -> dict:
    """A zone's dnsmasq IPv6 range as ipv6-manager writes it; router lifetime 0
    withdraws the zone's IPv6 default route from its guests."""
    return {"range": {"interface": iface, "start_addr": "::", "constructor": iface,
                      "ra_mode": "ra-names", "domain_type": "range",
                      "ra_router_lifetime": router_lifetime}}


_IFACE_KEYS = ("if", "gatewayv6", "dhcp6-ia-pd-len", *ZONE_V6_KEYS)

_READ_PHP = r"""<?php
require_once("config.inc");
$c = config_read_array("interfaces");
$keys = %s;
$out = [];
foreach ($c as $k => $v) {
    $o = [];
    foreach ($keys as $f) { if (isset($v[$f]) && !is_array($v[$f])) { $o[$f] = (string)$v[$f]; } }
    $out[$k] = $o;
}
$wanif = $c["wan"]["if"] ?? "";
$p = @file_get_contents("/tmp/{$wanif}_prefixv6");
echo json_encode(["interfaces" => $out, "prefix" => trim((string)$p)]);
""" % ("[" + ", ".join(f'"{k}"' for k in _IFACE_KEYS) + "]")

_WRITE_PHP = r"""<?php
require_once("config.inc");
require_once("util.inc");
$ch = json_decode(base64_decode("%s"), true);
foreach ($ch as $if => $keys) {
    $c = &config_read_array("interfaces", $if);
    foreach ($keys as $k => $v) { if ($v === null) { unset($c[$k]); } else { $c[$k] = (string)$v; } }
    unset($c);
}
write_config("TAPPaaS ipv6-manager (ADR-030)");
echo "written\n";
"""


def _fw(host: str, script: str, timeout: float = 120.0) -> str:
    """Run a shell script on the firewall; its stdout, or RuntimeError."""
    r = _firewall_ssh(host, script, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(f"firewall script failed (rc {r.returncode}): {(r.stderr or r.stdout).strip()[:300]}")
    return r.stdout


def read_firewall(host: str) -> tuple[dict, str]:
    """`config.xml` interfaces (the IPv6 keys) and the WAN's delegated prefix."""
    out = _fw(host, "php <<'PHP'\n" + _READ_PHP + "\nPHP\n")
    data = json.loads(out.strip().splitlines()[-1])
    return data.get("interfaces") or {}, data.get("prefix") or ""


def _radvd(mgr, controller: str, command: str, action: str, data=None, params=None) -> dict:
    p = {"module": "radvd", "controller": controller, "command": command, "action": action}
    if data is not None:
        p["data"] = data
    if params:
        p["params"] = params
    return (mgr.client.run_module("raw", params=p).get("result") or {}).get("response") or {}


def _dnsmasq(mgr, controller: str, command: str, action: str, data=None, params=None) -> dict:
    p = {"module": "dnsmasq", "controller": controller, "command": command, "action": action}
    if data is not None:
        p["data"] = data
    if params:
        p["params"] = params
    return (mgr.client.run_module("raw", params=p).get("result") or {}).get("response") or {}


def _routing(mgr, command: str, action: str, data=None, params=None) -> dict:
    p = {"module": "routing", "controller": "settings", "command": command, "action": action}
    if data is not None:
        p["data"] = data
    if params:
        p["params"] = params
    return (mgr.client.run_module("raw", params=p).get("result") or {}).get("response") or {}


def zone_interfaces(config: Config, zones: dict) -> dict[str, str]:
    """Zone name -> its VLAN interface (opt<n>), from the firewall's assignments."""
    with VlanManager(config) as vm:
        by_tag = {str(v["vlan_tag"]): v["identifier"] for v in vm.get_assigned_vlans()}
    out = {}
    for name, z in zones.items():
        if name.startswith("_") or not isinstance(z, dict):
            continue
        tag = z.get("vlantag")
        if isinstance(tag, int) and tag > 0 and str(tag) in by_tag:
            out[name] = by_tag[str(tag)]
    return out


def load_site_and_zones(config_dir: Path) -> tuple[dict, dict]:
    site = json.loads((config_dir / "site.json").read_text())
    authored, effective = config_dir / "zones.json", config_dir / "zones.effective.json"
    zf = effective if effective.is_file() and (
        not authored.is_file() or effective.stat().st_mtime >= authored.stat().st_mtime) else authored
    return site, json.loads(zf.read_text())


def execute(mgr, host: str, actions: list[Action], drain_seconds: float = DRAIN_SECONDS) -> None:
    """Carry out a plan: one config.xml write, the gateway, the reloads, the
    advertisements, and the leftovers a cleared zone keeps on its interface."""
    config_changes: dict[str, dict] = {}
    reload_ifaces: list[str] = []
    cleared_devices: list[str] = []
    wan_reload = False
    # A zone whose advertisements stop first tells its guests to drop the IPv6
    # default route (router lifetime 0) — while the firewall still allows IPv6,
    # or the advertisement never leaves it. Without this they keep the route
    # until it expires and every IPv6 attempt hangs before falling back (D8).
    drains = [a for a in actions if a.kind == "names-del"]
    for a in drains:
        r = _dnsmasq(mgr, "settings", "setRange", "post", _v6_range(a.target, "0"), [a.detail["uuid"]])
        if r.get("result") != "saved":
            raise RuntimeError(f"dnsmasq IPv6 range on {a.target}: drain returned {r}")
    if drains:
        _dnsmasq(mgr, "service", "reconfigure", "post")
        time.sleep(drain_seconds)

    for a in actions:
        if a.kind == "wan":
            config_changes["wan"] = dict(a.detail["set"])
            # The delegation size alone needs no WAN reload: OPNsense reads it
            # when a zone tracks the WAN, and a reload would renew IPv4 too.
            wan_reload = any(k != "dhcp6-ia-pd-len" for k in a.detail["set"])
            if a.detail.get("mode") == "static":
                _ensure_static_gateway(mgr, a.detail["gateway"])
        elif a.kind == "zone-set":
            config_changes[a.target] = {k: a.detail["set"].get(k) for k in ZONE_V6_KEYS}
            reload_ifaces.append(a.target)
        elif a.kind == "zone-clear":
            config_changes[a.target] = {k: None for k in ZONE_V6_KEYS}
            reload_ifaces.append(a.target)
            if a.detail.get("device"):
                cleared_devices.append(a.detail["device"])

    if config_changes:
        payload = base64.b64encode(json.dumps(config_changes).encode()).decode()
        _fw(host, "php <<'PHP'\n" + (_WRITE_PHP % payload) + "\nPHP\n")
    script = ""
    if wan_reload:
        script += "configctl interface reconfigure wan >/dev/null\n"
    for iface in reload_ifaces:
        script += f"configctl interface reconfigure {iface} >/dev/null\n"
    for dev in cleared_devices:
        # Reconfiguring leaves a tracked address on the interface until its
        # lifetime ends (ADR-030 D7): remove it now.
        script += (f"for a in $(ifconfig {dev} | awk '/inet6/ && !/fe80/ {{print $2}}'); do "
                   f"ifconfig {dev} inet6 \"$a\" delete; done\n")
    if script:
        _fw(host, script + "configctl filter refresh_aliases >/dev/null\n", timeout=300.0)

    # radvd first: a zone must not have two daemons advertising on it.
    radvd = [a for a in actions if a.kind == "radvd-del"]
    for a in radvd:
        r = _radvd(mgr, "settings", "delEntry", "post", params=[a.detail["uuid"]])
        if r.get("result") != "deleted":
            raise RuntimeError(f"radvd entry on {a.target}: delete returned {r}")
    # A zone change moves OPNsense's automatic radvd too (the override flag).
    if radvd or reload_ifaces:
        _radvd(mgr, "service", "reconfigure", "post")

    # dnsmasq: one IPv6 range per zone, `ra-names` — advertisements and AAAA names.
    names = [a for a in actions if a.kind.startswith("names-")]
    for a in names:
        rng = _v6_range(a.target)
        if a.kind == "names-add":
            r = _dnsmasq(mgr, "settings", "addRange", "post", rng)
        elif a.kind == "names-set":
            r = _dnsmasq(mgr, "settings", "setRange", "post", rng, [a.detail["uuid"]])
        else:
            r = _dnsmasq(mgr, "settings", "delRange", "post", params=[a.detail["uuid"]])
        if r.get("result") not in ("saved", "deleted"):
            raise RuntimeError(f"dnsmasq IPv6 range on {a.target}: {a.kind} returned {r}")
    if names:
        _dnsmasq(mgr, "service", "reconfigure", "post")


def _ensure_static_gateway(mgr, address: str) -> None:
    """The WAN's static IPv6 gateway, as OPNsense wants it: a named gateway."""
    rows = _routing(mgr, "searchGateway", "get").get("rows", []) or []
    item = {"gateway_item": {"name": STATIC_GATEWAY_NAME, "interface": "wan", "ipprotocol": "inet6",
                             "gateway": address, "descr": "TAPPaaS: WAN IPv6 gateway (site.json)",
                             "defaultgw": "1"}}
    mine = next((r for r in rows if r.get("name") == STATIC_GATEWAY_NAME), None)
    r = (_routing(mgr, "setGateway", "post", item, [mine["uuid"]]) if mine
         else _routing(mgr, "addGateway", "post", item))
    if r.get("result") != "saved":
        raise RuntimeError(f"WAN IPv6 gateway: {r}")
    _routing(mgr, "reconfigure", "post")


def converge_site(mgr, config: Config, host: str, config_dir: Path, check_mode: bool,
                  allow_override: bool | None = None) -> bool:
    """ADR-030 end to end. True on success."""
    site, zones = load_site_and_zones(config_dir)
    if allow_override is not None:
        site = {**site, "ipv6": allow_override}
    allowed = bool(site.get("ipv6"))

    def switch() -> bool:
        return converge(mgr, allowed, check_mode,
                        restart=lambda: unbound_restart(host),
                        resolver_ok=lambda: check_unbound_dns(host=host, label="POST-IPV6", retries=10, delay=3.0),
                        reload_filter=lambda: filter_reload(host))

    # Switching off, the zones go first: their withdrawal is an advertisement,
    # which the firewall no longer sends once it disallows IPv6 (D8).
    turning_off = not allowed and read_allowed(mgr)
    if not turning_off and not switch():
        return False

    ifaces = zone_interfaces(config, zones)
    current, prefix = read_firewall(host)
    desired = desired_state(site, zones, ifaces, prefix or None)
    for p in desired.problems:
        print(f"ipv6: {p}")
    entries = _radvd(mgr, "settings", "searchEntry", "get").get("rows", []) or []
    ranges = _dnsmasq(mgr, "settings", "searchRange", "get").get("rows", []) or []
    actions = plan(desired, current, set(ifaces.values()), entries, ranges)
    if desired.site_prefix:
        print(f"ipv6: site prefix {desired.site_prefix} "
              f"({desired.wan.mode if desired.wan else 'off'}); {len(desired.zones)} zone(s) with IPv6")
    if not actions:
        print("ipv6: the WAN and the zones match the declaration")
    else:
        for a in actions:
            print(f"ipv6: {'would ' if check_mode else ''}{a.describe()}")
        if not check_mode:
            execute(mgr, host, actions)
            if not check_unbound_dns(host=host, label="POST-IPV6", retries=10, delay=3.0):
                print("ERROR: Unbound stopped answering after the IPv6 changes — recover on the "
                      "firewall by IP: pluginctl -c unbound_start", file=sys.stderr)
                return False
            print(f"ipv6: {len(actions)} change(s) applied")
    if turning_off and not switch():
        return False
    return converge_published(mgr, config, host, check_mode, allowed=allowed)


# The WAN rules setup-caddy.sh writes for Caddy (#26 inbound): IPv4-only as
# written; both families while the site runs IPv6 and the WAN holds an address.
CADDY_WAN_RULES = ("TAPPaaS: Allow HTTP to Caddy", "TAPPaaS: Allow HTTPS to Caddy")


def caddy_wan_family(allowed: bool, wan_v6: list) -> str:
    """The address family the Caddy WAN rules should carry (pure)."""
    return "inet46" if allowed and wan_v6 else "inet"


def _converge_caddy_wan(config: Config, ifaces, allowed: bool, check_mode: bool) -> int:
    """Open Caddy on the WAN's IPv6 address too, or close it again. Returns changes."""
    from .firewall_manager import FirewallManager, FirewallRule, IpProtocol, Protocol, RuleAction

    wan = next((i for i in ifaces if i.identifier == "wan"), None)
    wan_v6 = list(wan.v6) if wan else []
    want = caddy_wan_family(allowed, wan_v6)
    changed = 0
    with FirewallManager(config) as fm:
        for desc in CADDY_WAN_RULES:
            r = fm.get_rule_by_description(desc)
            if r is None:
                continue                  # setup-caddy.sh writes them; nothing to follow
            if (r.ip_protocol or "inet") == want:
                continue
            print(f"ipv6: {'would ' if check_mode else ''}{desc}: {r.ip_protocol or 'inet'} -> {want}")
            changed += 1
            if check_mode:
                continue
            fm.update_rule(FirewallRule(
                description=r.description, action=RuleAction.PASS, interface=r.interface,
                ip_protocol=IpProtocol(want), protocol=Protocol.TCP,
                source_net=r.source_net or "any", destination_net=r.destination_net,
                destination_port=r.destination_port, log=r.log, quick=r.quick,
                sequence=r.sequence), apply=False)
        if changed and not check_mode:
            fm.apply_changes()
    if want == "inet46":
        print(f"ipv6: Caddy answers on the WAN over IPv6 at {wan_v6[0].ip} — the public AAAA "
              f"for published names (set it where the public A record is kept)")
    return changed


def converge_published(mgr, config: Config, host: str, check_mode: bool,
                       allowed: bool | None = None) -> bool:
    """Published names and access lists follow the interfaces' IPv6 (ADR-030 D9).

    The split-horizon AAAA next to every A that points at the firewall, and the
    IPv6 networks next to the IPv4 ones in TAPPaaS's Caddy access lists — both
    from what the interfaces hold now, so a changed prefix, or IPv6 switched off,
    is followed here on the next network update.
    """
    from .caddy_cli import reconfigure_cmd
    from .caddy_manager import CaddyManager
    from .unbound_cli import _search_overrides, apply_aaaa, describe_aaaa
    from .dual_stack import aaaa_plan

    ifaces = read_interfaces(mgr.client)
    names = aaaa_plan(_search_overrides(mgr), ifaces)
    for line in describe_aaaa(names):
        print(f"ipv6: {'would ' if check_mode else ''}{line}")
    if names and not check_mode:
        apply_aaaa(mgr, names)
        if not check_unbound_dns(host=host, label="POST-AAAA", retries=10, delay=3.0):
            print("ERROR: Unbound stopped answering after the AAAA records — recover on the "
                  "firewall by IP: pluginctl -c unbound_start", file=sys.stderr)
            return False

    changed = 0
    try:
        with CaddyManager(config) as cm:
            lists = [al for al in cm.list_access_lists() if al.name.startswith("tappaas-")]
            for al in lists:
                want = derived_v6(al.client_ips, ifaces)
                if want == al.client_ips:
                    continue
                print(f"ipv6: {'would ' if check_mode else ''}access list {al.name}: "
                      + ", ".join(want))
                changed += 1
                if not check_mode:
                    upd = al.to_access_list()
                    upd.client_ips = want
                    r = cm.update_access_list(al.uuid, upd)
                    if r.get("result") not in ("saved", "ok"):
                        raise RuntimeError(f"access list {al.name}: {r}")
            if changed and not check_mode and not reconfigure_cmd(cm):
                return False
    except RuntimeError:
        raise
    except Exception as exc:  # noqa: BLE001
        print(f"ipv6: Caddy access lists not checked: {exc}")
    if allowed is not None:
        changed += _converge_caddy_wan(config, ifaces, allowed, check_mode)
    if not names and not changed:
        print("ipv6: published names and access lists match the interfaces")
    return True


def read_wan(host: str) -> WanState:
    """The WAN's IPv6 router, route, gateway and prefix, read-only."""
    return parse_wan(_fw(host, READ_SH, timeout=60.0))


def solicit(host: str, wanif: str) -> list[Advert]:
    """Send one router solicitation on the WAN; the routers that answer."""
    return parse_adverts(_fw(host, SOLICIT_SH % wanif, timeout=60.0))


def _wan_lines(s: WanState, adverts: list[Advert] | None = None) -> list[str]:
    def nb(addr: str) -> str:
        n = s.neighbour(addr)
        if not addr:
            return ""
        if n is None:
            return " (not probed)"
        return " (answers)" if n.answers else " (does not answer: not a neighbour)"
    lines = [
        f"WAN interface:     {s.wanif or '(none)'}",
        f"recorded router:   {s.recorded or '(none)'}{nb(s.recorded)}",
        f"default route:     {('via ' + s.route) if s.route else '(none)'}{nb(s.route)}",
        f"{GATEWAY_NAME} gateway: {s.gateway or '(none)'}",
        f"delegated prefix:  {s.prefix or '(none)'}",
        f"WAN address:       {s.address or '(none)'}",
        f"rtsold:            {'running' if s.rtsold else 'NOT running'}",
    ]
    if adverts is not None:
        lines.append("advertising now:   " + (", ".join(
            f"{a.router} (lifetime {a.lifetime}s{', managed' if a.managed else ''})" for a in adverts)
            or "(no answer to a solicitation)"))
    return lines


def main():
    # Global options work on either side of the subcommand (#379); see cli_globals.py.
    gp = make_global_parent()
    gp.add_argument("--firewall", help="Firewall IP/hostname (default: firewall.mgmt.internal)")
    gp.add_argument("--port", type=int, help="API port (default: probe 443/8443)")
    gp.add_argument("--credential-file", help="Path to credential file")
    gp.add_argument("--no-ssl-verify", action="store_true", help="Disable SSL verification")
    gp.add_argument("--debug", action="store_true", help="Enable debug logging")
    gp.add_argument("--check-mode", action="store_true", help="Dry-run (no changes)")

    parser = StrictArgumentParser(
        description="The site's IPv6 stance on OPNsense: the global 'Allow IPv6' switch (#149)",
        parents=[gp],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  ipv6-manager status
  ipv6-manager apply --allow false --check-mode
  ipv6-manager apply --allow "$(jq -r '.ipv6 // false' ~/config/site.json)"
""",
    )
    sub = parser.add_subparsers(dest="command", help="Command")
    sub.add_parser("status", parents=[gp], help="Show whether the firewall allows IPv6")
    p_gw = sub.add_parser("gateway", parents=[gp],
                          help="The firewall's IPv6 address in a zone (exit 3: the zone has none)")
    p_gw.add_argument("zone", help="zone name from zones.json")
    p_gw.add_argument("--config-dir", default=os.environ.get("CONFIG_DIR", "/home/tappaas/config"),
                      help="where zones.json is (default: /home/tappaas/config)")
    p_wan = sub.add_parser("wan", parents=[gp],
                           help="The WAN's IPv6 router, default route, gateway and prefix (read-only)")
    p_wan.add_argument("--json", action="store_true", help="print the state as JSON")
    p_apply = sub.add_parser("apply", parents=[gp], help="Set 'Allow IPv6' to the site's value")
    p_apply.add_argument("--allow", type=_parse_bool, default=None,
                         help="override site.json ipv6 for the switch (default: read site.json)")
    p_apply.add_argument("--config-dir", default=os.environ.get("CONFIG_DIR", "/home/tappaas/config"),
                         help="where site.json and zones.json are (default: /home/tappaas/config)")

    args = parse_with_globals(parser, {
        "firewall": "firewall.mgmt.internal", "port": None,
        "credential_file": None, "no_ssl_verify": False,
        "debug": False, "check_mode": False,
    })
    if not args.command:
        parser.print_help()
        sys.exit(1)

    host = _probe_ip(args.firewall)
    try:
        # Over ssh only: the health gate reads this, and must answer when the API does not.
        if args.command == "wan":
            s = read_wan(host)
            if args.json:
                print(json.dumps(s.to_json(), indent=2))
            else:
                for line in _wan_lines(s):
                    print(line)
            sys.exit(0)
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: {exc}", file=sys.stderr)
        if args.debug:
            raise
        sys.exit(1)

    try:
        with _client(args) as mgr:
            if args.command == "status":
                print(f"ipv6: firewall allows IPv6: {_yn(read_allowed(mgr))}")
                ok = True
            elif args.command == "gateway":
                # Where Caddy's requests come from when it reaches a service in
                # this zone over IPv6: what a service trusts beside the IPv4 one.
                _, zones = load_site_and_zones(Path(args.config_dir))
                z = zones.get(args.zone)
                if not isinstance(z, dict) or not z.get("ip"):
                    raise RuntimeError(f"zone '{args.zone}' has no 'ip' in zones.json")
                addr = v6_on_network(z["ip"], read_interfaces(mgr.client))
                if not addr:
                    sys.exit(3)
                print(addr)
                ok = True
            else:
                ok = converge_site(mgr, mgr.config, _probe_ip(args.firewall), Path(args.config_dir),
                                   args.check_mode, allow_override=args.allow)
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: {exc}", file=sys.stderr)
        if args.debug:
            raise
        sys.exit(1)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
