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

    # Set credentials via file or environment
    export OPNSENSE_CREDENTIAL_FILE="/path/to/credentials.txt"
    # Or use token/secret directly
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


def example_create_single_vlan(manager: VlanManager, check_mode: bool = True) -> None:
    """Create a single VLAN."""
    print(f"\nCreating single VLAN (check_mode={check_mode})...")

    vlan = Vlan(
        description="Management VLAN",
        tag=10,
        interface="igb0",  # Change to your interface
        priority=0,
    )

    result = manager.create_vlan(vlan, check_mode=check_mode)
    print(f"  Result: {result}")


def example_create_multiple_vlans(manager: VlanManager, check_mode: bool = True) -> None:
    """Create multiple VLANs for a typical network setup."""
    print(f"\nCreating multiple VLANs (check_mode={check_mode})...")

    vlans = [
        Vlan(description="Management", tag=10, interface="igb0"),
        Vlan(description="Servers", tag=20, interface="igb0"),
        Vlan(description="Workstations", tag=30, interface="igb0"),
        Vlan(description="IoT Devices", tag=40, interface="igb0"),
        Vlan(description="Guest Network", tag=50, interface="igb0"),
        Vlan(description="DMZ", tag=100, interface="igb0"),
    ]

    results = manager.create_multiple_vlans(vlans, check_mode=check_mode)
    for vlan, result in zip(vlans, results):
        print(f"  VLAN {vlan.tag} ({vlan.description}): {result}")


def example_update_vlan(manager: VlanManager, check_mode: bool = True) -> None:
    """Update an existing VLAN."""
    print(f"\nUpdating VLAN (check_mode={check_mode})...")

    # Update the Management VLAN to use priority 7 (highest)
    vlan = Vlan(
        description="Management",
        tag=10,
        interface="igb0",
        priority=7,  # Changed from default 0
    )

    result = manager.update_vlan(vlan, match_fields=["description"], check_mode=check_mode)
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
        choices=["all", "test", "list", "spec", "create", "create-multi", "update", "delete"],
        default="all",
        help="Which example to run (default: all)",
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

        config = Config(
            firewall=firewall,
            credential_file=args.credential_file,
            ssl_verify=not args.no_ssl_verify,
            debug=args.debug,
        )
    except ValueError as e:
        print(f"Configuration error: {e}")
        print("\nSet environment variables or use command line arguments.")
        print("See --help for details.")
        sys.exit(1)

    # Run examples
    with VlanManager(config) as manager:
        examples = {
            "test": lambda: example_test_connection(manager),
            "list": lambda: example_list_modules(manager),
            "spec": lambda: example_show_vlan_spec(manager),
            "create": lambda: example_create_single_vlan(manager, check_mode),
            "create-multi": lambda: example_create_multiple_vlans(manager, check_mode),
            "update": lambda: example_update_vlan(manager, check_mode),
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
