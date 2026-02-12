#!/usr/bin/env python3
"""CLI for OPNsense firewall rule management.

This module provides a command-line interface for managing firewall rules
on OPNsense. It supports creating, listing, and deleting firewall rules.

Usage:
    opnsense-firewall create-rule --description "Allow HTTPS" --interface wan --protocol TCP --destination-port 443
    opnsense-firewall list-rules
    opnsense-firewall delete-rule --description "Allow HTTPS"
    opnsense-firewall apply
"""

import argparse
import json
import os
import sys

from .config import Config
from .firewall_manager import (
    FirewallManager,
    FirewallRule,
    IpProtocol,
    Protocol,
    RuleAction,
    RuleDirection,
)


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
    if args.credential_file:
        config_kwargs["credential_file"] = args.credential_file

    return Config(**config_kwargs)


def cmd_create_rule(args) -> int:
    """Create a firewall rule."""
    config = get_config(args)

    # Map CLI protocol to enum
    protocol_map = {
        "any": Protocol.ANY,
        "tcp": Protocol.TCP,
        "udp": Protocol.UDP,
        "tcp/udp": Protocol.TCP_UDP,
        "icmp": Protocol.ICMP,
    }
    protocol = protocol_map.get(args.protocol.lower(), Protocol.ANY)

    # Map CLI action to enum
    action_map = {
        "pass": RuleAction.PASS,
        "block": RuleAction.BLOCK,
        "reject": RuleAction.REJECT,
    }
    action = action_map.get(args.action.lower(), RuleAction.PASS)

    # Map CLI direction to enum
    direction_map = {
        "in": RuleDirection.IN,
        "out": RuleDirection.OUT,
    }
    direction = direction_map.get(args.direction.lower(), RuleDirection.IN)

    # Map CLI ip_protocol to enum
    ip_protocol_map = {
        "inet": IpProtocol.IPV4,
        "inet6": IpProtocol.IPV6,
        "inet46": IpProtocol.BOTH,
    }
    ip_protocol = ip_protocol_map.get(args.ip_protocol.lower(), IpProtocol.IPV4)

    rule = FirewallRule(
        description=args.description,
        action=action,
        interface=args.interface,
        direction=direction,
        ip_protocol=ip_protocol,
        protocol=protocol,
        source_net=args.source,
        source_port=args.source_port,
        destination_net=args.destination,
        destination_port=args.destination_port,
        log=args.log,
        enabled=not args.disabled,
        sequence=args.sequence,
    )

    try:
        with FirewallManager(config) as manager:
            # Check if rule already exists
            existing = manager.get_rule_by_description(args.description)
            if existing and not args.force:
                print(f"Rule already exists: {args.description}")
                if args.json:
                    print(json.dumps({"status": "exists", "uuid": existing.uuid}))
                return 0

            result = manager.create_rule(rule, apply=not args.no_apply)

            if args.json:
                print(json.dumps(result))
            else:
                print(f"Created rule: {args.description}")
                if result.get("result", {}).get("diff", {}).get("after"):
                    print("  Rule applied successfully")

            return 0
    except Exception as e:
        if args.json:
            print(json.dumps({"error": str(e)}))
        else:
            print(f"Error creating rule: {e}", file=sys.stderr)
        return 1


def cmd_list_rules(args) -> int:
    """List firewall rules."""
    config = get_config(args)

    try:
        with FirewallManager(config) as manager:
            rules = manager.list_rules(args.search or "")

            if args.json:
                rules_list = [
                    {
                        "uuid": r.uuid,
                        "description": r.description,
                        "enabled": r.enabled,
                        "action": r.action,
                        "interface": r.interface,
                        "protocol": r.protocol,
                        "source_net": r.source_net,
                        "source_port": r.source_port,
                        "destination_net": r.destination_net,
                        "destination_port": r.destination_port,
                        "log": r.log,
                    }
                    for r in rules
                ]
                print(json.dumps(rules_list, indent=2))
            else:
                if not rules:
                    print("No firewall rules found")
                else:
                    for rule in rules:
                        status = "enabled" if rule.enabled else "disabled"
                        action = rule.action.upper()
                        src_port = rule.source_port or "*"
                        dst_port = rule.destination_port or "*"
                        print(
                            f"[{status}] {action} {rule.protocol} "
                            f"{rule.source_net}:{src_port} -> "
                            f"{rule.destination_net}:{dst_port} "
                            f"on {rule.interface} ({rule.description})"
                        )

            return 0
    except Exception as e:
        if args.json:
            print(json.dumps({"error": str(e)}))
        else:
            print(f"Error listing rules: {e}", file=sys.stderr)
        return 1


