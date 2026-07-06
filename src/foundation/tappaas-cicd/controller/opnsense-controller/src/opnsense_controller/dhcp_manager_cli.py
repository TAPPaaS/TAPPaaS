#!/usr/bin/env python3
"""DHCP Management CLI for OPNsense Dnsmasq — PXE boot options (design N3).

Front door for the node-provisioning netboot plane
(docs/design/node-provisioning.md, Phase N3): sets/clears the DHCP
``next-server`` + bootfile on a zone's DHCP scope so follow-on TAPPaaS nodes
can PXE-boot the Proxmox VE automated installer served by tappaas-cicd's
``node-provisioner``.

Backend: OPNsense's dnsmasq plane (the same one zone-manager/dns-manager
drive) — its ``dhcp_boot`` grid renders ``dhcp-boot=[tag:x,]filename
[,servername[,address]]``, i.e. the DHCP header bootfile + next-server.

iPXE chainload: plain next-server+filename is enough when the TFTP-served
iPXE binary carries an embedded script (or the firmware itself is iPXE).
For a stock iPXE binary the classic DHCP loop (iPXE re-DHCPs and is handed
itself again) is broken with a dnsmasq conditional: ``--ipxe-script-url``
adds a match on DHCP option 175 (sent by iPXE) that hands iPXE the boot
script URL instead of the binary. TODO(V-2): OPNsense validates the option
number against its dnsmasq option catalogue — verify option "175" is
accepted on the deployed firewall version; on rejection this CLI degrades
to the plain entry with a warning.
"""

import argparse
import sys

from .config import Config
from .dhcp_manager import DhcpManager
from .log import error, info, warn
from .vlan_manager import VlanManager

# The default TAPPaaS provisioning scope: the mgmt zone is the untagged
# control plane (zones.json: vlantag 0, bridge "lan"), so its OPNsense
# interface identifier is simply "lan".
DEFAULT_ZONE = "mgmt"
UNTAGGED_ZONE_INTERFACES = {"mgmt": "lan", "lan": "lan", "wan": "wan"}

IPXE_TAG = "tappaas_ipxe"


def _boot_description(zone: str) -> str:
    return f"TAPPaaS PXE boot ({zone})"


def _chain_description(zone: str) -> str:
    return f"TAPPaaS PXE ipxe-chain ({zone})"


def _match_description(zone: str) -> str:
    return f"TAPPaaS PXE ipxe-match ({zone})"


def resolve_zone_interface(config: Config, zone: str) -> str:
    """Resolve a TAPPaaS zone name to its OPNsense interface identifier.

    Untagged zones (mgmt/lan/wan) map directly; VLAN zones are matched by
    the assigned-interface description (the post-#237 SSOT: interface labels
    equal zone keys).
    """
    zone_l = zone.lower()
    if zone_l in UNTAGGED_ZONE_INTERFACES:
        return UNTAGGED_ZONE_INTERFACES[zone_l]

    with VlanManager(config) as vlan_mgr:
        for v in vlan_mgr.get_assigned_vlans():
            if (v.get("description") or "").lower() == zone_l:
                return v["identifier"]
    raise LookupError(
        f"No OPNsense interface found for zone '{zone}' "
        "(no assigned VLAN carries that label; is the zone enabled?)"
    )


