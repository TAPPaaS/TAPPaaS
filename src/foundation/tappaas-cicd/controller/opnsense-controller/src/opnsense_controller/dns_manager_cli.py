#!/usr/bin/env python3
"""DNS Host Management CLI for OPNsense.

This module provides a dedicated CLI for managing DNS host entries
in OPNsense's Dnsmasq service.
"""

import argparse
import json
import sys

from .cli_globals import make_global_parent, parse_with_globals
from .config import Config
from .dhcp_manager import DhcpHost, DhcpManager


def format_ip(ip_raw) -> str:
    """Format IP address field which may be a list or string.

    Args:
        ip_raw: IP address(es) as returned from API (list, string, or None)

    Returns:
        Formatted IP string
    """
    if not ip_raw:
        return 'N/A'
    if isinstance(ip_raw, list):
        return ', '.join(str(ip) for ip in ip_raw) if ip_raw else 'N/A'
    return str(ip_raw)


def add_dns_host(
    manager: DhcpManager,
    hostname: str,
    domain: str,
    ip_address: str,
    description: str | None = None,
    check_mode: bool = False,
    mac: str | None = None,
) -> bool:
    """Add or update a DNS host entry.

    Args:
        manager: DhcpManager instance
        hostname: Hostname without domain (e.g., "backup")
        domain: Domain name (e.g., "mgmt.internal")
        ip_address: IP address for the host
        description: Description for the entry (defaults to hostname)
        check_mode: If True, perform dry-run without making changes
        mac: Optional MAC address. When given, the entry becomes a full DHCP
            static reservation (MAC -> IP) AND the hostname->IP DNS record in a
            single dnsmasq host. This LOCKS the guest's IP, so the DNS record can
            never drift if DHCP would otherwise hand out a different address on a
            later lease/reboot. Used for guests that cannot self-register via the
            DHCP lease under <vmname> (appliances like HAOS, Windows clones).

    Returns:
        True if successful, False otherwise
    """
    if description is None:
        description = f"{hostname}.{domain}"

    # Check if entry already exists
    existing = manager.get_host_by_description(description)
    if existing:
        print(f"DNS entry '{description}' already exists:")
        print(f"  Host: {existing['host']}.{existing.get('domain', '')}")
        print(f"  IP: {existing.get('ip', 'N/A')}")
        if check_mode:
            print("Would update entry (dry-run mode)")
            return True
        else:
            print("Updating entry...")
    else:
        if check_mode:
            print(f"Would create DNS entry: {hostname}.{domain} -> {ip_address} (dry-run mode)")
            return True
        else:
            print(f"Creating DNS entry: {hostname}.{domain} -> {ip_address}")

    # Create/update the DNS host entry. With a MAC it is a full static
    # reservation (MAC -> IP) that also serves the hostname -> IP record, so the
    # IP is locked and the DNS record cannot drift.
    host = DhcpHost(
        description=description,
        host=hostname,
        ip=[ip_address],
        domain=domain,
        hardware_addr=[mac] if mac else [],
    )
    if mac:
        print(f"  (static DHCP reservation: {mac} -> {ip_address})")

    try:
        result = manager.create_host(host, check_mode=check_mode)

        if check_mode:
            print("Dry-run completed successfully")
            return True

        if result.get("changed"):
            print(f"✓ DNS entry created/updated successfully")
            print(f"  {hostname}.{domain} -> {ip_address}")
            return True
        else:
            print("No changes made (entry already up to date)")
            return True
    except Exception as e:
        print(f"ERROR: Failed to create/update DNS entry: {e}", file=sys.stderr)
        return False


