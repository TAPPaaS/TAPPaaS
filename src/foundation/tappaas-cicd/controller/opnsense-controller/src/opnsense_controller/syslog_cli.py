#!/usr/bin/env python3
"""Syslog destination management CLI for OPNsense.

Use this to point OPNsense's syslog at a remote sink (e.g. the TAPPaaS
`logging` module's Promtail receiver on tcp/1514).

Usage:
    syslog-manager list
    syslog-manager add-destination --hostname logging.mgmt.internal --port 1514 \\
        --transport tcp4 --rfc5424 --description "tappaas-logging"
    syslog-manager delete-destination --description "tappaas-logging"
    syslog-manager reconfigure
"""

import argparse
import sys

from .config import Config
from .syslog_manager import (
    LEVELS,
    TRANSPORTS,
    SyslogDestination,
    SyslogManager,
)


def add_destination(
    manager: SyslogManager,
    *,
    hostname: str,
    port: int,
    transport: str,
    rfc5424: bool,
    description: str,
    level: str = "",
    facility: str = "",
    program: str = "",
    certificate: str = "",
    check_mode: bool = False,
) -> bool:
    """Idempotently add a destination, matched by description.

    If a destination with the same description already exists, update it in
    place rather than creating a duplicate. The OPNsense web UI matches by
    description as well, so this aligns with operator expectations.
    """
    if transport not in TRANSPORTS:
        print(
            f"ERROR: --transport {transport!r} is not one of {sorted(TRANSPORTS)}",
            file=sys.stderr,
        )
        return False
    if level and any(lv not in LEVELS for lv in level.split(",")):
        print(
            f"ERROR: --level entries must each be one of {sorted(LEVELS)}",
            file=sys.stderr,
        )
        return False
    if transport.startswith("tls") and not certificate:
        print(
            "ERROR: --certificate (cert UUID) is required when --transport is tls*",
            file=sys.stderr,
        )
        return False
    if not description:
        print(
            "ERROR: --description is required (used as idempotency key)",
            file=sys.stderr,
        )
        return False

    dest = SyslogDestination(
        hostname=hostname,
        port=port,
        transport=transport,
        rfc5424=rfc5424,
        description=description,
        level=level,
        facility=facility,
        program=program,
        certificate=certificate,
    )

    existing = manager.get_destination_by_description(description)
    if existing:
        same = (
            existing.hostname == hostname
            and str(existing.port) == str(port)
            and existing.transport == transport
            and existing.rfc5424 == rfc5424
            and existing.enabled is True
        )
        if same:
            print(
                f"Destination '{description}' already correct "
                f"(uuid={existing.uuid}, {transport}://{hostname}:{port}, rfc5424={rfc5424})"
            )
            return True

        if check_mode:
            print(
                f"Would update destination '{description}' "
                f"(uuid={existing.uuid}) → {transport}://{hostname}:{port} (dry-run)"
            )
            return True

        print(
            f"Updating destination '{description}' "
            f"(uuid={existing.uuid}) → {transport}://{hostname}:{port}"
        )
        result = manager.update_destination(existing.uuid, dest)
    else:
        if check_mode:
            print(
                f"Would create destination '{description}' "
                f"→ {transport}://{hostname}:{port} (dry-run)"
            )
            return True

        print(
            f"Creating destination '{description}' → {transport}://{hostname}:{port}"
        )
        result = manager.add_destination(dest)

    if result.get("result") == "saved" or result.get("uuid"):
        print(f"  OK")
        return True
    print(f"ERROR: API call failed: {result}", file=sys.stderr)
    return False


def delete_destination(
    manager: SyslogManager,
    *,
    description: str | None,
    uuid: str | None,
    check_mode: bool = False,
) -> bool:
    """Delete by description (preferred) or uuid."""
    if uuid:
        target_uuid = uuid
        label = f"uuid={uuid}"
    elif description:
        existing = manager.get_destination_by_description(description)
        if not existing:
            print(f"Destination '{description}' not found — nothing to delete")
            return True
        target_uuid = existing.uuid
        label = f"'{description}' (uuid={target_uuid})"
    else:
        print("ERROR: provide either --description or --uuid", file=sys.stderr)
        return False

    if check_mode:
        print(f"Would delete destination {label} (dry-run)")
        return True

    print(f"Deleting destination {label}")
    result = manager.delete_destination(target_uuid)
    if result.get("result") == "deleted" or "error" not in str(result).lower():
        print("  OK")
        return True
    print(f"ERROR: delete failed: {result}", file=sys.stderr)
    return False


def list_destinations(manager: SyslogManager) -> bool:
    dests = manager.list_destinations()
    if not dests:
        print("No syslog destinations configured")
        return True
    print(f"Destinations ({len(dests)}):")
    for d in dests:
        status = "enabled" if d.enabled else "disabled"
        rfc = "rfc5424" if d.rfc5424 else "rfc3164"
        print(
            f"  {d.description!r:35} "
            f"{d.transport:5} {d.hostname}:{d.port:5} [{status}, {rfc}]  uuid={d.uuid}"
        )
    return True


