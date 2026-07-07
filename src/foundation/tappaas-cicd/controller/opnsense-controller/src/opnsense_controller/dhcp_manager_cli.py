#!/usr/bin/env python3
"""DHCP Management CLI for OPNsense Dnsmasq — PXE boot options (design N3).

Front door for the node-provisioning netboot plane
(docs/design/node-provisioning.md, Phase N3): sets/clears the DHCP
``next-server`` + bootfile on a zone's DHCP scope so follow-on TAPPaaS nodes
can PXE-boot the Proxmox VE automated installer served by tappaas-cicd's
``node-provisioner``.

Backend (stage-1 hardware finding): the PXE lines are written as ONE owned
drop-in file, ``/usr/local/etc/dnsmasq.conf.d/tappaas-pxe.conf`` — the
dnsmasq plugin's sanctioned extension point (``conf-dir=...,*.conf``) —
because breaking the stock-iPXE DHCP loop REQUIRES a negated tag
(``dhcp-boot=tag:<if>,tag:!<ipxe>,...``) and the OPNsense dnsmasq model
rejects negated tag references ("Option [!uuid] not in list", probed on
25.7). The file is deployed over ssh (root@firewall, the same trust the
foundation scripts use) and survives every OPNsense reconfigure; disable
removes it. The dnsmasq mechanics: clients identifying as iPXE (DHCP
option 175) are handed the chainload script URL, everyone else gets
next-server + the iPXE binary.

Host reservations (``host set``/``host del``) pin a node's MACs to its
standard mgmt IP via the regular OPNsense API (the model supports those) —
used by node-provisioner at answer-serve time so a freshly installed node
boots straight onto its reserved 10.0.0.1x address.
"""

import argparse
import os
import subprocess
import sys

from .config import Config
from .dhcp_manager import DhcpManager
from .log import error, info
from .vlan_manager import VlanManager

# The default TAPPaaS provisioning scope: the mgmt zone is the untagged
# control plane (zones.json: vlantag 0, bridge "lan"), so its OPNsense
# interface identifier is simply "lan".
DEFAULT_ZONE = "mgmt"
UNTAGGED_ZONE_INTERFACES = {"mgmt": "lan", "lan": "lan", "wan": "wan"}

IPXE_TAG = "tappaas_ipxe"          # legacy API-object tag (cleanup only)
CONF_D_FILE = "/usr/local/etc/dnsmasq.conf.d/tappaas-pxe.conf"
IPXE_CONF_TAG = "tappaas-ipxe"     # raw dnsmasq tag name in the drop-in


def _boot_description(zone: str) -> str:
    return f"TAPPaaS PXE boot ({zone})"


def _chain_description(zone: str) -> str:
    return f"TAPPaaS PXE ipxe-chain ({zone})"


def _match_description(zone: str) -> str:
    return f"TAPPaaS PXE ipxe-match ({zone})"


def _fw_sh(config: Config, script: str) -> subprocess.CompletedProcess:
    """Run a bourne script on the firewall over ssh.

    root@firewall's login shell is csh — pipe the script to ``sh -s``
    instead of quoting through csh (the established TAPPaaS pattern).
    In root context (sudo node-provisioner, the TTL unit) root@cicd holds
    no firewall key — fall back to the operator's DEDICATED firewall key
    (~tappaas/.ssh/tappaas-fw, wired up by config-firewall.sh; the general
    id_ed25519 is NOT authorized on the firewall), mirroring the
    credential-file fallback.
    """
    cmd = ["ssh", "-o", "BatchMode=yes",
           "-o", "StrictHostKeyChecking=accept-new"]
    if os.geteuid() == 0:
        fw_key = "/home/tappaas/.ssh/tappaas-fw"
        if os.path.isfile(fw_key):
            cmd += ["-i", fw_key, "-o", "IdentitiesOnly=yes"]
    cmd += [f"root@{config.firewall}", "sh -s"]
    return subprocess.run(cmd, input=script, text=True, capture_output=True)


def _resolve_device(config: Config, interface: str) -> str:
    """OPNsense interface identifier (lan/opt1/...) -> OS device (vtnet0/...).

    The raw dnsmasq drop-in needs the OS device name (the generated config
    tags scopes as ``tag:<device>``); ``pluginctl -g`` reads it from the
    firewall's config.xml.
    """
    result = _fw_sh(config, f"pluginctl -g interfaces.{interface}.if\n")
    device = (result.stdout or "").strip().splitlines()[-1].strip() \
        if result.stdout.strip() else ""
    if result.returncode != 0 or not device or device == "null":
        raise RuntimeError(
            f"cannot resolve OS device for interface '{interface}' via "
            f"pluginctl on {config.firewall}: "
            f"{(result.stderr or result.stdout).strip()}")
    return device


