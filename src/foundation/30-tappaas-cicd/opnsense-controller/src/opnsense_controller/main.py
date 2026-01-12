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
from .dhcp_manager import DhcpHost, DhcpManager, DhcpRange
from .firewall_manager import FirewallManager, FirewallRule, Protocol, RuleAction
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


# =========================================================================
# DHCP Examples
# =========================================================================


def example_dhcp_test_connection(manager: DhcpManager) -> None:
    """Test the DHCP manager connection to OPNsense."""
    print("Testing DHCP manager connection...")
    if manager.test_connection():
        print("  Connection successful!")
    else:
        print("  Connection failed!")
        sys.exit(1)


def example_dhcp_show_specs(manager: DhcpManager) -> None:
    """Show DHCP-related module specifications."""
    print("\nDHCP module specifications:")
    print(f"  Range spec: {manager.get_range_spec()}")
    print(f"  Host spec: {manager.get_host_spec()}")
    print(f"  General spec: {manager.get_general_spec()}")


def example_dhcp_create_range(
    manager: DhcpManager,
    check_mode: bool = True,
    interface: str | None = None,
) -> None:
    """Create a DHCP range."""
    print(f"\nCreating DHCP range (check_mode={check_mode})...")

    dhcp_range = DhcpRange(
        description="Server Network DHCP",
        start_addr="10.21.0.100",
        end_addr="10.21.0.200",
        interface=interface,
        lease_time=86400,
        domain="srv.internal",
    )

    result = manager.create_range(dhcp_range, check_mode=check_mode)
    print(f"  Result: {result}")


def example_dhcp_create_multiple_ranges(
    manager: DhcpManager,
    check_mode: bool = True,
) -> None:
    """Create multiple DHCP ranges for typical TAPPaaS zones."""
    print(f"\nCreating multiple DHCP ranges (check_mode={check_mode})...")

    ranges = [
        DhcpRange(
            description="Private Network DHCP",
            start_addr="10.31.0.100",
            end_addr="10.31.0.250",
            domain="private.internal",
        ),
        DhcpRange(
            description="IoT Network DHCP",
            start_addr="10.41.0.100",
            end_addr="10.41.0.250",
            domain="iot.internal",
        ),
        DhcpRange(
            description="DMZ Network DHCP",
            start_addr="10.61.0.100",
            end_addr="10.61.0.200",
            domain="dmz.internal",
        ),
    ]

    results = manager.create_multiple_ranges(ranges, check_mode=check_mode)
    for dhcp_range, result in zip(ranges, results):
        print(f"  {dhcp_range.description}: {result}")


def example_dhcp_create_host(manager: DhcpManager, check_mode: bool = True) -> None:
    """Create a static DHCP host reservation."""
    print(f"\nCreating static DHCP host (check_mode={check_mode})...")

    host = DhcpHost(
        description="Nextcloud Server",
        host="nextcloud",
        ip=["10.21.0.10"],
        hardware_addr=["00:11:22:33:44:55"],
        domain="srv.internal",
    )

    result = manager.create_host(host, check_mode=check_mode)
    print(f"  Result: {result}")


def example_dhcp_create_multiple_hosts(
    manager: DhcpManager,
    check_mode: bool = True,
) -> None:
    """Create multiple static DHCP host reservations."""
    print(f"\nCreating multiple static DHCP hosts (check_mode={check_mode})...")

    hosts = [
        DhcpHost(
            description="Gitea Server",
            host="gitea",
            ip=["10.21.0.11"],
            domain="srv.internal",
        ),
        DhcpHost(
            description="Matrix Server",
            host="matrix",
            ip=["10.21.0.12"],
            domain="srv.internal",
        ),
        DhcpHost(
            description="HomeAssistant",
            host="homeassistant",
            ip=["10.41.0.10"],
            domain="iot.internal",
        ),
    ]

    results = manager.create_multiple_hosts(hosts, check_mode=check_mode)
    for host, result in zip(hosts, results):
        print(f"  {host.description}: {result}")


def example_dhcp_delete_host(manager: DhcpManager, check_mode: bool = True) -> None:
    """Delete a DHCP host reservation."""
    print(f"\nDeleting DHCP host (check_mode={check_mode})...")

    result = manager.delete_host("Matrix Server", check_mode=check_mode)
    print(f"  Result: {result}")


