#!/usr/bin/env python3
"""unbound-manager — manage OPNsense Unbound host overrides (ADR-005 #316, #269).

Unbound is the resolver TAPPaaS clients query on 10.0.0.1:53. Split-horizon DNS
for PUBLIC domains (e.g. *.tappaas.org -> the DMZ gateway where Caddy listens)
must live in Unbound Host Overrides, NOT in Dnsmasq host entries (which Unbound
does not serve for public domains, and which cannot express a wildcard). The
hostname "*" is a valid wildcard host override in Unbound.

Commands:
  unbound-manager add <hostname> <domain> <ip> [--description ...]
  unbound-manager delete <hostname> <domain>
  unbound-manager list

`*` is a valid hostname (wildcard). Changes reload Unbound automatically.
"""

import argparse
import sys

from .config import Config
from .dhcp_manager import DhcpManager  # reused only as a connected-Client provider


def _client(args):
    """Build a connected oxl Client from CLI args (same shape as dns-manager)."""
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


def add_override(args) -> bool:
    desc = args.description or f"{args.hostname}.{args.domain}"
    with _client(args) as mgr:
        result = mgr.client.run_module(
            "unbound_host",
            check_mode=args.check_mode,
            params={
                "hostname": args.hostname,
                "domain": args.domain,
                "record_type": "A",
                "value": args.ip,
                "description": desc,
                "state": "present",
            },
        )
    if result.get("error"):
        print(f"ERROR: {result['error']}", file=sys.stderr)
        return False
    changed = (result.get("result") or {}).get("changed")
    print(f"{'Created/updated' if changed else 'Already up to date'}: "
          f"{args.hostname}.{args.domain} -> {args.ip} (Unbound host override)")
    return True


def delete_override(args) -> bool:
    with _client(args) as mgr:
        result = mgr.client.run_module(
            "unbound_host",
            check_mode=args.check_mode,
            params={
                "hostname": args.hostname,
                "domain": args.domain,
                "record_type": "A",
                "state": "absent",
                # Match without `value` (we don't know the IP at delete time);
                # the default match_fields includes value, which would never match.
                "match_fields": ["hostname", "domain", "record_type"],
            },
        )
    if result.get("error"):
        print(f"ERROR: {result['error']}", file=sys.stderr)
        return False
    changed = (result.get("result") or {}).get("changed")
    print(f"{'Deleted' if changed else 'Not present'}: {args.hostname}.{args.domain}")
    return True


def list_overrides(args) -> bool:
    with _client(args) as mgr:
        result = mgr.client.run_module(
            "raw",
            params={
                "module": "unbound",
                "controller": "settings",
                "command": "searchHostOverride",
                "action": "get",
            },
        )
    rows = result.get("result", {}).get("response", {}).get("rows", [])
    if not rows:
        print("No Unbound host overrides.")
        return True
    print(f"{'HOST':<20} {'DOMAIN':<28} {'TYPE':<6} {'VALUE':<16} DESCRIPTION")
    for r in rows:
        print(f"{r.get('hostname',''):<20} {r.get('domain',''):<28} "
              f"{r.get('rr',''):<6} {r.get('server',''):<16} {r.get('description','')}")
    return True


def main():
    parser = argparse.ArgumentParser(
        description="OPNsense Unbound host-override management (split-horizon DNS)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  unbound-manager add '*' tappaas.org 10.6.0.1 --description "wildcard -> Caddy (DMZ)"
  unbound-manager add nextcloud tappaas.org 10.6.0.1
  unbound-manager delete nextcloud tappaas.org
  unbound-manager list
""",
    )
    parser.add_argument("--firewall", default="firewall.mgmt.internal",
                        help="Firewall IP/hostname (default: firewall.mgmt.internal)")
    parser.add_argument("--port", type=int, default=None, help="API port (default: probe 443/8443)")
    parser.add_argument("--credential-file", help="Path to credential file")
    parser.add_argument("--no-ssl-verify", action="store_true", help="Disable SSL verification")
    parser.add_argument("--debug", action="store_true", help="Enable debug logging")
    parser.add_argument("--check-mode", action="store_true", help="Dry-run (no changes)")

    sub = parser.add_subparsers(dest="command", help="Command")

    p_add = sub.add_parser("add", help="Add/update an Unbound host override")
    p_add.add_argument("hostname", help="Hostname (use '*' for a wildcard)")
    p_add.add_argument("domain", help="Domain (e.g., tappaas.org)")
    p_add.add_argument("ip", help="IP address (A record target)")
    p_add.add_argument("--description", help="Description (default: hostname.domain)")

    p_del = sub.add_parser("delete", help="Delete an Unbound host override")
    p_del.add_argument("hostname", help="Hostname (use '*' for a wildcard)")
    p_del.add_argument("domain", help="Domain")

    sub.add_parser("list", help="List Unbound host overrides")

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        sys.exit(1)

    try:
        if args.command == "add":
            ok = add_override(args)
        elif args.command == "delete":
            ok = delete_override(args)
        elif args.command == "list":
            ok = list_overrides(args)
        else:
            parser.print_help()
            ok = False
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: {exc}", file=sys.stderr)
        if args.debug:
            raise
        sys.exit(1)

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