def _legacy_api_cleanup(manager: DhcpManager, zone: str) -> bool:
    """Remove PXE entries an older dhcp-manager created as API objects."""
    changed = False
    for fn in (
        lambda: manager.delete_boot_entry(_boot_description(zone),
                                          reconfigure=False),
        lambda: manager.delete_boot_entry(_chain_description(zone),
                                          reconfigure=False),
        lambda: manager.delete_option_by_description(_match_description(zone),
                                                     reconfigure=False),
        lambda: manager.delete_dhcp_tag(IPXE_TAG, reconfigure=False),
    ):
        try:
            changed = fn().get("changed", False) or changed
        except Exception:
            pass
    return changed


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


def _render_conf(device: str, next_server: str, bootfile: str,
                 ipxe_script_url: str | None) -> str:
    """Render the tappaas-pxe.conf drop-in.

    Non-iPXE clients (firmware PXE) get next-server + the iPXE binary;
    clients already running iPXE (they send DHCP option 175) get the
    chainload script URL — the negated tag on the first line is what breaks
    the stock-iPXE self-download loop, and is exactly the construct the
    OPNsense API cannot express. servername AND address are both set:
    dnsmasq's 3-field form parses the third field as servername and clients
    then fall back to the DHCP server itself as next-server (stage-1
    PXE-E18 finding).
    """
    lines = [
        "# TAPPaaS PXE provisioning (node-provisioner, design N3).",
        "# Managed by 'dhcp-manager pxe enable/disable' — do not edit;",
        "# present ONLY while a provisioning window is open.",
        f"dhcp-match=set:{IPXE_CONF_TAG},175",
        f"dhcp-boot=tag:{device},tag:!{IPXE_CONF_TAG},"
        f"{bootfile},{next_server},{next_server}",
    ]
    if ipxe_script_url:
        lines.append(
            f"dhcp-boot=tag:{device},tag:{IPXE_CONF_TAG},{ipxe_script_url}")
    return "\n".join(lines) + "\n"


def pxe_enable(
    manager: DhcpManager,
    config: Config,
    zone: str,
    interface: str,
    next_server: str,
    bootfile: str,
    ipxe_script_url: str | None,
    check_mode: bool = False,
) -> bool:
    """Deploy the PXE drop-in on the firewall (idempotent)."""
    device = _resolve_device(config, interface)
    conf = _render_conf(device, next_server, bootfile, ipxe_script_url)
    if check_mode:
        info(f"[dry-run] would write {CONF_D_FILE} (interface {interface} "
             f"= {device}):\n{conf}")
        return True

    # Migrate away from the API-object shape of older versions.
    if _legacy_api_cleanup(manager, zone):
        manager.reconfigure()
        info("removed legacy API-object PXE entries")

    script = (
        f"cat > {CONF_D_FILE} <<'TAPPAAS_EOF'\n{conf}TAPPAAS_EOF\n"
        "configctl dnsmasq restart >/dev/null\n"
        "dnsmasq --test --conf-file=/usr/local/etc/dnsmasq.conf "
        "2>&1 | tail -1\n"
    )
    result = _fw_sh(config, script)
    if result.returncode != 0:
        raise RuntimeError(
            f"deploying {CONF_D_FILE} failed: "
            f"{(result.stderr or result.stdout).strip()}")

    info(f"PXE enabled on zone '{zone}' ({device}): "
         f"next-server={next_server} bootfile={bootfile}"
         + (f" chainload={ipxe_script_url}" if ipxe_script_url else ""))
    return True


def pxe_disable(manager: DhcpManager, config: Config, zone: str,
                check_mode: bool = False) -> bool:
    """Remove the PXE drop-in (and any legacy API entries). Idempotent."""
    if check_mode:
        info(f"[dry-run] would remove {CONF_D_FILE}")
        return True

    if _legacy_api_cleanup(manager, zone):
        manager.reconfigure()
        info("removed legacy API-object PXE entries")

    result = _fw_sh(config, (
        f"if [ -f {CONF_D_FILE} ]; then rm -f {CONF_D_FILE} && "
        f"configctl dnsmasq restart >/dev/null && echo removed; "
        f"else echo absent; fi\n"))
    if result.returncode != 0:
        raise RuntimeError(
            f"removing {CONF_D_FILE} failed: "
            f"{(result.stderr or result.stdout).strip()}")
    if "removed" in result.stdout:
        info(f"PXE disabled on zone '{zone}'")
    else:
        info(f"PXE was not enabled on zone '{zone}' (nothing to clear)")
    return True


