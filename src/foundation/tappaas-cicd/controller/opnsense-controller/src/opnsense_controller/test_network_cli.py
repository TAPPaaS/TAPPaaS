#!/usr/bin/env python3
"""CLI for the OPNsense side of the TAPPaaS test network (issue #225).

Drives :class:`TestNetworkManager` to assign a dedicated physical device to an
isolated test network, serve DHCP on it and install the routing/firewall
policy (test→internet, mgmt→test, isolate everything else).

The Proxmox-side work (find a vacant port, create the bridge, attach the NIC to
the firewall VM) is done by ``src/foundation/firewall/test-network.sh``, which
shells out to this CLI for the OPNsense steps.

Usage:
    test-network-manager create --device vtnet2 [--cidr 172.17.3.1/24]
    test-network-manager delete --device vtnet2
    test-network-manager status --device vtnet2
    # add --check-mode to any command for a dry run
"""

import argparse
import json
import os
import sys

from .config import Config
from .test_network_manager import TestNetworkManager


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


def _build_manager(args) -> TestNetworkManager:
    return TestNetworkManager(
        config=get_config(args),
        device=args.device,
        cidr=args.cidr,
        dhcp_start=args.dhcp_start,
        dhcp_end=args.dhcp_end,
        mgmt_net=args.mgmt_net,
        mgmt_iface=args.mgmt_iface,
        domain=args.domain,
    )


def _emit(args, payload: dict) -> int:
    if args.json:
        print(json.dumps(payload, indent=2))
    else:
        for key, value in payload.items():
            print(f"{key}: {value}")
    return 0


def cmd_create(args) -> int:
    try:
        mgr = _build_manager(args)
        return _emit(args, mgr.create(check_mode=args.check_mode))
    except Exception as e:  # noqa: BLE001 - surface to CLI
        if args.json:
            print(json.dumps({"error": str(e)}))
        else:
            print(f"Error creating test network: {e}", file=sys.stderr)
        return 1


def cmd_delete(args) -> int:
    try:
        mgr = _build_manager(args)
        return _emit(args, mgr.delete(check_mode=args.check_mode))
    except Exception as e:  # noqa: BLE001 - surface to CLI
        if args.json:
            print(json.dumps({"error": str(e)}))
        else:
            print(f"Error deleting test network: {e}", file=sys.stderr)
        return 1


def cmd_status(args) -> int:
    try:
        mgr = _build_manager(args)
        return _emit(args, mgr.status())
    except Exception as e:  # noqa: BLE001 - surface to CLI
        if args.json:
            print(json.dumps({"error": str(e)}))
        else:
            print(f"Error reading test network status: {e}", file=sys.stderr)
        return 1


def add_common_args(parser: argparse.ArgumentParser) -> None:
    """Connection + addressing arguments shared by all subcommands."""
    parser.add_argument(
        "--device", required=True,
        help="Guest network device backing the test net (e.g. vtnet2)",
    )
    parser.add_argument(
        "--cidr", default="172.17.3.1/24",
        help="Test-net gateway address + prefix (default: 172.17.3.1/24)",
    )
    parser.add_argument("--dhcp-start", default=None, help="DHCP pool start (default: .50)")
    parser.add_argument("--dhcp-end", default=None, help="DHCP pool end (default: .250)")
    parser.add_argument(
        "--mgmt-net", default="10.0.0.0/24",
        help="Management network allowed to initiate to the test net",
    )
    parser.add_argument(
        "--mgmt-iface", default="lan",
        help="OPNsense interface the mgmt net arrives on (default: lan)",
    )
    parser.add_argument("--domain", default="test.internal", help="DHCP domain")
    parser.add_argument(
        "--firewall", default="firewall.mgmt.internal",
        help="Firewall IP/hostname (default: firewall.mgmt.internal)",
    )
    parser.add_argument(
        "--port", type=int, default=None,
        help="API port (default: auto-detect by probing 443, then 8443)",
    )
    parser.add_argument("--credential-file", help="Path to credential file")
    parser.add_argument("--no-ssl-verify", action="store_true",
                        help="Disable SSL certificate verification")
    parser.add_argument("--debug", action="store_true", help="Enable debug logging")
    parser.add_argument("--json", action="store_true", help="Output in JSON format")
    parser.add_argument("--check-mode", action="store_true",
                        help="Dry run: report planned changes without applying")


def main():
    parser = argparse.ArgumentParser(
        description="OPNsense test-network manager (TAPPaaS issue #225)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    create_parser = subparsers.add_parser("create", help="Create the test network")
    add_common_args(create_parser)
    create_parser.set_defaults(func=cmd_create)

    delete_parser = subparsers.add_parser("delete", help="Tear down the test network")
    add_common_args(delete_parser)
    delete_parser.set_defaults(func=cmd_delete)

    status_parser = subparsers.add_parser("status", help="Show test network status")
    add_common_args(status_parser)
    status_parser.set_defaults(func=cmd_status)

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        return 1
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
