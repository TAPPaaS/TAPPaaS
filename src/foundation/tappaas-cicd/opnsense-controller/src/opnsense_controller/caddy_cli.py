#!/usr/bin/env python3
"""Caddy Reverse Proxy Management CLI for OPNsense.

This module provides a dedicated CLI for managing Caddy reverse proxy
domains and handlers on OPNsense.
"""

import argparse
import sys

from .caddy_manager import CaddyDomain, CaddyHandler, CaddyManager
from .config import Config


def add_domain(
    manager: CaddyManager,
    domain_name: str,
    description: str = "",
    check_mode: bool = False,
) -> bool:
    """Add a reverse proxy domain.

    Args:
        manager: CaddyManager instance.
        domain_name: Domain FQDN (e.g., "app.test.tapaas.org").
        description: Description for the entry.
        check_mode: If True, perform dry-run.

    Returns:
        True if successful.
    """
    existing = manager.get_domain_by_name(domain_name)
    if existing:
        print(f"Domain '{domain_name}' already exists (uuid={existing.uuid})")
        return True

    if check_mode:
        print(f"Would create domain: {domain_name} (dry-run)")
        return True

    print(f"Creating domain: {domain_name}")
    domain = CaddyDomain(domain=domain_name, description=description)
    result = manager.add_domain(domain)

    uuid = result.get("uuid")
    if uuid:
        print(f"  Domain created successfully (uuid={uuid})")
        return True

    # Some API versions return result differently
    if result.get("result") == "saved":
        print(f"  Domain created successfully")
        return True

    print(f"ERROR: Failed to create domain: {result}", file=sys.stderr)
    return False


def add_handler(
    manager: CaddyManager,
    domain_name: str,
    upstream: str,
    port: str = "80",
    description: str = "",
    check_mode: bool = False,
) -> bool:
    """Add a reverse proxy handler for a domain.

    Args:
        manager: CaddyManager instance.
        domain_name: Domain FQDN to attach the handler to.
        upstream: Upstream server hostname (e.g., "app.srv.internal").
        port: Upstream port.
        description: Description for the handler.
        check_mode: If True, perform dry-run.

    Returns:
        True if successful.
    """
    # Find the domain UUID
    domain_info = manager.get_domain_by_name(domain_name)
    if not domain_info:
        print(f"ERROR: Domain '{domain_name}' not found. Add it first.", file=sys.stderr)
        return False

    # Check if handler already exists
    if description:
        existing = manager.get_handler_by_description(description)
        if existing:
            print(f"Handler '{description}' already exists (uuid={existing.uuid})")
            print(f"  Upstream: {existing.upstream_domain}:{existing.upstream_port}")
            return True

    if check_mode:
        print(f"Would create handler: {domain_name} -> {upstream}:{port} (dry-run)")
        return True

    print(f"Creating handler: {domain_name} -> {upstream}:{port}")
    handler = CaddyHandler(
        domain_uuid=domain_info.uuid,
        upstream_domain=upstream,
        upstream_port=str(port),
        description=description,
    )
    result = manager.add_handler(handler)

    uuid = result.get("uuid")
    if uuid:
        print(f"  Handler created successfully (uuid={uuid})")
        return True

    if result.get("result") == "saved":
        print(f"  Handler created successfully")
        return True

    print(f"ERROR: Failed to create handler: {result}", file=sys.stderr)
    return False


def delete_domain_cmd(
    manager: CaddyManager,
    domain_name: str,
    check_mode: bool = False,
) -> bool:
    """Delete a reverse proxy domain.

    Args:
        manager: CaddyManager instance.
        domain_name: Domain FQDN to delete.
        check_mode: If True, perform dry-run.

    Returns:
        True if successful.
    """
    domain_info = manager.get_domain_by_name(domain_name)
    if not domain_info:
        print(f"Domain '{domain_name}' not found — nothing to delete")
        return True

    if check_mode:
        print(f"Would delete domain: {domain_name} (uuid={domain_info.uuid}) (dry-run)")
        return True

    print(f"Deleting domain: {domain_name} (uuid={domain_info.uuid})")
    result = manager.delete_domain(domain_info.uuid)

    if result.get("result") == "deleted":
        print(f"  Domain deleted successfully")
        return True

    # Treat any non-error response as success
    if "error" not in str(result).lower():
        print(f"  Domain deleted")
        return True

    print(f"ERROR: Failed to delete domain: {result}", file=sys.stderr)
    return False