def example_dhcp_enable_service(
    manager: DhcpManager,
    check_mode: bool = True,
    interfaces: list[str] | None = None,
) -> None:
    """Enable and configure the Dnsmasq DHCP service."""
    print(f"\nEnabling Dnsmasq service (check_mode={check_mode})...")

    result = manager.enable_service(
        interfaces=interfaces,
        dhcp_authoritative=True,
        check_mode=check_mode,
    )
    print(f"  Result: {result}")


def example_dhcp_configure_general(
    manager: DhcpManager,
    check_mode: bool = True,
) -> None:
    """Configure general Dnsmasq settings."""
    print(f"\nConfiguring Dnsmasq general settings (check_mode={check_mode})...")

    result = manager.configure_general(
        enabled=True,
        dhcp_authoritative=True,
        dhcp_fqdn=True,
        regdhcp=True,
        regdhcpstatic=True,
        check_mode=check_mode,
    )
    print(f"  Result: {result}")


# =========================================================================
# Firewall Examples
# =========================================================================


def example_firewall_test_connection(manager: FirewallManager) -> None:
    """Test the firewall manager connection to OPNsense."""
    print("Testing firewall manager connection...")
    if manager.test_connection():
        print("  Connection successful!")
    else:
        print("  Connection failed!")
        sys.exit(1)


def example_firewall_show_spec(manager: FirewallManager) -> None:
    """Show firewall rule module specification."""
    print("\nFirewall rule module specification:")
    print(f"  {manager.get_rule_spec()}")


def example_firewall_list_rules(manager: FirewallManager) -> None:
    """List all firewall rules."""
    print("\nFirewall rules:")
    rules = manager.list_rules()
    if not rules:
        print("  No firewall rules found")
    else:
        for rule in rules:
            status = "enabled" if rule.enabled else "disabled"
            action = rule.action.upper()
            print(
                f"  [{status}] {action} {rule.protocol} "
                f"{rule.source_net}:{rule.source_port or '*'} -> "
                f"{rule.destination_net}:{rule.destination_port or '*'} "
                f"on {rule.interface} ({rule.description})"
            )


def example_firewall_create_rule(
    manager: FirewallManager,
    check_mode: bool = True,
    interface: str = "lan",
) -> None:
    """Create a single firewall rule."""
    print(f"\nCreating firewall rule (check_mode={check_mode})...")

    rule = FirewallRule(
        description="Allow SSH from management",
        action=RuleAction.PASS,
        interface=interface,
        protocol=Protocol.TCP,
        source_net="10.0.0.0/24",
        destination_port="22",
        log=True,
    )

    if check_mode:
        print(f"  Would create rule: {rule}")
    else:
        result = manager.create_rule(rule)
        print(f"  Result: {result}")


def example_firewall_create_multiple_rules(
    manager: FirewallManager,
    check_mode: bool = True,
    interface: str = "lan",
) -> None:
    """Create multiple firewall rules for typical TAPPaaS setup."""
    print(f"\nCreating multiple firewall rules (check_mode={check_mode})...")

    rules = [
        FirewallRule(
            description="Allow DNS",
            action=RuleAction.PASS,
            interface=interface,
            protocol=Protocol.UDP,
            destination_port="53",
        ),
        FirewallRule(
            description="Allow HTTP",
            action=RuleAction.PASS,
            interface=interface,
            protocol=Protocol.TCP,
            destination_port="80",
        ),
        FirewallRule(
            description="Allow HTTPS",
            action=RuleAction.PASS,
            interface=interface,
            protocol=Protocol.TCP,
            destination_port="443",
        ),
        FirewallRule(
            description="Block all other outbound",
            action=RuleAction.BLOCK,
            interface=interface,
            sequence=65000,  # Low priority
        ),
    ]

    if check_mode:
        for rule in rules:
            print(f"  Would create: {rule.description} ({rule.action.value})")
    else:
        results = manager.create_multiple_rules(rules)
        for rule, result in zip(rules, results):
            print(f"  {rule.description}: {result}")


def example_firewall_delete_rule(
    manager: FirewallManager,
    check_mode: bool = True,
) -> None:
    """Delete a firewall rule."""
    print(f"\nDeleting firewall rule (check_mode={check_mode})...")

    if check_mode:
        print("  Would delete rule: 'Block all other outbound'")
    else:
        result = manager.delete_rule("Block all other outbound")
        print(f"  Result: {result}")