def pxe_status(manager: DhcpManager, config: Config, zone: str) -> bool:
    """Show TAPPaaS PXE state. Exit 0 = enabled, 1 = disabled."""
    result = _fw_sh(config, f"cat {CONF_D_FILE} 2>/dev/null || true\n")
    conf = result.stdout.strip()
    legacy = [e for e in manager.list_boot_entries()
              if (e.get("description") or "").startswith("TAPPaaS PXE")]

    if not conf and not legacy:
        print(f"PXE: disabled (no TAPPaaS boot entries; zone '{zone}')")
        return False
    if conf:
        print(f"PXE: enabled (zone '{zone}', {CONF_D_FILE})")
        for line in conf.splitlines():
            if not line.startswith("#"):
                print(f"  {line}")
    for e in legacy:
        print(f"  LEGACY API entry: {e.get('description')} "
              f"file={e.get('filename')} — run pxe disable to migrate")
    return bool(conf)


def host_set(manager: DhcpManager, name: str, ip: str, macs: list,
             domain: str | None, check_mode: bool = False) -> bool:
    """Pin a node's MACs to its standard mgmt IP (dnsmasq reservation).

    Reservations may sit OUTSIDE the dynamic dhcp-range — that is the
    normal dnsmasq way to pin infrastructure addresses (the mgmt pool
    starts at .100 precisely to keep .10-.18 free for the nodes). Multiple
    MACs on one reservation are supported for machines that boot from
    different ports (one active at a time).
    """
    if check_mode:
        info(f"[dry-run] would reserve {ip} for {name} "
             f"(macs: {', '.join(macs)})")
        return True
    manager.pin_host_macs(
        host=name, ip=ip, macs=macs, domain=domain,
        description=f"TAPPaaS node {name}")
    info(f"reserved {ip} for {name} (macs: {', '.join(macs)})")
    return True


def host_del(manager: DhcpManager, name: str, domain: str | None,
             check_mode: bool = False) -> bool:
    """Clear a node's MAC pinning (the DNS host entry itself stays)."""
    if check_mode:
        info(f"[dry-run] would clear MAC pinning for '{name}'")
        return True
    existing = manager.get_host_row(name, domain)
    if not existing or not existing.get("hwaddr"):
        info(f"no MAC pinning for {name}")
        return True
    manager.pin_host_macs(
        host=name, ip=existing.get("ip", ""), macs=[], domain=domain,
        description="")
    info(f"cleared MAC pinning for {name} (DNS host entry kept)")
    return True


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

    # host command group — node MAC -> standard-IP reservations
    host_parser = subparsers.add_parser(
        "host", help="Static DHCP reservations for TAPPaaS nodes"
    )
    host_sub = host_parser.add_subparsers(dest="host_command", help="Action")

    hset = host_sub.add_parser(
        "set", help="Reserve a node's standard mgmt IP for its MAC(s)"
    )
    hset.add_argument("name", help="Node name (e.g. tappaas4)")
    hset.add_argument("--ip", required=True,
                      help="Reserved IPv4 (e.g. 10.0.0.13)")
    hset.add_argument("--mac", action="append", required=True, default=[],
                      help="MAC address (repeatable — one per NIC the "
                           "machine may boot from)")
    hset.add_argument("--domain", default="mgmt.internal",
                      help="DNS domain for the reservation "
                           "(default: mgmt.internal)")

    hdel = host_sub.add_parser(
        "del", help="Clear a node's MAC pinning (DNS entry kept)")
    hdel.add_argument("name", help="Node name (e.g. tappaas4)")
    hdel.add_argument("--domain", default="mgmt.internal",
                      help="DNS domain of the entry (default: mgmt.internal)")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)
    if args.command == "pxe" and not getattr(args, "pxe_command", None):
        pxe_parser.print_help()
        sys.exit(1)
    if args.command == "host" and not getattr(args, "host_command", None):
        host_parser.print_help()
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
            if args.command == "pxe":
                if args.pxe_command == "enable":
                    interface = args.interface or resolve_zone_interface(
                        config, args.zone
                    )
                    success = pxe_enable(
                        manager,
                        config,
                        zone=args.zone,
                        interface=interface,
                        next_server=args.next_server,
                        bootfile=args.bootfile,
                        ipxe_script_url=args.ipxe_script_url,
                        check_mode=args.check_mode,
                    )
                elif args.pxe_command == "disable":
                    success = pxe_disable(manager, config, args.zone,
                                          args.check_mode)
                elif args.pxe_command == "status":
                    success = pxe_status(manager, config, args.zone)
            elif args.command == "host":
                if args.host_command == "set":
                    success = host_set(manager, args.name, args.ip,
                                       args.mac, args.domain,
                                       args.check_mode)
                elif args.host_command == "del":
                    success = host_del(manager, args.name, args.domain,
                                       args.check_mode)

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