def delete_handler_cmd(
    manager: CaddyManager,
    description: str | None = None,
    uuid: str | None = None,
    check_mode: bool = False,
) -> bool:
    """Delete a reverse proxy handler.

    Args:
        manager: CaddyManager instance.
        description: Handler description to find and delete.
        uuid: Handler UUID to delete directly.
        check_mode: If True, perform dry-run.

    Returns:
        True if successful.
    """
    if uuid:
        handler_uuid = uuid
    elif description:
        handler_info = manager.get_handler_by_description(description)
        if not handler_info:
            print(f"Handler '{description}' not found — nothing to delete")
            return True
        handler_uuid = handler_info.uuid
        print(f"Found handler: {description} (uuid={handler_uuid})")
    else:
        print("ERROR: Provide either --description or --uuid", file=sys.stderr)
        return False

    if check_mode:
        print(f"Would delete handler (uuid={handler_uuid}) (dry-run)")
        return True

    print(f"Deleting handler (uuid={handler_uuid})")
    result = manager.delete_handler(handler_uuid)

    if result.get("result") == "deleted":
        print(f"  Handler deleted successfully")
        return True

    if "error" not in str(result).lower():
        print(f"  Handler deleted")
        return True

    print(f"ERROR: Failed to delete handler: {result}", file=sys.stderr)
    return False


def list_all(manager: CaddyManager) -> bool:
    """List all domains and handlers.

    Args:
        manager: CaddyManager instance.

    Returns:
        True if successful.
    """
    domains = manager.list_domains()
    handlers = manager.list_handlers()

    if not domains and not handlers:
        print("No Caddy reverse proxy entries configured")
        return True

    print(f"Domains ({len(domains)}):")
    for d in domains:
        status = "enabled" if d.enabled else "disabled"
        print(f"  {d.domain:40} [{status}]  ({d.description})  uuid={d.uuid}")

    print(f"\nHandlers ({len(handlers)}):")
    for h in handlers:
        status = "enabled" if h.enabled else "disabled"
        print(f"  -> {h.upstream_domain}:{h.upstream_port:5}  [{status}]  ({h.description})  uuid={h.uuid}")

    return True


def reconfigure_cmd(manager: CaddyManager, check_mode: bool = False) -> bool:
    """Reconfigure Caddy (regenerate Caddyfile and reload).

    Args:
        manager: CaddyManager instance.
        check_mode: If True, perform dry-run.

    Returns:
        True if successful.
    """
    if check_mode:
        print("Would reconfigure Caddy (dry-run)")
        return True

    print("Reconfiguring Caddy...")
    result = manager.reconfigure()

    if result.get("status") == "ok":
        print("  Caddy reconfigured successfully")
        return True

    # Treat non-error as success
    if "error" not in str(result).lower():
        print("  Caddy reconfigured")
        return True

    print(f"ERROR: Reconfigure failed: {result}", file=sys.stderr)
    return False


