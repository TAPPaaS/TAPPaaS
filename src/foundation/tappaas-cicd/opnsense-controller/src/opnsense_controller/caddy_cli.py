#!/usr/bin/env python3
"""Caddy Reverse Proxy Management CLI for OPNsense.

This module provides a dedicated CLI for managing Caddy reverse proxy
domains and handlers on OPNsense.
"""

import argparse
import sys
from urllib.parse import urlparse

from .caddy_manager import CaddyDomain, CaddyHandler, CaddyManager
from .config import Config


def add_domain(
    manager: CaddyManager,
    domain_name: str,
    description: str = "",
    dns_challenge: bool = False,
    custom_certificate: str = "",
    check_mode: bool = False,
) -> bool:
    """Add (or reconcile) a reverse proxy domain.

    Args:
        manager: CaddyManager instance.
        domain_name: Domain FQDN (e.g., "app.test.tapaas.org").
        description: Description for the entry.
        dns_challenge: If True, issue the certificate via ACME DNS-01
            (no inbound HTTP-01 validation needed). Requires the global
            os-caddy TLS DNS provider/API key to be configured.
        custom_certificate: Refid of an OPNsense Trust certificate to use
            (issue #254 — typically the wildcard issued by os-acme-client).
            When set, Caddy serves this cert and skips its own ACME for
            the domain. Mutually exclusive with ``dns_challenge``.
        check_mode: If True, perform dry-run.

    Returns:
        True if successful.
    """
    existing = manager.get_domain_by_name(domain_name)
    if existing:
        if check_mode:
            print(f"Domain '{domain_name}' exists; would reconcile (dns_challenge={dns_challenge}, custom_certificate={custom_certificate!r}) (dry-run)")
            return True
        # Reconcile the DNS-01 setting on the existing domain.
        domain = CaddyDomain(
            domain=domain_name,
            description=description or existing.description,
            enabled=existing.enabled,
            dns_challenge=dns_challenge,
            custom_certificate=custom_certificate,
        )
        result = manager.update_domain(existing.uuid, domain)
        if result.get("result") in ("saved", None) or result.get("uuid"):
            print(f"Domain '{domain_name}' reconciled (uuid={existing.uuid}, dns_challenge={dns_challenge}, custom_certificate={custom_certificate!r})")
            return True
        print(f"ERROR: Failed to reconcile domain: {result}", file=sys.stderr)
        return False

    if check_mode:
        print(f"Would create domain: {domain_name} (dns_challenge={dns_challenge}, custom_certificate={custom_certificate!r}) (dry-run)")
        return True

    print(f"Creating domain: {domain_name}")
    domain = CaddyDomain(
        domain=domain_name,
        description=description,
        dns_challenge=dns_challenge,
        custom_certificate=custom_certificate,
    )
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
    upstream: str | None = None,
    port: str = "80",
    description: str = "",
    access_list: str = "",
    upstream_tls: bool = False,
    forward_auth: bool = False,
    check_mode: bool = False,
    redir: str = "",
    redir_path: str = "",
    upstream_http1: bool = False,
    preserve_host: bool = False,
) -> bool:
    """Add (or reconcile) a reverse-proxy OR redir handler for a domain.

    Exactly one of `upstream` (reverse_proxy) or `redir` (HTTP redirect) is used.

    For `redir`, os-caddy 2.1.0 renders ``redir <target>{uri}`` with no status
    code, so Caddy's default (302) applies — the redirect code is not
    configurable via the plugin (issue #270). The target scheme is taken from
    the URL (https → TLS), and the request path/query is preserved unless
    `redir_path` is given.

    Args:
        manager: CaddyManager instance.
        domain_name: Domain FQDN to attach the handler to.
        upstream: Reverse-proxy upstream hostname (e.g., "app.srv.internal").
        port: Upstream port.
        description: Description for the handler.
        access_list: Optional access-list NAME to attach (issue #206). Restricts
            which client networks may reach the service. Empty = unrestricted.
        upstream_tls: Reverse-proxy to an HTTPS upstream.
        forward_auth: Enable per-handle Authentik forward_auth (issue #45).
        check_mode: If True, perform dry-run.
        redir: Redirect target URL (e.g. "https://identity.example.com").
        redir_path: For redir, a fixed target path (Caddy ToPath); empty
            preserves the request path/query.

    Returns:
        True if successful.
    """
    # Find the domain UUID
    domain_info = manager.get_domain_by_name(domain_name)
    if not domain_info:
        print(f"ERROR: Domain '{domain_name}' not found. Add it first.", file=sys.stderr)
        return False

    # Resolve the access-list name to a UUID, if requested.
    access_list_uuid = ""
    if access_list:
        al = manager.get_access_list_by_name(access_list)
        if not al:
            print(f"ERROR: Access list '{access_list}' not found. Add it first.", file=sys.stderr)
            return False
        access_list_uuid = al.uuid

    if redir:
        # Parse the redirect target URL → scheme (TLS), host (ToDomain),
        # optional port (ToPort), optional path (ToPath). A bare host defaults
        # to https.
        target = redir if "://" in redir else f"https://{redir}"
        parsed = urlparse(target)
        if not parsed.hostname:
            print(f"ERROR: Could not parse redirect target '{redir}'", file=sys.stderr)
            return False
        # An explicit --redir-path wins; otherwise use the URL path unless it is
        # empty/root, in which case leave it blank so os-caddy preserves {uri}.
        to_path = redir_path or (parsed.path if parsed.path not in ("", "/") else "")
        handler = CaddyHandler(
            domain_uuid=domain_info.uuid,
            upstream_domain=parsed.hostname,
            upstream_port=str(parsed.port) if parsed.port else "",
            description=description,
            access_list_uuid=access_list_uuid,
            upstream_tls=(parsed.scheme == "https"),
            forward_auth=forward_auth,
            directive="redir",
            to_path=to_path,
        )
        scheme = "https" if parsed.scheme == "https" else "http"
        port_part = f":{parsed.port}" if parsed.port else ""
        target_desc = f"redir {scheme}://{parsed.hostname}{port_part}{to_path or '{uri}'}"
    else:
        handler = CaddyHandler(
            domain_uuid=domain_info.uuid,
            upstream_domain=upstream,
            upstream_port=str(port),
            description=description,
            access_list_uuid=access_list_uuid,
            upstream_tls=upstream_tls,
            upstream_http_version=("http1" if upstream_http1 else ""),
            host_header=(domain_name if preserve_host else ""),
            forward_auth=forward_auth,
        )
        target_desc = f"{upstream}:{port}"

    # Reconcile an existing handler (so the access list / upstream stay current)
    # rather than skipping — important for applying #206 restriction changes.
    existing = manager.get_handler_by_description(description) if description else None
    if existing:
        if check_mode:
            print(f"Would update handler: {domain_name} -> {target_desc} "
                  f"(access_list={access_list or 'none'}) (dry-run)")
            return True
        print(f"Updating handler: {domain_name} -> {target_desc} "
              f"(access_list={access_list or 'none'})")
        result = manager.update_handler(existing.uuid, handler)
        if result.get("result") in ("saved", "ok") or result.get("uuid"):
            print("  Handler updated successfully")
            return True
        print(f"ERROR: Failed to update handler: {result}", file=sys.stderr)
        return False

    if check_mode:
        print(f"Would create handler: {domain_name} -> {target_desc} "
              f"(access_list={access_list or 'none'}) (dry-run)")
        return True

    print(f"Creating handler: {domain_name} -> {target_desc} "
          f"(access_list={access_list or 'none'})")
    result = manager.add_handler(handler)

    uuid = result.get("uuid")
    if uuid:
        print(f"  Handler created successfully (uuid={uuid})")
        return True
    if result.get("result") == "saved":
        print("  Handler created successfully")
        return True

    print(f"ERROR: Failed to create handler: {result}", file=sys.stderr)
    return False


