#!/usr/bin/env python3
"""node-provisioner CLI — PXE provisioning of follow-on TAPPaaS nodes.

Phase N3 of docs/design/node-provisioning.md (#404 item 2). Operator flow:

    node-provisioner register tappaas3 --pool 'tanka1=single:nvme0n1'
    node-provisioner prepare --iso /path/to/prepared-pve.iso   # once
    node-provisioner enable                                    # TTL 2h
    ... power the box on (PXE first in BIOS) ...
    node-provisioner disable                                   # or TTL fires
"""

from __future__ import annotations

import argparse
import sys

from . import __version__, assets, server, service
from .log import error, info
from .registry import Registry
from .util import DEFAULT_NODE_DOMAIN, DEFAULT_PORT


def _add_firewall_options(parser: argparse.ArgumentParser) -> None:
    """dhcp-manager passthrough options (same family as dns-manager)."""
    parser.add_argument(
        "--firewall", default=None,
        help="Firewall IP/hostname (default: firewall.mgmt.internal)")
    parser.add_argument(
        "--no-ssl-verify", action="store_true",
        help="Disable SSL certificate verification (passed to dhcp-manager)")
    parser.add_argument(
        "--credential-file", default=None,
        help="OPNsense API credential file (passed to dhcp-manager)")


def cmd_register(args) -> bool:
    reg = Registry().register(args.name, macs=args.mac, pool_specs=args.pool)
    info(f"registered pending node '{reg.name}' -> {reg.path}")
    if not reg.macs:
        info("no MAC pinned — the node matches only while it is the SINGLE "
             "pending registration (add --mac to pin)")
    if not reg.pools:
        info("no pool declared — the answer will fall back to ext4 with a "
             "TODO marker; declare --pool 'tanka1=single:<disk>'")
    return True


def cmd_unregister(args) -> bool:
    if Registry().unregister(args.name):
        info(f"unregistered '{args.name}'")
        return True
    error(f"no pending registration named '{args.name}'")
    return False


def cmd_list(_args) -> bool:
    pending = Registry().list_pending()
    if not pending:
        print("no pending registrations")
        return True
    for reg in pending:
        macs = ", ".join(reg.macs) or "-"
        pools = ", ".join(
            f"{p['name']}={p['layout']}:{','.join(p['disks'])}"
            for p in reg.pools) or "-"
        print(f"{reg.name:20} macs={macs:24} pools={pools:32} "
              f"created={reg.created}")
    return True


def cmd_prepare(args) -> bool:
    assets.prepare(args.iso, port=args.port)
    return True


def cmd_serve(args) -> bool:
    server.serve(port=args.port, domain=args.domain)
    return True


def cmd_enable(args) -> bool:
    return service.enable(
        ttl=args.ttl,
        port=args.port,
        next_server=args.next_server,
        bootfile=args.bootfile,
        zone=args.zone,
        firewall=args.firewall,
        no_ssl_verify=args.no_ssl_verify,
        credential_file=args.credential_file,
    )


def cmd_disable(args) -> bool:
    return service.disable(
        zone=args.zone,
        firewall=args.firewall,
        no_ssl_verify=args.no_ssl_verify,
        credential_file=args.credential_file,
    )


def cmd_status(args) -> bool:
    return service.status(
        zone=args.zone,
        firewall=args.firewall,
        no_ssl_verify=args.no_ssl_verify,
        credential_file=args.credential_file,
    )


def main():
    parser = argparse.ArgumentParser(
        prog="node-provisioner",
        description="PXE provisioning service for follow-on TAPPaaS nodes "
                    "(design N3)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Operator flow:
  node-provisioner register tappaas3 --pool 'tanka1=single:nvme0n1'
  node-provisioner prepare --iso /var/tmp/pve-prepared.iso     # once per ISO
  node-provisioner enable                                      # TTL 2h
  ...rack the box, PXE first in BIOS, power on, walk away...
  node-provisioner disable                                     # or TTL fires

Security (design section 4): off by default, TTL-limited, registrations are
the allowlist, answers are one-shot. Serve binds 0.0.0.0 — mgmt-VLAN
placement is what scopes it (see README.md).
        """,
    )
    parser.add_argument("--version", action="version", version=__version__)
    sub = parser.add_subparsers(dest="command", help="Command to execute")

    p = sub.add_parser("register", help="Register a pending node (allowlist)")
    p.add_argument("name", help="Node name (e.g. tappaas3)")
    p.add_argument("--mac", action="append", default=[],
                   help="Pin a MAC address (repeatable)")
    p.add_argument("--pool", action="append", default=[],
                   help="Storage pool spec 'name=layout:disk[,disk...]' "
                        "(repeatable), e.g. 'tanka1=single:nvme0n1'")
    p.set_defaults(func=cmd_register)

    p = sub.add_parser("unregister", help="Remove a pending registration")
    p.add_argument("name")
    p.set_defaults(func=cmd_unregister)

    p = sub.add_parser("list", help="List pending registrations")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser(
        "prepare",
        help="Stage netboot assets from a (pre-prepared) PVE ISO")
    p.add_argument("--iso", required=True,
                   help="Path to the PVE installer ISO — run "
                        "'proxmox-auto-install-assistant prepare-iso ... "
                        "--fetch-from http --url http://<cicd>:<port>/answer' "
                        "on it first (V-2)")
    p.add_argument("--port", type=int, default=DEFAULT_PORT,
                   help=f"HTTP port baked into boot.ipxe (default {DEFAULT_PORT})")
    p.set_defaults(func=cmd_prepare)

    p = sub.add_parser("serve", help="Run the HTTP asset+answer server "
                                     "(foreground; enable runs this)")
    p.add_argument("--port", type=int, default=DEFAULT_PORT)
    p.add_argument("--domain", default=DEFAULT_NODE_DOMAIN,
                   help=f"Node FQDN domain (default {DEFAULT_NODE_DOMAIN})")
    p.set_defaults(func=cmd_serve)

    p = sub.add_parser("enable",
                       help="Start serve+TFTP (transient units), set DHCP "
                            "PXE options, arm the auto-off TTL")
    p.add_argument("--ttl", type=int, default=service.DEFAULT_TTL_SECONDS,
                   help="Seconds until auto-disable (default 7200 = 2h)")
    p.add_argument("--port", type=int, default=DEFAULT_PORT)
    p.add_argument("--next-server", default=None,
                   help="cicd mgmt IP handed to PXE clients "
                        "(default: auto-detect)")
    p.add_argument("--bootfile", default="ipxe.efi")
    p.add_argument("--zone", default="mgmt")
    _add_firewall_options(p)
    p.set_defaults(func=cmd_enable)

    p = sub.add_parser("disable", help="Stop the units + clear DHCP options")
    p.add_argument("--zone", default="mgmt")
    _add_firewall_options(p)
    p.set_defaults(func=cmd_disable)

    p = sub.add_parser("status", help="Units / registrations / DHCP state "
                                      "(exit 0 = fully enabled)")
    p.add_argument("--zone", default="mgmt")
    _add_firewall_options(p)
    p.set_defaults(func=cmd_status)

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        sys.exit(1)

    try:
        sys.exit(0 if args.func(args) else 1)
    except KeyboardInterrupt:
        error("Interrupted by user")
        sys.exit(130)
    except Exception as e:
        error(str(e))
        import os
        if os.environ.get("TAPPAAS_DEBUG") == "1":
            import traceback
            traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
