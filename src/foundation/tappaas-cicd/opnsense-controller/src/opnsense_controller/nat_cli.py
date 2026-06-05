#!/usr/bin/env python3
"""CLI for OPNsense destination-NAT (port-forward) management.

Manages "Firewall → NAT → Port Forward" rules on OPNsense via the
``firewall/d_nat`` API. Each rule is an rdr-pass rule (translates AND allows),
so a single command exposes an internal service port on the firewall WAN.

Usage:
    nat-manager add-rule --description "TAPPaaS: forgejo SSH" \\
        --external-port 2022 --target 10.0.30.20 --internal-port 22 --protocol TCP
    nat-manager list-rules
    nat-manager delete-rule --description "TAPPaaS: forgejo SSH"
    nat-manager apply
"""

import argparse
import json
import os
import sys

from .config import Config
from .nat_manager import NatManager, NatRule


def get_config(args) -> Config:
    """Build configuration from CLI arguments and environment."""
    firewall = os.environ.get("OPNSENSE_HOST", args.firewall)
    if args.firewall != "firewall.mgmt.internal":
        firewall = args.firewall

    config_kwargs = {
        "firewall": firewall,
        "ssl_verify": not args.no_ssl_verify,
        "debug": args.debug,
    }
    if getattr(args, "port", None) is not None:
        config_kwargs["port"] = args.port
    if args.credential_file:
        config_kwargs["credential_file"] = args.credential_file

    try:
        return Config(**config_kwargs)
    except ValueError as e:
        print(f"Configuration error: {e}", file=sys.stderr)
        sys.exit(1)


def cmd_add_rule(args) -> int:
    """Create or update a port-forward rule."""
    config = get_config(args)

    rule = NatRule(
        description=args.description,
        external_port=args.external_port,
        internal_port=args.internal_port,
        target=args.target,
        protocol=args.protocol.upper() if args.protocol.lower() != "tcp/udp" else "TCP/UDP",
        interface=args.interface,
        destination_net=args.destination,
        source_net=args.source,
        ip_protocol=args.ip_protocol,
        enabled=not args.disabled,
    )

    try:
        with NatManager(config) as manager:
            result = manager.add_rule(rule, apply=not args.no_apply)
            if args.json:
                print(json.dumps(result))
            else:
                print(
                    f"Port-forward set: {args.interface}:{args.external_port} "
                    f"-> {args.target}:{args.internal_port} ({args.protocol}) "
                    f"[{args.description}]"
                )
            return 0
    except Exception as e:
        if args.json:
            print(json.dumps({"error": str(e)}))
        else:
            print(f"Error creating port-forward: {e}", file=sys.stderr)
        return 1


def cmd_list_rules(args) -> int:
    """List port-forward rules."""
    config = get_config(args)

    try:
        with NatManager(config) as manager:
            rules = manager.list_rules(args.search or "")

            if args.json:
                print(
                    json.dumps(
                        [
                            {
                                "uuid": r.uuid,
                                "description": r.description,
                                "enabled": r.enabled,
                                "interface": r.interface,
                                "protocol": r.protocol,
                                "destination_net": r.destination_net,
                                "destination_port": r.destination_port,
                                "target": r.target,
                                "local_port": r.local_port,
                            }
                            for r in rules
                        ],
                        indent=2,
                    )
                )
            else:
                if not rules:
                    print("No port-forward rules found")
                else:
                    for r in rules:
                        status = "enabled" if r.enabled else "disabled"
                        print(
                            f"[{status}] {r.protocol} "
                            f"{r.interface}:{r.destination_port} -> "
                            f"{r.target}:{r.local_port} ({r.description})"
                        )
            return 0
    except Exception as e:
        if args.json:
            print(json.dumps({"error": str(e)}))
        else:
            print(f"Error listing port-forwards: {e}", file=sys.stderr)
        return 1


def cmd_delete_rule(args) -> int:
    """Delete a port-forward rule."""
    config = get_config(args)

    try:
        with NatManager(config) as manager:
            if args.uuid:
                result = manager.delete_rule_by_uuid(args.uuid, apply=not args.no_apply)
            else:
                result = manager.delete_rule(args.description, apply=not args.no_apply)

            if args.json:
                print(json.dumps(result))
            else:
                print(f"Deleted port-forward: {args.description or args.uuid}")
            return 0
    except Exception as e:
        if args.json:
            print(json.dumps({"error": str(e)}))
        else:
            print(f"Error deleting port-forward: {e}", file=sys.stderr)
        return 1


def cmd_apply(args) -> int:
    """Apply pending port-forward changes."""
    config = get_config(args)

    try:
        with NatManager(config) as manager:
            result = manager.apply_changes()
            if args.json:
                print(json.dumps(result))
            else:
                print("Port-forward changes applied")
            return 0
    except Exception as e:
        if args.json:
            print(json.dumps({"error": str(e)}))
        else:
            print(f"Error applying changes: {e}", file=sys.stderr)
        return 1


