#!/usr/bin/env python3
"""OPNsense Controller for TAPPaaS.

This script demonstrates how to use the oxl-opnsense-client library
to manage VLANs on an OPNsense firewall.

Usage:
    # Run with default firewall (firewall.mgmt.internal)
    python -m opnsense_controller.main

    # Specify a different firewall
    python -m opnsense_controller.main --firewall 10.0.0.1

    # Or override via environment variable
    export OPNSENSE_HOST="10.0.0.1"
    python -m opnsense_controller.main

    # Credentials are loaded from (in order of priority):
    # 1. --credential-file CLI option
    # 2. OPNSENSE_CREDENTIAL_FILE environment variable
    # 3. $HOME/.opnsense-credentials.txt (default)
    #
    # Or use token/secret directly via environment:
    export OPNSENSE_TOKEN="your-api-token"
    export OPNSENSE_SECRET="your-api-secret"
"""

import argparse
import os
import sys

from .config import Config
from .vlan_manager import Vlan, VlanManager


def example_test_connection(manager: VlanManager) -> None:
    """Test the connection to OPNsense."""
    print("Testing connection...")
    if manager.test_connection():
        print("  Connection successful!")
    else:
        print("  Connection failed!")
        sys.exit(1)


def example_list_modules(manager: VlanManager) -> None:
    """List available modules (filtered to interface-related)."""
    print("\nAvailable interface modules:")
    modules = manager.list_modules()
    interface_modules = [m for m in modules if "interface" in m.lower()]
    for module in sorted(interface_modules):
        print(f"  - {module}")


def example_show_vlan_spec(manager: VlanManager) -> None:
    """Show the VLAN module specification."""
    print("\nVLAN module specification:")
    spec = manager.get_vlan_spec()
    print(f"  {spec}")


def example_show_assigned_vlans(manager: VlanManager) -> None:
    """Show VLANs that are assigned to interfaces."""
    print("\nAssigned VLANs:")
    vlans = manager.get_assigned_vlans()
    if not vlans:
        print("  No VLANs are currently assigned to interfaces")
    else:
        for vlan in vlans:
            status = "enabled" if vlan["enabled"] else "disabled"
            print(
                f"  VLAN {vlan['vlan_tag']}: {vlan['device']} -> "
                f"{vlan['identifier']} ({vlan['description']}) [{status}]"
            )


def example_create_single_vlan(
    manager: VlanManager,
    check_mode: bool = True,
    interface: str = "vtnet0",
    assign: bool = False,
) -> None:
    """Create a single VLAN device and optionally assign it."""
    print(f"\nCreating single VLAN (check_mode={check_mode}, interface={interface}, assign={assign})...")

    vlan = Vlan(
        description="Management VLAN",
        tag=10,
        interface=interface,
        priority=0,
    )

    result = manager.create_vlan(vlan, check_mode=check_mode, assign=assign)
    changed = result.get("result", {}).get("diff", {}).get("before") is None
    if changed and not check_mode:
        print("  VLAN device created successfully")
        if assign and result.get("ifname"):
            print(f"  Assigned to interface: {result['ifname']}")
    else:
        print(f"  Result: {result}")


def example_create_multiple_vlans(
    manager: VlanManager,
    check_mode: bool = True,
    interface: str = "vtnet0",
    assign: bool = False,
) -> None:
    """Create multiple VLANs for a typical network setup."""
    print(f"\nCreating multiple VLANs (check_mode={check_mode}, interface={interface}, assign={assign})...")

    vlans = [
        Vlan(description="Management", tag=10, interface=interface),
        Vlan(description="Servers", tag=20, interface=interface),
        Vlan(description="Workstations", tag=30, interface=interface),
        Vlan(description="IoT Devices", tag=40, interface=interface),
        Vlan(description="Guest Network", tag=50, interface=interface),
        Vlan(description="DMZ", tag=100, interface=interface),
    ]

    results = manager.create_multiple_vlans(vlans, check_mode=check_mode, assign=assign)
    for vlan, result in zip(vlans, results):
        ifname = result.get("ifname", "not assigned")
        print(f"  VLAN {vlan.tag} ({vlan.description}): ifname={ifname}")