def main():
    """Main entry point for caddy-manager CLI."""
    # Shared global options available in both positions (before or after subcommand)
    global_parser = argparse.ArgumentParser(add_help=False)
    global_parser.add_argument(
        "--firewall",
        default="firewall.mgmt.internal",
        help="Firewall IP/hostname (default: firewall.mgmt.internal)",
    )
    global_parser.add_argument(
        "--api-port",
        type=int,
        default=None,
        dest="api_port",
        help="OPNsense API port (default: auto-detect by probing 443, then 8443)",
    )
    global_parser.add_argument(
        "--credential-file",
        help="Path to credential file (default: $HOME/.opnsense-credentials.txt)",
    )
    global_parser.add_argument(
        "--no-ssl-verify",
        action="store_true",
        help="Disable SSL certificate verification",
    )
    global_parser.add_argument(
        "--debug",
        action="store_true",
        help="Enable debug logging",
    )
    global_parser.add_argument(
        "--check-mode",
        action="store_true",
        help="Dry-run mode (don't make actual changes)",
    )

    parser = argparse.ArgumentParser(
        description="Caddy Reverse Proxy Management for OPNsense",
        parents=[global_parser],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # List all domains and handlers
  caddy-manager list

  # Add a domain (global options can go before or after the subcommand)
  caddy-manager add-domain app.test.tapaas.org --description "TAPPaaS: myapp" --no-ssl-verify
  caddy-manager --no-ssl-verify add-domain app.test.tapaas.org --description "TAPPaaS: myapp"

  # Add a handler for a domain
  caddy-manager add-handler app.test.tapaas.org --upstream myapp.srv.internal --port 8080 --description "TAPPaaS: myapp"

  # Delete a handler by description
  caddy-manager delete-handler --description "TAPPaaS: myapp"

  # Delete a domain
  caddy-manager delete-domain app.test.tapaas.org

  # Reconfigure Caddy (apply pending changes)
  caddy-manager reconfigure

  # Dry-run mode
  caddy-manager add-domain app.test.tapaas.org --check-mode
        """,
    )

    # Subcommands (each inherits global options so they work after the subcommand too)
    subparsers = parser.add_subparsers(dest="command", help="Command to execute")

    # add-domain
    add_domain_parser = subparsers.add_parser("add-domain", parents=[global_parser], help="Add a reverse proxy domain")
    add_domain_parser.add_argument("domain", help="Domain FQDN (e.g., app.test.tapaas.org)")
    add_domain_parser.add_argument("--description", default="", help="Description for the domain")

    # add-handler
    add_handler_parser = subparsers.add_parser("add-handler", parents=[global_parser], help="Add a reverse proxy handler")
    add_handler_parser.add_argument("domain", help="Domain FQDN to attach the handler to")
    add_handler_parser.add_argument("--upstream", required=True, help="Upstream server (e.g., app.srv.internal)")
    add_handler_parser.add_argument("--port", default="80", help="Upstream port (default: 80)")
    add_handler_parser.add_argument("--description", default="", help="Description for the handler")

    # delete-domain
    delete_domain_parser = subparsers.add_parser("delete-domain", parents=[global_parser], help="Delete a reverse proxy domain")
    delete_domain_parser.add_argument("domain", help="Domain FQDN to delete")

    # delete-handler
    delete_handler_parser = subparsers.add_parser("delete-handler", parents=[global_parser], help="Delete a reverse proxy handler")
    delete_handler_group = delete_handler_parser.add_mutually_exclusive_group(required=True)
    delete_handler_group.add_argument("--description", help="Handler description to match")
    delete_handler_group.add_argument("--uuid", help="Handler UUID to delete directly")

    # list
    subparsers.add_parser("list", parents=[global_parser], help="List all domains and handlers")

    # reconfigure
    subparsers.add_parser("reconfigure", parents=[global_parser], help="Reconfigure Caddy (apply changes)")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    # Build configuration
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

    # Execute command
    try:
        with CaddyManager(config) as manager:
            if not manager.test_connection():
                print("ERROR: Cannot connect to OPNsense firewall", file=sys.stderr)
                sys.exit(1)

            if args.debug:
                print(f"Connected to OPNsense at {config.firewall}")

            success = False
            if args.command == "add-domain":
                success = add_domain(manager, args.domain, args.description, args.check_mode)
            elif args.command == "add-handler":
                success = add_handler(
                    manager, args.domain, args.upstream, args.port,
                    args.description, args.check_mode,
                )
            elif args.command == "delete-domain":
                success = delete_domain_cmd(manager, args.domain, args.check_mode)
            elif args.command == "delete-handler":
                success = delete_handler_cmd(
                    manager,
                    description=getattr(args, "description", None),
                    uuid=getattr(args, "uuid", None),
                    check_mode=args.check_mode,
                )
            elif args.command == "list":
                success = list_all(manager)
            elif args.command == "reconfigure":
                success = reconfigure_cmd(manager, args.check_mode)

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