def delete_dns_host(
    manager: DhcpManager,
    hostname: str,
    domain: str,
    check_mode: bool = False,
    debug: bool = False,
) -> bool:
    """Delete a DNS host entry by hostname and domain.

    Args:
        manager: DhcpManager instance
        hostname: Hostname without domain (e.g., "backup")
        domain: Domain name (e.g., "mgmt.internal")
        check_mode: If True, perform dry-run without making changes
        debug: Enable debug output

    Returns:
        True if successful, False otherwise
    """
    try:
        # List all hosts to find the matching entry
        hosts = manager.list_hosts()

        # Find the host matching hostname and domain
        matching_host = None
        for host in hosts:
            if host.get('host') == hostname and host.get('domain') == domain:
                matching_host = host
                break

        if not matching_host:
            print(f"ERROR: No DNS entry found for {hostname}.{domain}", file=sys.stderr)
            return False

        uuid = matching_host.get('uuid')
        if not uuid:
            print(f"ERROR: Entry found but has no UUID", file=sys.stderr)
            return False

        ip = format_ip(matching_host.get('ip'))
        desc = matching_host.get('description', 'N/A')

        print(f"Found DNS entry:")
        print(f"  Host: {hostname}.{domain}")
        print(f"  IP: {ip}")
        print(f"  Description: {desc}")
        print(f"  UUID: {uuid}")

        if check_mode:
            print(f"Would delete DNS entry (dry-run mode)")
            return True

        if debug:
            print(f"DEBUG: Deleting entry with UUID: {uuid}")

        # Delete by UUID
        result = manager.delete_host_by_uuid(uuid, check_mode=check_mode)

        if result.get("changed"):
            print(f"✓ DNS entry deleted successfully")
            return True
        else:
            print(f"ERROR: Failed to delete DNS entry", file=sys.stderr)
            if debug:
                print(f"DEBUG: Result: {result}")
            return False

    except Exception as e:
        print(f"ERROR: Failed to delete DNS entry: {e}", file=sys.stderr)
        if debug:
            import traceback
            traceback.print_exc()
        return False


def list_dns_hosts(manager: DhcpManager) -> bool:
    """List all DNS host entries.

    Args:
        manager: DhcpManager instance

    Returns:
        True if successful, False otherwise
    """
    try:
        hosts = manager.list_hosts()
        if not hosts:
            print("No DNS host entries found")
            return True

        print(f"Found {len(hosts)} DNS host entries:")
        print()
        for host in hosts:
            fqdn = f"{host['host']}.{host.get('domain', '')}" if host.get('domain') else host['host']
            ip = format_ip(host.get('ip'))
            desc = host.get('description', 'N/A')
            print(f"  {fqdn:40} -> {ip:15}  ({desc})")

        return True
    except Exception as e:
        print(f"ERROR: Failed to list DNS entries: {e}", file=sys.stderr)
        return False


def check_dns_range(manager: DhcpManager, ip_address: str) -> bool:
    """Check whether an IP falls inside a configured DHCP pool (issue #251).

    Prints the matching range if the IP is inside a DHCP pool and returns
    False (so the shell sees a non-zero exit); returns True when the IP is
    clear of every pool. Callers (e.g. network:dns install-service) treat a
    non-zero exit as a warning, not a hard failure — a static reservation
    inside the pool still works, it is just risky.

    Args:
        manager: DhcpManager instance
        ip_address: IPv4 address to test

    Returns:
        True if the IP is NOT inside any DHCP pool, False if it is inside one.
    """
    try:
        match = manager.ip_in_any_range(ip_address)
    except Exception as e:
        print(f"ERROR: Failed to query DHCP ranges: {e}", file=sys.stderr)
        # Unknown — do not block the caller; report "clear".
        return True

    if match:
        desc = match.get("description") or match.get("interface") or "?"
        print(
            f"IP {ip_address} is INSIDE DHCP pool "
            f"'{desc}' ({match.get('start_addr')}-{match.get('end_addr')})"
        )
        return False

    print(f"IP {ip_address} is not inside any DHCP pool")
    return True