def example_update_vlan(
    manager: VlanManager, check_mode: bool = True, interface: str = "vtnet0"
) -> None:
    """Update an existing VLAN."""
    print(f"\nUpdating VLAN (check_mode={check_mode}, interface={interface})...")

    # Update the Management VLAN to use priority 7 (highest)
    vlan = Vlan(
        description="Management",
        tag=10,
        interface=interface,
        priority=7,  # Changed from default 0
    )

    result = manager.update_vlan(vlan, check_mode=check_mode)
    print(f"  Result: {result}")


def example_delete_vlan(manager: VlanManager, check_mode: bool = True) -> None:
    """Delete a VLAN."""
    print(f"\nDeleting VLAN (check_mode={check_mode})...")

    result = manager.delete_vlan("Guest Network", check_mode=check_mode)
    print(f"  Result: {result}")


def main():
    """Run the OPNsense controller examples."""
    parser = argparse.ArgumentParser(
        description="OPNsense Controller for TAPPaaS",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Actually execute changes (default is check/dry-run mode)",
    )
    parser.add_argument(
        "--firewall",
        default="firewall.mgmt.internal",
        help="Firewall IP/hostname (default: firewall.mgmt.internal, overrides OPNSENSE_HOST env var)",
    )
    parser.add_argument(
        "--credential-file",
        help="Path to credential file (overrides OPNSENSE_CREDENTIAL_FILE env var)",
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
        "--example",
        choices=["all", "test", "list", "spec", "assigned", "create", "create-multi", "update", "delete"],
        default="all",
        help="Which example to run (default: all)",
    )
    parser.add_argument(
        "--interface",
        default="vtnet0",
        help="Parent interface for VLAN examples (default: vtnet0). Use actual interface name, not OPNsense label.",
    )
    parser.add_argument(
        "--assign",
        action="store_true",
        help="Assign created VLANs to interfaces and enable them (requires custom PHP extension)",
    )

    args = parser.parse_args()
    check_mode = not args.execute

    if check_mode:
        print("=" * 60)
        print("RUNNING IN CHECK MODE (dry-run) - no changes will be made")
        print("Use --execute to actually make changes")
        print("=" * 60)

    # Build configuration
    # Priority: CLI --firewall > OPNSENSE_HOST env var > default
    try:
        firewall = os.environ.get("OPNSENSE_HOST", args.firewall)
        # If user explicitly passed --firewall, use that over env var
        if args.firewall != "firewall.mgmt.internal":
            firewall = args.firewall

        # Build config kwargs, only including credential_file if explicitly provided
        config_kwargs = {
            "firewall": firewall,
            "ssl_verify": not args.no_ssl_verify,
            "debug": args.debug,
        }
        if args.credential_file:
            config_kwargs["credential_file"] = args.credential_file

        config = Config(**config_kwargs)
    except ValueError as e:
        print(f"Configuration error: {e}")
        print("\nSet environment variables or use command line arguments.")
        print("See --help for details.")
        sys.exit(1)

    # Run examples
    with VlanManager(config) as manager:
        interface = args.interface
        assign = args.assign
        examples = {
            "test": lambda: example_test_connection(manager),
            "list": lambda: example_list_modules(manager),
            "spec": lambda: example_show_vlan_spec(manager),
            "assigned": lambda: example_show_assigned_vlans(manager),
            "create": lambda: example_create_single_vlan(manager, check_mode, interface, assign),
            "create-multi": lambda: example_create_multiple_vlans(manager, check_mode, interface, assign),
            "update": lambda: example_update_vlan(manager, check_mode, interface),
            "delete": lambda: example_delete_vlan(manager, check_mode),
        }

        if args.example == "all":
            for name, func in examples.items():
                try:
                    func()
                except Exception as e:
                    print(f"  Error in {name}: {e}")
        else:
            examples[args.example]()


if __name__ == "__main__":
    main()