def reconfigure(manager: SyslogManager, check_mode: bool = False) -> bool:
    """Apply pending syslog changes — re-render config and reload syslogd."""
    if check_mode:
        print("Would reconfigure syslog (dry-run)")
        return True
    print("Reconfiguring syslog...")
    result = manager.reconfigure()
    if result.get("status") == "ok":
        print("  syslog reconfigured")
        return True
    if "error" not in str(result).lower():
        print(f"  syslog reconfigure returned: {result}")
        return True
    print(f"ERROR: reconfigure failed: {result}", file=sys.stderr)
    return False


def main():
    global_parser = argparse.ArgumentParser(add_help=False)
    global_parser.add_argument(
        "--firewall",
        default="firewall.mgmt.internal",
        help="Firewall IP/hostname (default: firewall.mgmt.internal)",
    )
    global_parser.add_argument(
        "--api-port", type=int, default=None, dest="api_port",
        help="OPNsense API port (default: auto-detect 443 then 8443)",
    )
    global_parser.add_argument(
        "--credential-file",
        help="Path to credential file (default: $HOME/.opnsense-credentials.txt)",
    )
    global_parser.add_argument("--no-ssl-verify", action="store_true",
                               help="Disable SSL certificate verification")
    global_parser.add_argument("--debug", action="store_true", help="Enable debug logging")
    global_parser.add_argument("--check-mode", action="store_true", help="Dry-run mode")

    parser = argparse.ArgumentParser(
        description="Manage OPNsense built-in syslog destinations",
        parents=[global_parser],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # List all destinations
  syslog-manager list

  # Add (or update) the tappaas-logging destination — RFC 5424 over TCP
  syslog-manager add-destination \\
    --hostname logging.mgmt.internal --port 1514 \\
    --transport tcp4 --rfc5424 \\
    --description tappaas-logging

  # Apply pending changes (reload syslogd)
  syslog-manager reconfigure

  # Remove the destination
  syslog-manager delete-destination --description tappaas-logging
""",
    )
    subparsers = parser.add_subparsers(dest="command", help="Command to execute")

    add_p = subparsers.add_parser("add-destination", parents=[global_parser],
                                   help="Create or update a syslog destination (idempotent)")
    add_p.add_argument("--hostname", required=True, help="Target hostname/IP")
    add_p.add_argument("--port", type=int, default=514, help="Target port (default 514)")
    add_p.add_argument("--transport", default="tcp4",
                       choices=sorted(TRANSPORTS),
                       help="Transport (default tcp4)")
    add_p.add_argument("--rfc5424", action="store_true",
                       help="Emit RFC 5424 format (Promtail expects this)")
    add_p.add_argument("--description", required=True,
                       help="Description — also the idempotency key")
    add_p.add_argument("--level", default="",
                       help="Comma-sep severities (any of: " + ",".join(sorted(LEVELS)) + ")")
    add_p.add_argument("--facility", default="", help="Comma-sep facilities (default: all)")
    add_p.add_argument("--program", default="", help="Comma-sep program filter (default: all)")
    add_p.add_argument("--certificate", default="", help="TLS cert UUID (only for tls*)")

    del_p = subparsers.add_parser("delete-destination", parents=[global_parser],
                                   help="Delete a syslog destination")
    del_group = del_p.add_mutually_exclusive_group(required=True)
    del_group.add_argument("--description", help="Destination description to match")
    del_group.add_argument("--uuid", help="Destination UUID to delete directly")

    subparsers.add_parser("list", parents=[global_parser], help="List all destinations")
    subparsers.add_parser("reconfigure", parents=[global_parser], help="Apply pending changes")

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        sys.exit(1)

    config_kwargs = {
        "firewall": args.firewall,
        "ssl_verify": not args.no_ssl_verify,
        "debug": args.debug,
    }
    if args.api_port is not None:
        config_kwargs["port"] = args.api_port
    if args.credential_file:
        config_kwargs["credential_file"] = args.credential_file

    try:
        config = Config(**config_kwargs)
    except ValueError as e:
        print(f"Configuration error: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        with SyslogManager(config) as manager:
            if not manager.test_connection():
                print("ERROR: Cannot connect to OPNsense firewall", file=sys.stderr)
                sys.exit(1)
            if args.debug:
                print(f"Connected to OPNsense at {config.firewall}")

            success = False
            if args.command == "add-destination":
                success = add_destination(
                    manager,
                    hostname=args.hostname,
                    port=args.port,
                    transport=args.transport,
                    rfc5424=args.rfc5424,
                    description=args.description,
                    level=args.level,
                    facility=args.facility,
                    program=args.program,
                    certificate=args.certificate,
                    check_mode=args.check_mode,
                )
            elif args.command == "delete-destination":
                success = delete_destination(
                    manager,
                    description=getattr(args, "description", None),
                    uuid=getattr(args, "uuid", None),
                    check_mode=args.check_mode,
                )
            elif args.command == "list":
                success = list_destinations(manager)
            elif args.command == "reconfigure":
                success = reconfigure(manager, check_mode=args.check_mode)

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