def pxe_enable(
    manager: DhcpManager,
    zone: str,
    interface: str,
    next_server: str,
    bootfile: str,
    ipxe_script_url: str | None,
    check_mode: bool = False,
) -> bool:
    """Set PXE boot options on the zone's DHCP scope (idempotent)."""
    if check_mode:
        info(f"[dry-run] would set dhcp-boot on '{interface}': "
             f"file={bootfile} next-server={next_server}")
        if ipxe_script_url:
            info(f"[dry-run] would add iPXE chainload -> {ipxe_script_url}")
        return True

    staged = False

    # Optional iPXE chainload conditional FIRST (so a failure degrades to
    # the plain entry before anything is applied).
    if ipxe_script_url:
        try:
            tag_uuid = manager.ensure_dhcp_tag(IPXE_TAG)
            manager.create_match_option(
                option="175",  # iPXE feature list — presence identifies iPXE
                set_tag=tag_uuid,
                description=_match_description(zone),
                reconfigure=False,
            )
            manager.set_boot_entry(
                filename=ipxe_script_url,
                description=_chain_description(zone),
                interface=interface,
                tag=tag_uuid,
                reconfigure=False,
            )
            staged = True
            info(f"iPXE chainload conditional staged -> {ipxe_script_url}")
        except Exception as e:  # degrade to plain entry (V-2)
            warn(f"iPXE chainload conditional not accepted by firewall: {e}")
            warn("Falling back to plain next-server+bootfile. The TFTP-served "
                 "iPXE binary must then carry an embedded script (or the "
                 "client firmware must be natively iPXE) to avoid the "
                 "PXE re-DHCP loop. TODO(V-2).")

    manager.set_boot_entry(
        filename=bootfile,
        address=next_server,
        description=_boot_description(zone),
        interface=interface,
        reconfigure=False,
    )
    staged = True

    if staged:
        manager.reconfigure()
    info(f"PXE enabled on zone '{zone}' (interface {interface}): "
         f"next-server={next_server} bootfile={bootfile}")
    return True


def pxe_disable(manager: DhcpManager, zone: str, check_mode: bool = False) -> bool:
    """Clear all TAPPaaS PXE boot options for the zone (idempotent)."""
    if check_mode:
        info(f"[dry-run] would clear TAPPaaS PXE entries for zone '{zone}'")
        return True

    changed = False
    for step, fn in (
        ("boot entry", lambda: manager.delete_boot_entry(
            _boot_description(zone), reconfigure=False)),
        ("ipxe-chain entry", lambda: manager.delete_boot_entry(
            _chain_description(zone), reconfigure=False)),
        ("ipxe-match option", lambda: manager.delete_option_by_description(
            _match_description(zone), reconfigure=False)),
    ):
        try:
            result = fn()
            changed = changed or result.get("changed", False)
        except Exception as e:
            warn(f"Could not remove {step}: {e}")

    # The shared tag is only removed once nothing references it; a failure
    # here (still referenced by another zone's chain entry) is harmless.
    try:
        result = manager.delete_dhcp_tag(IPXE_TAG, reconfigure=False)
        changed = changed or result.get("changed", False)
    except Exception as e:
        warn(f"Could not remove tag '{IPXE_TAG}' (still referenced?): {e}")

    if changed:
        manager.reconfigure()
        info(f"PXE disabled on zone '{zone}'")
    else:
        info(f"PXE was not enabled on zone '{zone}' (nothing to clear)")
    return True


def pxe_status(manager: DhcpManager, zone: str) -> bool:
    """Show TAPPaaS PXE state for the zone. Exit 0 = enabled, 1 = disabled."""
    entries = manager.list_boot_entries()
    tappaas_entries = [
        e for e in entries
        if (e.get("description") or "").startswith("TAPPaaS PXE")
    ]
    boot = manager.get_boot_by_description(_boot_description(zone))
    chain = manager.get_boot_by_description(_chain_description(zone))

    if not tappaas_entries:
        print(f"PXE: disabled (no TAPPaaS boot entries; zone '{zone}')")
        return False

    print(f"PXE: {'enabled' if boot else 'disabled'} (zone '{zone}')")
    for e in tappaas_entries:
        tagged = " [tagged]" if e.get("tag") else ""
        print(
            f"  {e.get('description')}: file={e.get('filename')} "
            f"next-server={e.get('address') or '-'} "
            f"interface={e.get('interface') or 'any'}{tagged}"
        )
    if chain:
        print("  iPXE chainload conditional: active")
    return bool(boot)