def cmd_test(args) -> int:
    """Test connection to OPNsense."""
    config = get_config(args)

    try:
        with NatManager(config) as manager:
            if manager.test_connection():
                if args.json:
                    print(json.dumps({"status": "ok", "firewall": config.firewall}))
                else:
                    print(f"Connection to {config.firewall} successful")
                return 0
            if args.json:
                print(json.dumps({"status": "failed", "firewall": config.firewall}))
            else:
                print(f"Connection to {config.firewall} failed")
            return 1
    except Exception as e:
        if args.json:
            print(json.dumps({"error": str(e)}))
        else:
            print(f"Error: {e}", file=sys.stderr)
        return 1


def add_common_args(parser: argparse.ArgumentParser) -> None:
    """Add common arguments to a parser."""
    parser.add_argument(
        "--firewall",
        default="firewall.mgmt.internal",
        help="Firewall IP/hostname (default: firewall.mgmt.internal)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=None,
        help="API port (default: auto-detect by probing 443, then 8443)",
    )
    parser.add_argument("--credential-file", help="Path to credential file")
    parser.add_argument(
        "--no-ssl-verify",
        action="store_true",
        help="Disable SSL certificate verification",
    )
    parser.add_argument("--debug", action="store_true", help="Enable debug logging")
    parser.add_argument("--json", action="store_true", help="Output in JSON format")


def main():
    """Main entry point for the NAT CLI."""
    parser = argparse.ArgumentParser(
        description="OPNsense Destination-NAT (Port Forward) Manager",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    # add-rule command
    add_parser = subparsers.add_parser(
        "add-rule",
        help="Create or update a port-forward rule",
        description="Create or update a port-forward (destination-NAT) rule",
    )
    add_common_args(add_parser)
    add_parser.add_argument(
        "--description", "-d", required=True,
        help="Rule description (used as identifier for idempotency)",
    )
    add_parser.add_argument(
        "--external-port", "-e", required=True,
        help="External port exposed on the firewall interface (e.g. 2022)",
    )
    add_parser.add_argument(
        "--target", "-t", required=True,
        help="Internal target host IP (or alias) traffic is forwarded to",
    )
    add_parser.add_argument(
        "--internal-port", "-P", required=True,
        help="Internal service port on the target host (e.g. 22)",
    )
    add_parser.add_argument(
        "--protocol", "-p",
        choices=["tcp", "udp", "tcp/udp", "TCP", "UDP", "TCP/UDP"],
        default="TCP",
        help="Protocol (default: TCP)",
    )
    add_parser.add_argument(
        "--interface", "-i", default="wan",
        help="Firewall interface to listen on (default: wan)",
    )
    add_parser.add_argument(
        "--destination", "-D", default="wanip",
        help="Match destination network/address (default: wanip)",
    )
    add_parser.add_argument(
        "--source", "-s", default="any",
        help="Match source network/address (default: any)",
    )
    add_parser.add_argument(
        "--ip-protocol",
        choices=["inet", "inet6", "inet46"],
        default="inet",
        help="IP protocol version (default: inet/IPv4)",
    )
    add_parser.add_argument(
        "--disabled", action="store_true", help="Create rule in disabled state",
    )
    add_parser.add_argument(
        "--no-apply", action="store_true", help="Don't apply changes immediately",
    )
    add_parser.set_defaults(func=cmd_add_rule)

    # list-rules command
    list_parser = subparsers.add_parser(
        "list-rules", help="List port-forward rules",
        description="List all port-forward rules on OPNsense",
    )
    add_common_args(list_parser)
    list_parser.add_argument("--search", help="Filter rules by description")
    list_parser.set_defaults(func=cmd_list_rules)

    # delete-rule command
    delete_parser = subparsers.add_parser(
        "delete-rule", help="Delete a port-forward rule",
        description="Delete a port-forward rule on OPNsense",
    )
    add_common_args(delete_parser)
    delete_group = delete_parser.add_mutually_exclusive_group(required=True)
    delete_group.add_argument(
        "--description", "-d", help="Rule description to delete",
    )
    delete_group.add_argument("--uuid", help="Rule UUID to delete")
    delete_parser.add_argument(
        "--no-apply", action="store_true", help="Don't apply changes immediately",
    )
    delete_parser.set_defaults(func=cmd_delete_rule)

    # apply command
    apply_parser = subparsers.add_parser(
        "apply", help="Apply pending port-forward changes",
        description="Apply any pending port-forward configuration changes",
    )
    add_common_args(apply_parser)
    apply_parser.set_defaults(func=cmd_apply)

    # test command
    test_parser = subparsers.add_parser(
        "test", help="Test connection to OPNsense",
        description="Test the connection to OPNsense firewall",
    )
    add_common_args(test_parser)
    test_parser.set_defaults(func=cmd_test)

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        return 1

    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
