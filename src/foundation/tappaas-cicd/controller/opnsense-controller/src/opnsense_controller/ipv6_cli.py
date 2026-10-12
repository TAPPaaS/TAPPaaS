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
  ipv6-manager apply --allow true|false [--check-mode]

`apply` changes nothing when the firewall already agrees. A change applies the
global interface settings, reloads the filter, restarts Unbound so `do-ip6`
follows, and checks that the resolver still answers. Measured on hrossen
2026-10-12: no interruption to IPv4 or DNS.
"""

import argparse
import ipaddress
import sys
from typing import Callable

from .cli_globals import StrictArgumentParser, make_global_parent, parse_with_globals
from .config import Config
from .dhcp_manager import DhcpManager  # reused only as a connected-Client provider
from .service_health import check_unbound_dns, filter_reload, unbound_restart


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
    p_apply = sub.add_parser("apply", parents=[gp], help="Set 'Allow IPv6' to the site's value")
    p_apply.add_argument("--allow", type=_parse_bool, required=True,
                         help="true when the site supports IPv6 (site.json ipv6)")

    args = parse_with_globals(parser, {
        "firewall": "firewall.mgmt.internal", "port": None,
        "credential_file": None, "no_ssl_verify": False,
        "debug": False, "check_mode": False,
    })
    if not args.command:
        parser.print_help()
        sys.exit(1)

    try:
        with _client(args) as mgr:
            if args.command == "status":
                print(f"ipv6: firewall allows IPv6: {_yn(read_allowed(mgr))}")
                ok = True
            else:
                ip = _probe_ip(args.firewall)
                ok = converge(
                    mgr, args.allow, args.check_mode,
                    restart=lambda: unbound_restart(ip),
                    resolver_ok=lambda: check_unbound_dns(host=ip, label="POST-IPV6", retries=10, delay=3.0),
                    reload_filter=lambda: filter_reload(ip),
                )
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: {exc}", file=sys.stderr)
        if args.debug:
            raise
        sys.exit(1)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