def list_dhcp_leases(
    manager: DhcpManager,
    mac: str | None = None,
    ip: str | None = None,
    as_json: bool = False,
) -> bool:
    """List active dnsmasq DHCP leases, optionally filtered by MAC or IP.

    Primary consumer is the cluster:vm reconciler: after moving a VM to a new
    zone it reboots and needs the guest's new IPv4. The qemu-guest-agent is the
    first source, but it may be absent/slow; ``dns-manager leases --mac <MAC>``
    is the guest-agent-independent fallback — it reads the IP straight from the
    DHCP server's lease table.

    Output:
      * ``--mac``/``--ip`` filter: prints ONLY the matching lease IP(s), one per
        line (so a shell can capture ``ip=$(dns-manager leases --mac X)``).
        Exit non-zero (returns False) when nothing matches.
      * no filter: prints a human table (or JSON with ``--json``).

    Returns True on success (≥1 lease when filtered), False otherwise.
    """
    try:
        leases = manager.list_leases()
    except Exception as e:
        print(f"ERROR: Failed to list DHCP leases: {e}", file=sys.stderr)
        return False

    if mac:
        mac_l = mac.strip().lower()
        leases = [le for le in leases if (le.get("mac") or "").lower() == mac_l]
    if ip:
        leases = [le for le in leases if le.get("ip") == ip]

    if as_json:
        print(json.dumps(leases, indent=2))
        return bool(leases) if (mac or ip) else True

    if mac or ip:
        # Machine-friendly: just the IP(s) for the filtered lease(s).
        for le in leases:
            if le.get("ip"):
                print(le["ip"])
        return bool(leases)

    if not leases:
        print("No active DHCP leases")
        return True
    print(f"{'IP':<16} {'MAC':<18} {'ZONE':<14} HOSTNAME")
    for le in leases:
        print(
            f"{(le.get('ip') or ''):<16} {(le.get('mac') or ''):<18} "
            f"{(le.get('zone') or ''):<14} {le.get('hostname') or ''}"
        )
    return True