def cmd_delete_rule(args) -> int:
    """Delete a firewall rule."""
    config = get_config(args)

    try:
        with FirewallManager(config) as manager:
            if args.uuid:
                result = manager.delete_rule_by_uuid(args.uuid, apply=not args.no_apply)
            else:
                result = manager.delete_rule(args.description, apply=not args.no_apply)

            if args.json:
                print(json.dumps(result))
            else:
                print(f"Deleted rule: {args.description or args.uuid}")

            return 0
    except Exception as e:
        if args.json:
            print(json.dumps({"error": str(e)}))
        else:
            print(f"Error deleting rule: {e}", file=sys.stderr)
        return 1


def cmd_apply(args) -> int:
    """Apply pending firewall changes."""
    config = get_config(args)

    try:
        with FirewallManager(config) as manager:
            result = manager.apply_changes()

            if args.json:
                print(json.dumps(result))
            else:
                print("Firewall changes applied")

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
        with FirewallManager(config) as manager:
            if manager.test_connection():
                if args.json:
                    print(json.dumps({"status": "ok", "firewall": config.firewall}))
                else:
                    print(f"Connection to {config.firewall} successful")
                return 0
            else:
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
        "--credential-file",
        help="Path to credential file",
    )
    parser.add_argument(
        "--no-ssl-verify",
        action="store_true",
        help="Disable SSL certificate verification",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Enable debug logging",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output in JSON format",
    )


def main():
    """Main entry point for the firewall CLI."""
    parser = argparse.ArgumentParser(
        description="OPNsense Firewall Rule Manager",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    # create-rule command
    create_parser = subparsers.add_parser(
        "create-rule",
        help="Create a firewall rule",
        description="Create a new firewall rule on OPNsense",
    )
    add_common_args(create_parser)
    create_parser.add_argument(
        "--description", "-d",
        required=True,
        help="Rule description (used as identifier)",
    )
    create_parser.add_argument(
        "--interface", "-i",
        required=True,
        help="Interface name (e.g., wan, lan, opt1)",
    )
    create_parser.add_argument(
        "--action", "-a",
        choices=["pass", "block", "reject"],
        default="pass",
        help="Rule action (default: pass)",
    )
    create_parser.add_argument(
        "--direction",
        choices=["in", "out"],
        default="in",
        help="Traffic direction (default: in)",
    )
    create_parser.add_argument(
        "--ip-protocol",
        choices=["inet", "inet6", "inet46"],
        default="inet",
        help="IP protocol version (default: inet/IPv4)",
    )
    create_parser.add_argument(
        "--protocol", "-p",
        choices=["any", "tcp", "udp", "tcp/udp", "icmp"],
        default="any",
        help="Network protocol (default: any)",
    )
    create_parser.add_argument(
        "--source", "-s",
        default="any",
        help="Source network/host (default: any)",
    )
    create_parser.add_argument(
        "--source-port",
        help="Source port",
    )
    create_parser.add_argument(
        "--destination", "-D",
        default="any",
        help="Destination network/host (default: any)",
    )
    create_parser.add_argument(
        "--destination-port", "-P",
        help="Destination port",
    )
    create_parser.add_argument(
        "--log/--no-log",
        dest="log",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Enable logging (default: enabled)",
    )
    create_parser.add_argument(
        "--disabled",
        action="store_true",
        help="Create rule in disabled state",
    )
    create_parser.add_argument(
        "--sequence",
        type=int,
        help="Rule sequence/priority (lower = higher priority)",
    )
    create_parser.add_argument(
        "--force", "-f",
        action="store_true",
        help="Overwrite existing rule with same description",
    )
    create_parser.add_argument(
        "--no-apply",
        action="store_true",
        help="Don't apply changes immediately",
    )
    create_parser.set_defaults(func=cmd_create_rule)

    # list-rules command
    list_parser = subparsers.add_parser(
        "list-rules",
        help="List firewall rules",
        description="List all firewall rules on OPNsense",
    )
    add_common_args(list_parser)
    list_parser.add_argument(
        "--search",
        help="Filter rules by description",
    )
    list_parser.set_defaults(func=cmd_list_rules)

    # delete-rule command
    delete_parser = subparsers.add_parser(
        "delete-rule",
        help="Delete a firewall rule",
        description="Delete a firewall rule on OPNsense",
    )
    add_common_args(delete_parser)
    delete_group = delete_parser.add_mutually_exclusive_group(required=True)
    delete_group.add_argument(
        "--description", "-d",
        help="Rule description to delete",
    )
    delete_group.add_argument(
        "--uuid",
        help="Rule UUID to delete",
    )
    delete_parser.add_argument(
        "--no-apply",
        action="store_true",
        help="Don't apply changes immediately",
    )
    delete_parser.set_defaults(func=cmd_delete_rule)

    # apply command
    apply_parser = subparsers.add_parser(
        "apply",
        help="Apply pending firewall changes",
        description="Apply any pending firewall configuration changes",
    )
    add_common_args(apply_parser)
    apply_parser.set_defaults(func=cmd_apply)

    # test command
    test_parser = subparsers.add_parser(
        "test",
        help="Test connection to OPNsense",
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