def example_firewall_allow_rule(
    manager: FirewallManager,
    check_mode: bool = True,
    interface: str = "lan",
) -> None:
    """Create a simple allow rule using convenience method."""
    print(f"\nCreating allow rule (check_mode={check_mode})...")

    if check_mode:
        print(f"  Would create allow rule for ICMP on {interface}")
    else:
        result = manager.create_allow_rule(
            description="Allow ICMP ping",
            interface=interface,
            protocol=Protocol.ICMP,
        )
        print(f"  Result: {result}")


def example_firewall_block_rule(
    manager: FirewallManager,
    check_mode: bool = True,
    interface: str = "lan",
) -> None:
    """Create a simple block rule using convenience method."""
    print(f"\nCreating block rule (check_mode={check_mode})...")

    if check_mode:
        print(f"  Would create block rule for Telnet on {interface}")
    else:
        result = manager.create_block_rule(
            description="Block Telnet",
            interface=interface,
            protocol=Protocol.TCP,
            destination_port="23",
        )
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
        "--mode",
        choices=["vlan", "dhcp", "firewall"],
        default="vlan",
        help="Which manager to use: vlan, dhcp, or firewall (default: vlan)",
    )
    parser.add_argument(
        "--example",
        default="all",
        help="Which example to run (default: all). "
        "For vlan: all, test, list, spec, assigned, create, create-multi, update, delete. "
        "For dhcp: all, test, spec, range, range-multi, host, host-multi, delete-host, enable, config. "
        "For firewall: all, test, spec, list, create, create-multi, delete, allow, block",
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

    # Run examples based on mode
    if args.mode == "vlan":
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
            elif args.example in examples:
                examples[args.example]()
            else:
                print(f"Unknown VLAN example: {args.example}")
                print(f"Available: {', '.join(examples.keys())}")
                sys.exit(1)

    elif args.mode == "dhcp":
        with DhcpManager(config) as manager:
            examples = {
                "test": lambda: example_dhcp_test_connection(manager),
                "spec": lambda: example_dhcp_show_specs(manager),
                "range": lambda: example_dhcp_create_range(manager, check_mode),
                "range-multi": lambda: example_dhcp_create_multiple_ranges(manager, check_mode),
                "host": lambda: example_dhcp_create_host(manager, check_mode),
                "host-multi": lambda: example_dhcp_create_multiple_hosts(manager, check_mode),
                "delete-host": lambda: example_dhcp_delete_host(manager, check_mode),
                "enable": lambda: example_dhcp_enable_service(manager, check_mode),
                "config": lambda: example_dhcp_configure_general(manager, check_mode),
            }

            if args.example == "all":
                for name, func in examples.items():
                    try:
                        func()
                    except Exception as e:
                        print(f"  Error in {name}: {e}")
            elif args.example in examples:
                examples[args.example]()
            else:
                print(f"Unknown DHCP example: {args.example}")
                print(f"Available: {', '.join(examples.keys())}")
                sys.exit(1)

    elif args.mode == "firewall":
        with FirewallManager(config) as manager:
            interface = args.interface
            examples = {
                "test": lambda: example_firewall_test_connection(manager),
                "spec": lambda: example_firewall_show_spec(manager),
                "list": lambda: example_firewall_list_rules(manager),
                "create": lambda: example_firewall_create_rule(manager, check_mode, interface),
                "create-multi": lambda: example_firewall_create_multiple_rules(manager, check_mode, interface),
                "delete": lambda: example_firewall_delete_rule(manager, check_mode),
                "allow": lambda: example_firewall_allow_rule(manager, check_mode, interface),
                "block": lambda: example_firewall_block_rule(manager, check_mode, interface),
            }

            if args.example == "all":
                for name, func in examples.items():
                    try:
                        func()
                    except Exception as e:
                        print(f"  Error in {name}: {e}")
            elif args.example in examples:
                examples[args.example]()
            else:
                print(f"Unknown firewall example: {args.example}")
                print(f"Available: {', '.join(examples.keys())}")
                sys.exit(1)


if __name__ == "__main__":
    main()