def main():
    """Main entry point for DNS manager CLI."""
    # Global options work on either side of the subcommand (#379); see cli_globals.py.
    gp = make_global_parent()
    gp.add_argument(
        "--firewall",
        help="Firewall IP/hostname (default: firewall.mgmt.internal)",
    )
    gp.add_argument(
        "--port",
        type=int,
        help="API port (default: auto-detect by probing 443, then 8443)",
    )
    gp.add_argument(
        "--credential-file",
        help="Path to credential file (default: $HOME/.opnsense-credentials.txt)",
    )
    gp.add_argument(
        "--no-ssl-verify",
        action="store_true",
        help="Disable SSL certificate verification",
    )
    gp.add_argument(
        "--debug",
        action="store_true",
        help="Enable debug logging",
    )
    gp.add_argument(
        "--check-mode",
        action="store_true",
        help="Dry-run mode (don't make actual changes)",
    )

    parser = argparse.ArgumentParser(
        description="DNS Host Management for OPNsense Dnsmasq",
        parents=[gp],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Add a DNS entry
  dns-manager add backup mgmt.internal 10.0.0.12

  # Add with custom description
  dns-manager add backup mgmt.internal 10.0.0.12 --description "PBS Backup Server"

  # Delete a DNS entry (by hostname and domain)
  dns-manager delete backup mgmt.internal

  # List all DNS entries
  dns-manager list

  # Check whether an IP is inside a DHCP pool (non-zero exit if it is)
  dns-manager check-range 10.2.20.25

  # Dry-run mode (don't make changes)
  dns-manager add backup mgmt.internal 10.0.0.12 --check-mode
  dns-manager delete backup mgmt.internal --check-mode
        """,
    )

    # Subcommands
    subparsers = parser.add_subparsers(dest="command", help="Command to execute")

    # Add command
    add_parser = subparsers.add_parser("add", parents=[gp], help="Add or update a DNS host entry")
    add_parser.add_argument("hostname", help="Hostname without domain (e.g., backup)")
    add_parser.add_argument("domain", help="Domain name (e.g., mgmt.internal)")
    add_parser.add_argument("ip", help="IP address")
    add_parser.add_argument(
        "--description",
        help="Description for the entry (default: hostname.domain)",
    )
    add_parser.add_argument(
        "--mac",
        help="MAC address — make this a static DHCP reservation (MAC -> IP) so "
             "the IP is locked and the DNS record cannot drift. Use for guests "
             "that do not self-register via the lease (HAOS, Windows clones).",
    )

    # Delete command
    delete_parser = subparsers.add_parser("delete", parents=[gp], help="Delete a DNS host entry by hostname and domain")
    delete_parser.add_argument("hostname", help="Hostname without domain (e.g., backup)")
    delete_parser.add_argument("domain", help="Domain name (e.g., mgmt.internal)")

    # List command
    subparsers.add_parser("list", parents=[gp], help="List all DNS host entries")

    # Check-range command (issue #251)
    check_range_parser = subparsers.add_parser(
        "check-range",
        parents=[gp],
        help="Check whether an IP is inside a DHCP pool (exit 1 if it is)",
    )
    check_range_parser.add_argument("ip", help="IP address to check")

    # Leases command (issue #235) — list dnsmasq DHCP leases; the cluster:vm
    # reconciler uses `leases --mac <MAC>` as a guest-agent-independent way to
    # find a VM's IP after a zone/subnet change.
    leases_parser = subparsers.add_parser(
        "leases", parents=[gp], help="List active DHCP leases (optionally filter by --mac/--ip)"
    )
    leases_parser.add_argument("--mac", help="Only the lease for this MAC (prints its IP)")
    leases_parser.add_argument("--ip", help="Only the lease for this IP")
    leases_parser.add_argument("--json", action="store_true", help="Emit JSON")

    args = parse_with_globals(parser, {
        "firewall": "firewall.mgmt.internal",
        "port": None,
        "credential_file": None,
        "no_ssl_verify": False,
        "debug": False,
        "check_mode": False,
    })

    if not args.command:
        parser.print_help()
        sys.exit(1)

    # Build configuration
    config_kwargs = {
        "firewall": args.firewall,
        "ssl_verify": not args.no_ssl_verify,
        "debug": args.debug,
    }
    if args.port is not None:
        config_kwargs["port"] = args.port
    if args.credential_file:
        config_kwargs["credential_file"] = args.credential_file

    try:
        config = Config(**config_kwargs)
    except ValueError as e:
        print(f"Configuration error: {e}", file=sys.stderr)
        sys.exit(1)

    # Execute command
    try:
        with DhcpManager(config) as manager:
            # Test connection
            if not manager.test_connection():
                print("ERROR: Cannot connect to OPNsense firewall", file=sys.stderr)
                sys.exit(1)

            if args.debug:
                print(f"Connected to OPNsense at {config.firewall}")

            success = False
            if args.command == "add":
                success = add_dns_host(
                    manager,
                    args.hostname,
                    args.domain,
                    args.ip,
                    args.description,
                    args.check_mode,
                    mac=args.mac,
                )
            elif args.command == "delete":
                success = delete_dns_host(
                    manager,
                    args.hostname,
                    args.domain,
                    args.check_mode,
                    args.debug,
                )
            elif args.command == "list":
                success = list_dns_hosts(manager)
            elif args.command == "check-range":
                success = check_dns_range(manager, args.ip)
            elif args.command == "leases":
                success = list_dhcp_leases(
                    manager, mac=args.mac, ip=args.ip, as_json=args.json
                )

            sys.exit(0 if success else 1)

    except KeyboardInterrupt:
        print("\nInterrupted by user", file=sys.stderr)
        sys.exit(130)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        if args.debug:
            import traceback
            traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