def main():
    """Main entry point for the DHCP manager CLI."""
    parser = argparse.ArgumentParser(
        description="DHCP scope management for OPNsense Dnsmasq (PXE boot options)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Enable PXE on the mgmt scope (node-provisioner enable calls this)
  dhcp-manager pxe enable --next-server 10.0.0.10 --bootfile ipxe.efi

  # ... with an iPXE chainload conditional (breaks the stock-iPXE DHCP loop)
  dhcp-manager pxe enable --next-server 10.0.0.10 \\
      --ipxe-script-url http://10.0.0.10:8090/boot.ipxe

  # Clear the PXE options again (always do this after provisioning!)
  dhcp-manager pxe disable

  # Show current state (exit 0 when enabled, 1 when not)
  dhcp-manager pxe status
        """,
    )

    # Global options (same family as dns-manager)
    parser.add_argument(
        "--firewall",
        default="firewall.mgmt.internal",
        help="Firewall IP/hostname (default: firewall.mgmt.internal)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=None,
        help="API port (default: auto-detect by probing 443, then 8443)",
    )
    parser.add_argument(
        "--credential-file",
        help="Path to credential file (default: $HOME/.opnsense-credentials.txt)",
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
        "--check-mode",
        action="store_true",
        help="Dry-run mode (don't make actual changes)",
    )

    subparsers = parser.add_subparsers(dest="command", help="Command to execute")

    # pxe command group
    pxe_parser = subparsers.add_parser(
        "pxe", help="PXE boot options on a zone's DHCP scope"
    )
    pxe_sub = pxe_parser.add_subparsers(dest="pxe_command", help="PXE action")

    enable_parser = pxe_sub.add_parser(
        "enable", help="Set next-server + bootfile on the zone's DHCP scope"
    )
    enable_parser.add_argument(
        "--next-server", required=True,
        help="TFTP server IPv4 handed to PXE clients (the cicd mgmt IP)",
    )
    enable_parser.add_argument(
        "--bootfile", default="ipxe.efi",
        help="Boot file name for PXE firmware (default: ipxe.efi)",
    )
    enable_parser.add_argument(
        "--zone", default=DEFAULT_ZONE,
        help=f"TAPPaaS zone whose DHCP scope gets the options (default: {DEFAULT_ZONE})",
    )
    enable_parser.add_argument(
        "--interface",
        help="Explicit OPNsense interface identifier (overrides zone lookup)",
    )
    enable_parser.add_argument(
        "--ipxe-script-url",
        help="Also add an iPXE chainload conditional: clients identifying as "
             "iPXE (DHCP option 175) are handed this script URL instead of "
             "the bootfile (breaks the stock-iPXE DHCP loop)",
    )

    disable_parser = pxe_sub.add_parser(
        "disable", help="Clear the TAPPaaS PXE boot options"
    )
    disable_parser.add_argument("--zone", default=DEFAULT_ZONE)

    status_parser = pxe_sub.add_parser(
        "status", help="Show PXE state (exit 0 = enabled, 1 = disabled)"
    )
    status_parser.add_argument("--zone", default=DEFAULT_ZONE)

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)
    if args.command == "pxe" and not getattr(args, "pxe_command", None):
        pxe_parser.print_help()
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
        error(f"Configuration error: {e}")
        sys.exit(1)

    try:
        with DhcpManager(config) as manager:
            if not manager.test_connection():
                error("Cannot connect to OPNsense firewall")
                sys.exit(1)

            success = False
            if args.pxe_command == "enable":
                interface = args.interface or resolve_zone_interface(
                    config, args.zone
                )
                success = pxe_enable(
                    manager,
                    zone=args.zone,
                    interface=interface,
                    next_server=args.next_server,
                    bootfile=args.bootfile,
                    ipxe_script_url=args.ipxe_script_url,
                    check_mode=args.check_mode,
                )
            elif args.pxe_command == "disable":
                success = pxe_disable(manager, args.zone, args.check_mode)
            elif args.pxe_command == "status":
                success = pxe_status(manager, args.zone)

            sys.exit(0 if success else 1)

    except KeyboardInterrupt:
        error("Interrupted by user")
        sys.exit(130)
    except Exception as e:
        error(str(e))
        if args.debug:
            import traceback
            traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