def add_access_list_cmd(
    manager: CaddyManager,
    name: str,
    clients: str,
    matcher: str = "remote_ip",
    invert: bool = False,
    response_code: int | None = None,
    description: str = "",
    check_mode: bool = False,
) -> bool:
    """Create or update a Caddy access list (issue #206).

    Args:
        manager: CaddyManager instance.
        name: Access-list name (unique key).
        clients: Comma-separated client IPs/CIDRs (e.g. "10.0.0.0/24,10.2.10.0/24").
        matcher: 'remote_ip' (direct peer) or 'client_ip' (honours trusted proxies).
        invert: False (default) = allow-list (only these pass); True = deny-list.
        response_code: HTTP code to return to blocked clients (None → abort).
        description: Description for the access list.
        check_mode: If True, perform dry-run.
    """
    from .caddy_manager import CaddyAccessList

    client_ips = [c.strip() for c in clients.split(",") if c.strip()]
    if not client_ips:
        print("ERROR: --clients must contain at least one IP/CIDR", file=sys.stderr)
        return False

    al = CaddyAccessList(
        name=name, client_ips=client_ips, invert=invert, matcher=matcher,
        response_code=response_code, description=description,
    )

    existing = manager.get_access_list_by_name(name)
    verb = "update" if existing else "create"
    if check_mode:
        print(f"Would {verb} access list '{name}': {('block' if invert else 'allow')} "
              f"{matcher} {client_ips} (dry-run)")
        return True

    print(f"{verb.capitalize()} access list '{name}': "
          f"{('block' if invert else 'allow only')} {matcher} {client_ips}")
    if existing:
        result = manager.update_access_list(existing.uuid, al)
    else:
        result = manager.add_access_list(al)

    if result.get("uuid") or result.get("result") in ("saved", "ok"):
        print(f"  Access list '{name}' {verb}d successfully")
        return True
    print(f"ERROR: Failed to {verb} access list: {result}", file=sys.stderr)
    return False


def delete_access_list_cmd(
    manager: CaddyManager,
    name: str,
    check_mode: bool = False,
) -> bool:
    """Delete a Caddy access list by name (issue #206)."""
    existing = manager.get_access_list_by_name(name)
    if not existing:
        print(f"Access list '{name}' not found — nothing to delete")
        return True
    if check_mode:
        print(f"Would delete access list '{name}' (uuid={existing.uuid}) (dry-run)")
        return True
    result = manager.delete_access_list(existing.uuid)
    if result.get("result") in ("deleted", "ok"):
        print(f"  Access list '{name}' deleted")
        return True
    print(f"ERROR: Failed to delete access list: {result}", file=sys.stderr)
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

  # Add a reverse-proxy handler for a domain
  caddy-manager add-handler app.test.tapaas.org --upstream myapp.srv.internal --port 8080 --description "TAPPaaS: myapp"

  # Add a redirect handler (issue #270): www.example.com -> https://identity.example.com (preserves path; 302)
  caddy-manager add-handler www.example.com --redir https://identity.example.com --description "TAPPaaS: www-redir"

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
    add_domain_parser.add_argument(
        "--dns-challenge",
        action="store_true",
        help="Issue the TLS certificate via ACME DNS-01 (no inbound validation; "
        "requires the global os-caddy TLS DNS provider/API key)",
    )
    add_domain_parser.add_argument(
        "--custom-certificate",
        default="",
        metavar="REFID",
        help="Use an existing OPNsense Trust certificate (refid) instead of "
        "letting Caddy fetch one via ACME. Typically the wildcard refid issued "
        "by os-acme-client (issue #254). Mutually exclusive with --dns-challenge.",
    )

    # add-handler
    add_handler_parser = subparsers.add_parser("add-handler", parents=[global_parser], help="Add a reverse proxy or redirect handler")
    add_handler_parser.add_argument("domain", help="Domain FQDN to attach the handler to")
    # Exactly one of --upstream (reverse_proxy) or --redir (HTTP redirect).
    handler_target = add_handler_parser.add_mutually_exclusive_group(required=True)
    handler_target.add_argument("--upstream", help="Reverse-proxy upstream server (e.g., app.srv.internal)")
    handler_target.add_argument(
        "--redir",
        help="Redirect target URL (e.g. https://identity.example.com) — configures a Caddy "
        "'redir' handler instead of reverse_proxy (issue #270). The request path/query is "
        "preserved unless --redir-path is given. NOTE: os-caddy emits no status code, so "
        "Caddy's default (302) applies — the redirect code is not configurable via the plugin.",
    )
    add_handler_parser.add_argument("--redir-path", default="", help="For --redir: fixed target path (e.g. /ui/); omit to preserve the request path/query")
    add_handler_parser.add_argument("--port", default="80", help="Upstream port (default: 80; reverse_proxy only)")
    add_handler_parser.add_argument("--description", default="", help="Description for the handler")
    add_handler_parser.add_argument("--access-list", default="", help="Name of an access list to attach (issue #206) — restrict client networks")
    add_handler_parser.add_argument("--upstream-tls", action="store_true", help="Reverse-proxy to an HTTPS upstream (e.g. the OPNsense GUI on :8443); skips upstream cert verification")
    add_handler_parser.add_argument("--upstream-http1", action="store_true", help="Force HTTP/1.1 to the upstream (os-caddy HttpVersion=http1). Required for WebSocket apps behind a TLS upstream (e.g. the UniFi OS console), which otherwise 500 on the WS over HTTP/2 (#339)")
    add_handler_parser.add_argument("--preserve-host", action="store_true", help="Force the upstream Host header to the public domain (header_up Host <domain>). Needed for apps that validate a WebSocket's Origin against the Host header (e.g. UniFi OS), which otherwise 500 because Caddy sends the upstream's own hostname (#339)")
    add_handler_parser.add_argument("--forward-auth", action="store_true",
                                    help="Enable Caddy per-handle forward_auth — redirects unauthenticated "
                                    "requests through the global Authentik outpost (issue #45). Requires "
                                    "the global AuthProvider to be configured (done by identity install).")

    # add-accesslist (issue #206)
    add_al_parser = subparsers.add_parser("add-accesslist", parents=[global_parser], help="Create/update an access list (client-IP allow/deny)")
    add_al_parser.add_argument("name", help="Access list name (unique key)")
    add_al_parser.add_argument("--clients", required=True, help="Comma-separated IPs/CIDRs, e.g. 10.0.0.0/24,10.2.10.0/24")
    add_al_parser.add_argument("--matcher", default="remote_ip", choices=["remote_ip", "client_ip"], help="Match the direct peer (remote_ip, default) or honour trusted proxies (client_ip)")
    add_al_parser.add_argument("--invert", action="store_true", help="Make it a deny-list (block the listed networks) instead of an allow-list")
    add_al_parser.add_argument("--response-code", type=int, default=None, help="HTTP code returned to blocked clients (default: abort the connection)")
    add_al_parser.add_argument("--description", default="", help="Description for the access list")

    # delete-accesslist (issue #206)
    del_al_parser = subparsers.add_parser("delete-accesslist", parents=[global_parser], help="Delete an access list by name")
    del_al_parser.add_argument("name", help="Access list name to delete")

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
                success = add_domain(
                    manager, args.domain, args.description,
                    args.dns_challenge, args.custom_certificate, args.check_mode,
                )
            elif args.command == "add-handler":
                success = add_handler(
                    manager, args.domain, args.upstream, args.port,
                    args.description, args.access_list, args.upstream_tls,
                    args.forward_auth, args.check_mode,
                    redir=args.redir, redir_path=args.redir_path,
                    upstream_http1=args.upstream_http1,
                    preserve_host=args.preserve_host,
                )
            elif args.command == "add-accesslist":
                success = add_access_list_cmd(
                    manager, args.name, args.clients, args.matcher,
                    args.invert, args.response_code, args.description, args.check_mode,
                )
            elif args.command == "delete-accesslist":
                success = delete_access_list_cmd(manager, args.name, args.check_mode)
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
