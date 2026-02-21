#!/usr/bin/env python3
"""Zone Manager for TAPPaaS.

This module reads zone definitions from zones.json and configures:
- VLANs for each enabled zone
- DHCP ranges for each enabled zone (configurable via DHCP-start/DHCP-end, defaults: .50 to .250)
- Firewall rules based on access-to field (optional, use --firewall-rules)

Usage:
    zone-manager --zones-file /path/to/zones.json --execute
    zone-manager --zones-file /path/to/zones.json --execute --firewall-rules
    zone-manager --firewall-rules-only --execute
"""

import argparse
import ipaddress
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path

from .config import Config
from .dhcp_manager import DhcpManager, DhcpRange
from .firewall_manager import FirewallManager, FirewallRule, FirewallRuleInfo, RuleAction
from .vlan_manager import Vlan, VlanManager


@dataclass
class Zone:
    """Represents a TAPPaaS network zone."""

    name: str
    zone_type: str
    state: str
    type_id: str
    sub_id: str
    vlan_tag: int
    ip_network: str
    bridge: str
    description: str
    access_to: list[str]
    pinhole_allowed_from: list[str]
    ssid: str | None = None
    dhcp_start_offset: int = 50
    dhcp_end_offset: int = 250

    @classmethod
    def from_json(cls, name: str, data: dict) -> "Zone":
        """Create a Zone from JSON data."""
        return cls(
            name=name,
            zone_type=data.get("type", ""),
            state=data.get("state", ""),
            type_id=data.get("typeId", ""),
            sub_id=data.get("subId", ""),
            vlan_tag=data.get("vlantag", 0),
            ip_network=data.get("ip", ""),
            bridge=data.get("bridge", "lan"),
            description=data.get("description", ""),
            access_to=data.get("access-to", []),
            pinhole_allowed_from=data.get("pinhole-allowed-from", []),
            ssid=data.get("SSID"),
            dhcp_start_offset=data.get("DHCP-start", 50),
            dhcp_end_offset=data.get("DHCP-end", 250),
        )

    @property
    def is_enabled(self) -> bool:
        """Check if zone is enabled (Active or Mandatory)."""
        return self.state.lower() in ("active", "mandatory", "manadatory")

    @property
    def is_manual(self) -> bool:
        """Check if zone is manually managed (neither created nor removed)."""
        return self.state.lower() == "manual"

    @property
    def is_inactive(self) -> bool:
        """Check if zone is inactive (defined but not managed)."""
        return self.state.lower() == "inactive"

    @property
    def needs_vlan(self) -> bool:
        """Check if zone needs a VLAN (tag > 0)."""
        return self.vlan_tag > 0

    @property
    def network(self) -> ipaddress.IPv4Network:
        """Get the IP network as an IPv4Network object."""
        return ipaddress.IPv4Network(self.ip_network, strict=False)

    @property
    def gateway_ip(self) -> str:
        """Get the gateway IP (first usable address, typically .1)."""
        return str(list(self.network.hosts())[0])

    @property
    def dhcp_start(self) -> str:
        """Get DHCP range start IP (default .50, configurable via DHCP-start)."""
        network = self.network
        return str(network.network_address + self.dhcp_start_offset)

    @property
    def dhcp_end(self) -> str:
        """Get DHCP range end IP (default .250, configurable via DHCP-end)."""
        network = self.network
        return str(network.network_address + self.dhcp_end_offset)

    @property
    def domain(self) -> str:
        """Get the domain name for this zone."""
        return f"{self.name}.internal"

    @property
    def vlan_description(self) -> str:
        """Get the standard VLAN description for this zone."""
        return self.description

    @property
    def dhcp_description(self) -> str:
        """Get the standard DHCP range description for this zone."""
        return f"{self.name} DHCP"


class ZoneManager:
    """Manager for configuring TAPPaaS zones on OPNsense."""

    # Default mapping of bridge names to physical interfaces
    DEFAULT_BRIDGE_MAP = {
        "lan": "vtnet0",
        "wan": "vtnet1",
    }

    # RFC1918 private address ranges used to block inter-zone traffic
    # when a zone only has internet access (not access to all internal zones)
    RFC1918_NETWORKS = [
        ("10.0.0.0/8", "rfc1918-10"),
        ("172.16.0.0/12", "rfc1918-172"),
        ("192.168.0.0/16", "rfc1918-192"),
    ]

    def __init__(
        self,
        config: Config,
        zones_file: str | Path,
        interface: str = "vtnet0",
        bridge_map: dict[str, str] | None = None,
    ):
        """Initialize the zone manager.

        Args:
            config: OPNsense connection configuration
            zones_file: Path to zones.json file
            interface: Default physical interface for VLANs (default: vtnet0)
            bridge_map: Mapping of bridge names to physical interfaces
        """
        self.config = config
        self.zones_file = Path(zones_file)
        self.interface = interface
        self.bridge_map = bridge_map or self.DEFAULT_BRIDGE_MAP.copy()
        self.zones: list[Zone] = []

    def get_interface_for_bridge(self, bridge: str) -> str:
        """Get the physical interface for a bridge name.

        Args:
            bridge: Bridge name (e.g., 'LAN', 'WAN')

        Returns:
            Physical interface name (e.g., 'vtnet0')
        """
        # Normalize to lowercase for lookup
        bridge_lower = bridge.lower()
        return self.bridge_map.get(bridge_lower, self.interface)

    def load_zones(self) -> list[Zone]:
        """Load zones from the JSON file."""
        if not self.zones_file.exists():
            raise FileNotFoundError(f"Zones file not found: {self.zones_file}")

        with open(self.zones_file) as f:
            data = json.load(f)

        self.zones = [Zone.from_json(name, zone_data) for name, zone_data in data.items()]
        return self.zones

    def get_enabled_zones(self) -> list[Zone]:
        """Get all enabled zones."""
        return [z for z in self.zones if z.is_enabled]

    def get_disabled_zones(self) -> list[Zone]:
        """Get all disabled zones (excludes manual zones)."""
        return [z for z in self.zones if not z.is_enabled and not z.is_manual]

    def get_manual_zones(self) -> list[Zone]:
        """Get all manually managed zones."""
        return [z for z in self.zones if z.is_manual]

    def get_vlan_zones(self) -> list[Zone]:
        """Get enabled zones that need VLANs (tag > 0)."""
        return [z for z in self.get_enabled_zones() if z.needs_vlan]

    def get_disabled_vlan_zones(self) -> list[Zone]:
        """Get disabled zones that have VLANs (tag > 0, excludes manual zones)."""
        return [z for z in self.get_disabled_zones() if z.needs_vlan]

    def get_dhcp_zones(self) -> list[Zone]:
        """Get enabled zones that need DHCP (tag > 0, excludes untagged zones)."""
        return [z for z in self.get_enabled_zones() if z.needs_vlan]

    def get_disabled_dhcp_zones(self) -> list[Zone]:
        """Get disabled zones that have DHCP (tag > 0, excludes manual and untagged zones)."""
        return [z for z in self.get_disabled_zones() if z.needs_vlan]

    def get_firewall_zones(self) -> list[Zone]:
        """Get enabled zones that need firewall rules (have access-to defined)."""
        return [z for z in self.get_enabled_zones() if z.access_to]

    def get_zone_by_name(self, name: str) -> Zone | None:
        """Find a zone by its name.

        Args:
            name: Zone name to search for

        Returns:
            Zone if found, None otherwise
        """
        for zone in self.zones:
            if zone.name.lower() == name.lower():
                return zone
        return None

    def get_zone_interface(self, zone: Zone) -> str | None:
        """Get the OPNsense interface identifier for a zone.

        For VLAN zones, this looks up the assigned interface.
        For untagged zones, returns the bridge name (lan/wan).

        Args:
            zone: Zone to get interface for

        Returns:
            Interface identifier (e.g., 'lan', 'srv', 'opt1') or None if not found
        """
        if zone.needs_vlan:
            # For VLAN zones, find the assigned interface by zone name
            with VlanManager(self.config) as vlan_mgr:
                assigned = vlan_mgr.get_assigned_vlans()
                for v in assigned:
                    # Check by VLAN tag or by interface description/name
                    if v["vlan_tag"] == str(zone.vlan_tag):
                        return v["identifier"]
                    # Also check if the interface name matches the zone name
                    if v.get("description", "").lower() == zone.name.lower():
                        return v["identifier"]
            return None
        else:
            # For untagged zones, use the bridge directly
            return zone.bridge.lower()

    def get_destination_for_target(self, target: str) -> str:
        """Get the destination network for a firewall rule target.

        Args:
            target: Target zone name, 'internet', or 'all'

        Returns:
            Destination network string for firewall rule
        """
        if target.lower() == "all":
            return "any"
        elif target.lower() == "internet":
            # For internet access, destination is 'any' but rule is on WAN direction
            # Actually, for outbound internet access, we allow to 'any' from the zone
            return "any"
        else:
            # Look up the zone's network
            target_zone = self.get_zone_by_name(target)
            if target_zone:
                return target_zone.ip_network
            # If zone not found, return the name as-is (might be an alias)
            return target

    def get_firewall_rule_description(self, source_zone: Zone, target: str) -> str:
        """Generate a standard description for a zone access rule.

        Args:
            source_zone: Source zone
            target: Target zone name or special value

        Returns:
            Rule description string
        """
        return f"Zone {source_zone.name} -> {target}"

    def configure_vlans(
        self,
        check_mode: bool = True,
        assign: bool = True,
    ) -> dict[str, dict]:
        """Configure VLANs for all enabled zones.

        Checks if VLANs already exist before creating them.
        Also deletes VLANs for disabled zones if they exist.
        By default, VLANs are assigned to OPNsense interfaces.

        Args:
            check_mode: If True, don't make changes (dry-run)
            assign: If True (default), also assign VLANs to interfaces

        Returns:
            Dictionary mapping zone names to results
        """
        results = {}
        vlan_zones = self.get_vlan_zones()
        disabled_zones = self.get_disabled_vlan_zones()
        manual_zones = [z for z in self.get_manual_zones() if z.needs_vlan]
        untagged_zones = [z for z in self.get_enabled_zones() if not z.needs_vlan]

        print(f"\nConfiguring VLANs...")
        print(f"  Enabled zones requiring VLANs: {len(vlan_zones)}")
        print(f"  Disabled zones with VLANs to remove: {len(disabled_zones)}")
        print(f"  Manual zones (skipped): {len(manual_zones)}")
        print(f"  Untagged zones (skipped, vlantag=0): {len(untagged_zones)}")

        with VlanManager(self.config) as manager:
            # Get existing VLANs once for efficiency
            existing_vlans = manager.list_vlans()
            # Convert tag to int for proper comparison with zone.vlan_tag (which is int)
            existing_tags = {int(v["tag"]): v for v in existing_vlans}
            existing_descriptions = {v["description"]: v for v in existing_vlans}

            # Get assigned VLANs to check if we need to unassign before deleting
            assigned_vlans = manager.get_assigned_vlans()
            # Convert vlan_tag to int for proper comparison
            assigned_by_tag = {int(v["vlan_tag"]) if isinstance(v["vlan_tag"], str) else v["vlan_tag"]: v for v in assigned_vlans if v.get("vlan_tag")}

            # First, delete VLANs for disabled zones
            for zone in disabled_zones:
                # Only use tag-based lookup for deletion to avoid matching wrong VLANs with duplicate descriptions
                existing = existing_tags.get(zone.vlan_tag)

                if existing:
                    print(f"  {zone.name}: Deleting VLAN {zone.vlan_tag} (zone disabled)")
                    if check_mode:
                        results[zone.name] = {"status": "would_delete", "vlan": zone.vlan_tag}
                    else:
                        try:
                            # Check if VLAN is assigned to an interface
                            assigned = assigned_by_tag.get(zone.vlan_tag)

                            # If not found in assigned_by_tag, search manually by description or device
                            if not assigned:
                                vlan_device = existing.get("device")
                                for v in assigned_vlans:
                                    if v.get("device") == vlan_device or v.get("description", "").lower() == zone.name.lower():
                                        assigned = v
                                        break

                            if assigned:
                                iface_id = assigned.get("identifier")
                                print(f"    Unassigning interface {iface_id} first...")
                                manager.unassign_interface(iface_id)

                            # Now delete the VLAN
                            result = manager.delete_vlan(existing["description"], check_mode=False)
                            results[zone.name] = {"status": "deleted", "result": result}
                        except Exception as e:
                            error_msg = str(e)
                            # If deletion fails because interface is still assigned, provide helpful error
                            if "assigned as an interface" in error_msg.lower():
                                print(f"    Error: VLAN is assigned to an interface but could not be unassigned automatically.")
                                print(f"    Please manually delete the interface in OPNsense first, then re-run zone-manager.")
                            else:
                                print(f"    Error: {e}")
                            results[zone.name] = {"status": "error", "error": error_msg}
                else:
                    print(f"  {zone.name}: VLAN {zone.vlan_tag} not found (nothing to delete)")
                    results[zone.name] = {"status": "not_found", "vlan": zone.vlan_tag}

            # Then, create VLANs for enabled zones
            for zone in vlan_zones:
                vlan_desc = zone.vlan_description
                # Prioritize tag-based lookup to avoid matching wrong VLANs with duplicate descriptions
                existing = existing_tags.get(zone.vlan_tag) or existing_descriptions.get(vlan_desc)

                if existing:
                    print(f"  {zone.name}: VLAN {zone.vlan_tag} already exists (skipping)")
                    results[zone.name] = {
                        "status": "exists",
                        "vlan": zone.vlan_tag,
                        "device": existing.get("device"),
                    }
                    continue

                # Use the zone's bridge to determine the physical interface
                vlan_interface = self.get_interface_for_bridge(zone.bridge)
                vlan = Vlan(
                    description=vlan_desc,
                    tag=zone.vlan_tag,
                    interface=vlan_interface,
                )

                # Calculate gateway IP and subnet for static assignment
                gateway_ip = zone.gateway_ip
                subnet_bits = zone.network.prefixlen
                print(f"  {zone.name}: Creating VLAN {zone.vlan_tag} on {vlan_interface} (bridge: {zone.bridge}, gateway: {gateway_ip}/{subnet_bits})")

                if check_mode:
                    results[zone.name] = {"status": "would_create", "vlan": zone.vlan_tag}
                else:
                    try:
                        # Pass zone.name as interface_name so the assigned interface is named after the zone
                        # Also assign the gateway IP as a static address on the interface
                        result = manager.create_vlan(
                            vlan,
                            check_mode=False,
                            assign=assign,
                            interface_name=zone.name,
                            ipv4_type="static",
                            ipv4_address=gateway_ip,
                            ipv4_subnet=subnet_bits,
                        )
                        results[zone.name] = {"status": "created", "result": result}
                    except Exception as e:
                        results[zone.name] = {"status": "error", "error": str(e)}
                        print(f"    Error: {e}")

            # Report on manual zones (not created or deleted)
            for zone in manual_zones:
                print(f"  {zone.name}: VLAN {zone.vlan_tag} skipped (manual zone)")
                results[zone.name] = {"status": "skipped_manual", "vlan": zone.vlan_tag}

            # Report on untagged zones (vlantag=0, not managed by zone-manager)
            for zone in untagged_zones:
                print(f"  {zone.name}: VLAN skipped (untagged zone, vlantag=0)")
                results[zone.name] = {"status": "skipped_untagged", "reason": "vlantag=0"}

        return results

    def configure_dhcp(self, check_mode: bool = True) -> dict[str, dict]:
        """Configure DHCP ranges for all enabled zones.

        Checks if DHCP ranges already exist before creating them.
        Also deletes DHCP ranges for disabled zones if they exist.
        Associates DHCP ranges with the zone's bridge interface.

        Args:
            check_mode: If True, don't make changes (dry-run)

        Returns:
            Dictionary mapping zone names to results
        """
        results = {}
        dhcp_zones = self.get_dhcp_zones()
        disabled_zones = self.get_disabled_dhcp_zones()
        manual_zones = [z for z in self.get_manual_zones() if z.needs_vlan]
        untagged_zones = [z for z in self.get_enabled_zones() if not z.needs_vlan]

        print(f"\nConfiguring DHCP...")
        print(f"  Enabled zones requiring DHCP: {len(dhcp_zones)}")
        print(f"  Disabled zones with DHCP to remove: {len(disabled_zones)}")
        print(f"  Manual zones (skipped): {len(manual_zones)}")
        print(f"  Untagged zones (skipped, vlantag=0): {len(untagged_zones)}")

        with DhcpManager(self.config) as manager:
            # Get existing DHCP ranges once for efficiency
            existing_ranges = manager.list_ranges()
            existing_by_desc = {r["description"]: r for r in existing_ranges}

            # First, delete DHCP ranges for disabled zones
            for zone in disabled_zones:
                dhcp_desc = zone.dhcp_description
                existing = existing_by_desc.get(dhcp_desc)

                if existing:
                    print(f"  {zone.name}: Deleting DHCP range (zone disabled)")
                    if check_mode:
                        results[zone.name] = {
                            "status": "would_delete",
                            "range": f"{zone.dhcp_start}-{zone.dhcp_end}",
                        }
                    else:
                        try:
                            result = manager.delete_range(dhcp_desc, check_mode=False)
                            results[zone.name] = {"status": "deleted", "result": result}
                        except Exception as e:
                            results[zone.name] = {"status": "error", "error": str(e)}
                            print(f"    Error: {e}")
                else:
                    print(f"  {zone.name}: DHCP range not found (nothing to delete)")
                    results[zone.name] = {"status": "not_found"}

            # Then, create DHCP ranges for enabled zones with VLANs
            for zone in dhcp_zones:
                dhcp_desc = zone.dhcp_description
                existing = existing_by_desc.get(dhcp_desc)

                if existing:
                    print(f"  {zone.name}: DHCP range already exists (skipping)")
                    results[zone.name] = {
                        "status": "exists",
                        "range": f"{existing.get('start_addr')}-{existing.get('end_addr')}",
                    }
                    continue

                # Determine the interface for DHCP
                # The bridge field from zones.json may be 'lan', 'wan', or a logical name
                # OPNsense dnsmasq accepts interface identifiers like 'lan', 'wan', 'opt1', etc.
                # If the zone has a VLAN, we need to find its assigned interface identifier
                dhcp_interface = None
                if zone.needs_vlan:
                    # For VLAN zones, try to find the assigned interface
                    # by looking for the VLAN in assigned interfaces
                    with VlanManager(self.config) as vlan_mgr:
                        assigned = vlan_mgr.get_assigned_vlans()
                        for v in assigned:
                            if v["vlan_tag"] == str(zone.vlan_tag):
                                dhcp_interface = v["identifier"]
                                break
                else:
                    # For non-VLAN zones, use the bridge directly if it's a valid identifier
                    # Valid identifiers are: lan, wan, opt1, opt2, etc. (case-insensitive)
                    bridge_lower = zone.bridge.lower()
                    if bridge_lower in ("lan", "wan") or bridge_lower.startswith("opt"):
                        dhcp_interface = zone.bridge

                # Create DHCP range
                dhcp_range = DhcpRange(
                    description=dhcp_desc,
                    start_addr=zone.dhcp_start,
                    end_addr=zone.dhcp_end,
                    interface=dhcp_interface,  # May be None (any) if not assigned
                    domain=zone.domain,
                    lease_time=86400,  # 24 hours
                )

                interface_info = dhcp_interface or "any"
                print(f"  {zone.name}: {zone.dhcp_start} - {zone.dhcp_end} ({zone.domain}) on {interface_info}")

                if check_mode:
                    results[zone.name] = {
                        "status": "would_create",
                        "range": f"{zone.dhcp_start}-{zone.dhcp_end}",
                        "domain": zone.domain,
                        "interface": interface_info,
                    }
                else:
                    try:
                        result = manager.create_range(dhcp_range, check_mode=False)
                        results[zone.name] = {"status": "created", "result": result}
                    except Exception as e:
                        error_str = str(e)
                        # If the interface isn't found by dnsmasq (e.g., newly created VLAN),
                        # retry without interface binding (use "any")
                        if "was not found" in error_str and dhcp_interface:
                            print(f"    Interface '{dhcp_interface}' not recognized by dnsmasq, retrying without interface binding...")
                            dhcp_range_any = DhcpRange(
                                description=dhcp_desc,
                                start_addr=zone.dhcp_start,
                                end_addr=zone.dhcp_end,
                                interface=None,  # Use "any"
                                domain=zone.domain,
                                lease_time=86400,
                            )
                            try:
                                result = manager.create_range(dhcp_range_any, check_mode=False)
                                results[zone.name] = {
                                    "status": "created",
                                    "result": result,
                                    "note": f"Interface '{dhcp_interface}' not found, created without interface binding",
                                }
                                print(f"    Created DHCP range on 'any' interface")
                            except Exception as e2:
                                results[zone.name] = {"status": "error", "error": str(e2)}
                                print(f"    Error: {e2}")
                        else:
                            results[zone.name] = {"status": "error", "error": error_str}
                            print(f"    Error: {e}")

            # Report on manual zones (not created or deleted)
            for zone in manual_zones:
                print(f"  {zone.name}: DHCP skipped (manual zone)")
                results[zone.name] = {
                    "status": "skipped_manual",
                    "range": f"{zone.dhcp_start}-{zone.dhcp_end}",
                }

            # Report on untagged zones (vlantag=0, not managed by zone-manager)
            for zone in untagged_zones:
                print(f"  {zone.name}: DHCP skipped (untagged zone, vlantag=0)")
                results[zone.name] = {
                    "status": "skipped_untagged",
                    "reason": "vlantag=0",
                }

        return results

    def _create_or_skip_rule(
        self,
        manager: FirewallManager,
        existing_by_desc: dict[str, FirewallRuleInfo],
        description: str,
        interface: str,
        source_net: str,
        destination_net: str,
        action: RuleAction,
        sequence: int,
        check_mode: bool,
        results_list: list[dict],
    ) -> None:
        """Create a firewall rule or skip if it already exists.

        Args:
            manager: Connected FirewallManager instance
            existing_by_desc: Dict of existing rules keyed by description
            description: Rule description (used for matching)
            interface: OPNsense interface identifier
            source_net: Source network CIDR
            destination_net: Destination network CIDR or 'any'
            action: Rule action (PASS or BLOCK)
            sequence: Rule sequence number for ordering
            check_mode: If True, don't make changes
            results_list: List to append result dicts to
        """
        action_str = "pass" if action == RuleAction.PASS else "block"

        existing = existing_by_desc.get(description)
        if existing:
            print(f"    {action_str}: {description} (exists, skipping)")
            results_list.append({
                "description": description,
                "status": "exists",
                "action": action_str,
                "destination": destination_net,
            })
            return

        print(f"    {action_str}: {description}")

        if check_mode:
            results_list.append({
                "description": description,
                "status": "would_create",
                "action": action_str,
                "destination": destination_net,
            })
        else:
            try:
                rule = FirewallRule(
                    description=description,
                    action=action,
                    interface=interface,
                    source_net=source_net,
                    destination_net=destination_net,
                    log=True,
                    sequence=sequence,
                )
                result = manager.create_rule(rule, apply=False)
                results_list.append({
                    "description": description,
                    "status": "created",
                    "action": action_str,
                    "destination": destination_net,
                    "result": result,
                })
            except Exception as e:
                results_list.append({
                    "description": description,
                    "status": "error",
                    "error": str(e),
                })
                print(f"      Error: {e}")

    def configure_firewall_rules(self, check_mode: bool = True) -> dict[str, dict]:
        """Configure firewall rules based on zone access-to definitions.

        Implements zone isolation with the following semantics:
        - 'all': Single pass rule to any destination (full access)
        - 'internet': Allows outbound internet but blocks other internal zones.
          Creates: pass to gateway, block RFC1918, pass to any.
        - <zone_name>: Allows traffic to that specific zone's network only.

        When 'internet' is combined with specific zones (e.g. ["internet", "iot"]),
        pass rules for the named zones are inserted before the RFC1918 block so
        that traffic to those zones is allowed while all other internal traffic
        is blocked.

        Rule ordering per zone (using sequence numbers):
        1. Pass to own gateway (DNS/NTP access)
        2. Pass to each explicitly allowed zone network
        3. Block RFC1918 private ranges (zone isolation)
        4. Pass to any (internet access)

        Args:
            check_mode: If True, don't make changes (dry-run)

        Returns:
            Dictionary mapping zone names to results
        """
        results = {}
        firewall_zones = self.get_firewall_zones()
        manual_zones = self.get_manual_zones()
        isolated_zones = [
            z for z in self.get_enabled_zones()
            if not z.access_to and not z.is_manual
        ]
        disabled_zones = self.get_disabled_zones()

        print(f"\nConfiguring Firewall Rules...")
        print(f"  Zones with access-to rules: {len(firewall_zones)}")
        print(f"  Isolated zones (empty access-to): {len(isolated_zones)}")
        print(f"  Disabled zones (rules to clean up): {len(disabled_zones)}")
        print(f"  Manual zones (skipped): {len(manual_zones)}")

        with FirewallManager(self.config) as manager:
            # Get existing rules for comparison
            existing_rules = manager.list_rules()
            existing_by_desc = {r.description: r for r in existing_rules}

            # Delete firewall rules for disabled zones
            for zone in disabled_zones:
                zone_prefix = f"Zone {zone.name} "
                matching = [r for r in existing_rules if r.description.startswith(zone_prefix)]
                if matching:
                    print(f"  {zone.name}: Deleting {len(matching)} rules (zone disabled)")
                    if not check_mode:
                        for rule_info in matching:
                            try:
                                manager.delete_rule(rule_info.description, apply=False)
                            except Exception as e:
                                print(f"    Error deleting '{rule_info.description}': {e}")
                    results[zone.name] = {
                        "status": "would_delete" if check_mode else "deleted",
                        "rules_deleted": len(matching),
                    }

            # Create rules for enabled zones
            for zone in firewall_zones:
                zone_results = []
                zone_interface = self.get_zone_interface(zone)

                if not zone_interface:
                    print(f"  {zone.name}: Cannot find interface (skipping)")
                    results[zone.name] = {
                        "status": "error",
                        "error": "Interface not found",
                        "rules": [],
                    }
                    continue

                print(f"  {zone.name} (interface: {zone_interface}):")

                # Categorise targets
                targets_lower = [t.lower() for t in zone.access_to]
                has_all = "all" in targets_lower
                has_internet = "internet" in targets_lower
                specific_targets = [t for t in zone.access_to if t.lower() not in ("all", "internet")]

                # Base sequence derived from VLAN tag (gives room for ~10 rules per zone)
                base_seq = zone.vlan_tag * 10 if zone.vlan_tag > 0 else 100
                seq = base_seq

                if has_all:
                    # Full access — single pass rule to any
                    self._create_or_skip_rule(
                        manager, existing_by_desc,
                        f"Zone {zone.name} -> all",
                        zone_interface, zone.ip_network, "any",
                        RuleAction.PASS, seq, check_mode, zone_results,
                    )
                else:
                    # Step 1: Allow access to own gateway (DNS, NTP)
                    self._create_or_skip_rule(
                        manager, existing_by_desc,
                        f"Zone {zone.name} -> gateway",
                        zone_interface, zone.ip_network, f"{zone.gateway_ip}/32",
                        RuleAction.PASS, seq, check_mode, zone_results,
                    )
                    seq += 1

                    # Step 2: Allow access to each explicitly named zone
                    for target in specific_targets:
                        target_zone = self.get_zone_by_name(target)
                        if target_zone:
                            dest = target_zone.ip_network
                        else:
                            print(f"    Warning: target zone '{target}' not found in zones.json, using name as alias")
                            dest = target
                        self._create_or_skip_rule(
                            manager, existing_by_desc,
                            f"Zone {zone.name} -> {target}",
                            zone_interface, zone.ip_network, dest,
                            RuleAction.PASS, seq, check_mode, zone_results,
                        )
                        seq += 1

                    if has_internet:
                        # Step 3: Block RFC1918 to prevent reaching unlisted internal zones
                        for network, label in self.RFC1918_NETWORKS:
                            self._create_or_skip_rule(
                                manager, existing_by_desc,
                                f"Zone {zone.name} block {label}",
                                zone_interface, zone.ip_network, network,
                                RuleAction.BLOCK, seq, check_mode, zone_results,
                            )
                            seq += 1

                        # Step 4: Allow internet (pass to any — only non-RFC1918 reaches here)
                        self._create_or_skip_rule(
                            manager, existing_by_desc,
                            f"Zone {zone.name} -> internet",
                            zone_interface, zone.ip_network, "any",
                            RuleAction.PASS, seq, check_mode, zone_results,
                        )

                results[zone.name] = {
                    "status": "processed",
                    "interface": zone_interface,
                    "rules": zone_results,
                }

            # Apply all changes at once if not in check mode
            if not check_mode:
                print("\n  Applying firewall changes...")
                try:
                    manager.apply_changes()
                    print("  Changes applied successfully")
                except Exception as e:
                    print(f"  Error applying changes: {e}")

            # Report on isolated zones (enabled but empty access-to)
            for zone in isolated_zones:
                print(f"  {zone.name}: No rules (fully isolated, default block)")
                results[zone.name] = {"status": "isolated", "access_to": []}

            # Report on manual zones
            for zone in manual_zones:
                if zone.access_to:
                    print(f"  {zone.name}: Firewall rules skipped (manual zone)")
                    results[zone.name] = {
                        "status": "skipped_manual",
                        "access_to": zone.access_to,
                    }

        return results

    def update_dnsmasq_interfaces(self, check_mode: bool = True) -> dict:
        """Update dnsmasq to listen on all enabled VLAN interfaces.

        Builds a list of all interfaces that need DHCP (LAN + VLAN zones)
        and updates the dnsmasq general configuration.

        Args:
            check_mode: If True, don't make changes (dry-run)

        Returns:
            Result dictionary
        """
        # Start with the base LAN interface
        interfaces = ["lan"]

        # Add all enabled VLAN zone interfaces
        for zone in self.get_vlan_zones():
            iface = self.get_zone_interface(zone)
            if iface and iface not in interfaces:
                interfaces.append(iface)

        print(f"  Dnsmasq interfaces: {', '.join(interfaces)}")

        if check_mode:
            return {"status": "would_update", "interfaces": interfaces}

        try:
            with DhcpManager(self.config) as manager:
                result = manager.set_dnsmasq_interfaces(
                    interfaces=interfaces,
                    check_mode=check_mode,
                )
                print(f"  Updated dnsmasq to listen on {len(interfaces)} interfaces")
                return {"status": "updated", "interfaces": interfaces, "result": result}
        except Exception as e:
            print(f"  Error updating dnsmasq interfaces: {e}")
            return {"status": "error", "error": str(e)}

    def configure_all(
        self,
        check_mode: bool = True,
        assign_vlans: bool = True,
        firewall_rules: bool = True,
    ) -> dict:
        """Configure VLANs, DHCP, and firewall rules for all zones.

        VLANs are always configured before DHCP ranges to ensure
        the network infrastructure is in place.
        Firewall rules are configured last, after all zones are created.
        By default, VLANs are assigned to OPNsense interfaces and
        firewall rules are created based on the access-to field.

        Args:
            check_mode: If True, don't make changes (dry-run)
            assign_vlans: If True (default), also assign VLANs to interfaces
            firewall_rules: If True (default), also configure firewall rules based on access-to

        Returns:
            Dictionary with 'vlans', 'dhcp', and optionally 'firewall' results
        """
        # Configure VLANs first, then DHCP, then firewall rules
        print("\n" + "=" * 60)
        print("Step 1: Configuring VLANs")
        print("=" * 60)
        vlan_results = self.configure_vlans(check_mode=check_mode, assign=assign_vlans)

        print("\n" + "=" * 60)
        print("Step 2: Configuring DHCP ranges")
        print("=" * 60)
        dhcp_results = self.configure_dhcp(check_mode=check_mode)

        # Update dnsmasq to listen on all VLAN interfaces
        print("\n" + "=" * 60)
        print("Step 2b: Updating dnsmasq interface bindings")
        print("=" * 60)
        dnsmasq_result = self.update_dnsmasq_interfaces(check_mode=check_mode)

        result = {
            "vlans": vlan_results,
            "dhcp": dhcp_results,
            "dnsmasq_interfaces": dnsmasq_result,
        }

        if firewall_rules:
            print("\n" + "=" * 60)
            print("Step 3: Configuring Firewall Rules")
            print("=" * 60)
            firewall_results = self.configure_firewall_rules(check_mode=check_mode)
            result["firewall"] = firewall_results

        return result

    def list_current_config(self) -> dict:
        """List current VLAN and DHCP configuration from OPNsense.

        Returns:
            Dictionary with 'vlans' and 'dhcp_ranges' lists
        """
        vlans = []
        dhcp_ranges = []

        with VlanManager(self.config) as manager:
            vlans = manager.list_vlans()

        with DhcpManager(self.config) as manager:
            dhcp_ranges = manager.list_ranges()

        return {
            "vlans": vlans,
            "dhcp_ranges": dhcp_ranges,
        }

    def print_current_config(self):
        """Print the current VLAN and DHCP configuration from OPNsense."""
        config = self.list_current_config()

        print("\nCurrent OPNsense Configuration:")
        print("=" * 80)

        print("\nVLANs:")
        print("-" * 80)
        if not config["vlans"]:
            print("  No VLANs configured")
        else:
            print(f"  {'Tag':<6} {'Device':<15} {'Interface':<12} {'Description'}")
            print("  " + "-" * 70)
            for vlan in config["vlans"]:
                print(f"  {vlan['tag']:<6} {vlan['device'] or '-':<15} {vlan['interface']:<12} {vlan['description']}")

        print("\nDHCP Ranges:")
        print("-" * 80)
        if not config["dhcp_ranges"]:
            print("  No DHCP ranges configured")
        else:
            print(f"  {'Description':<20} {'Start':<16} {'End':<16} {'Interface':<10} {'Domain'}")
            print("  " + "-" * 75)
            for r in config["dhcp_ranges"]:
                print(
                    f"  {r['description'] or '-':<20} {r['start_addr'] or '-':<16} "
                    f"{r['end_addr'] or '-':<16} {r['interface'] or 'any':<10} {r['domain'] or '-'}"
                )

        print("=" * 80)

    def print_zone_summary(self):
        """Print a summary of all zones."""
        print("\nZone Summary:")
        print("-" * 80)
        print(f"{'Name':<15} {'Type':<12} {'State':<10} {'VLAN':<6} {'IP Network':<18} {'DHCP Range'}")
        print("-" * 80)

        for zone in self.zones:
            if zone.is_enabled:
                status = "enabled"
            elif zone.is_manual:
                status = "manual"
            else:
                status = "disabled"
            vlan = str(zone.vlan_tag) if zone.vlan_tag > 0 else "-"
            dhcp_range = f"{zone.dhcp_start}-{zone.dhcp_end}" if zone.is_enabled else "-"

            print(f"{zone.name:<15} {zone.zone_type:<12} {status:<10} {vlan:<6} {zone.ip_network:<18} {dhcp_range}")

        print("-" * 80)
        enabled = len(self.get_enabled_zones())
        disabled = len(self.get_disabled_zones())
        manual = len(self.get_manual_zones())
        vlan_zones = len(self.get_vlan_zones())
        print(f"Total: {len(self.zones)} zones, {enabled} enabled, {disabled} disabled, {manual} manual, {vlan_zones} with VLANs")


def main():
    """Main entry point for zone-manager CLI."""
    parser = argparse.ArgumentParser(
        description="TAPPaaS Zone Manager - Configure VLANs and DHCP from zones.json",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    parser.add_argument(
        "--zones-file",
        default=None,
        help="Path to zones.json file (default: auto-detect from TAPPaaS structure)",
    )
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Actually execute changes (default is check/dry-run mode)",
    )
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
        help="Path to credential file",
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
        "--interface",
        default="vtnet1",
        help="Physical interface for VLANs (default: vtnet1)",
    )
    parser.add_argument(
        "--no-assign",
        action="store_true",
        help="Do not assign VLANs to interfaces (by default VLANs are assigned)",
    )
    parser.add_argument(
        "--vlans-only",
        action="store_true",
        help="Only configure VLANs, skip DHCP and firewall rules",
    )
    parser.add_argument(
        "--dhcp-only",
        action="store_true",
        help="Only configure DHCP, skip VLANs and firewall rules",
    )
    parser.add_argument(
        "--no-firewall-rules",
        action="store_true",
        help="Do not configure firewall rules (by default firewall rules are configured based on access-to field in zones.json)",
    )
    parser.add_argument(
        "--firewall-rules-only",
        action="store_true",
        help="Only configure firewall rules, skip VLANs and DHCP",
    )
    parser.add_argument(
        "--summary",
        action="store_true",
        help="Only show zone summary, don't configure anything",
    )
    parser.add_argument(
        "--list-config",
        action="store_true",
        help="List current OPNsense VLAN and DHCP configuration",
    )

    args = parser.parse_args()
    check_mode = not args.execute

    # Find zones.json file
    zones_file = args.zones_file
    if not zones_file:
        # Try to find it relative to common locations
        possible_paths = [
            Path("zones.json"),
            Path("src/foundation/zones.json"),
            Path("/home/tappaas/TAPPaaS/src/foundation/zones.json"),
        ]
        for path in possible_paths:
            if path.exists():
                zones_file = str(path)
                break

    if not zones_file:
        print("Error: Could not find zones.json. Use --zones-file to specify the path.")
        sys.exit(1)

    if check_mode and not args.summary and not args.list_config:
        print("=" * 60)
        print("RUNNING IN CHECK MODE (dry-run) - no changes will be made")
        print("Use --execute to actually make changes")
        print("=" * 60)

    # Build configuration
    try:
        firewall = os.environ.get("OPNSENSE_HOST", args.firewall)
        if args.firewall != "firewall.mgmt.internal":
            firewall = args.firewall

        config_kwargs = {
            "firewall": firewall,
            "ssl_verify": not args.no_ssl_verify,
            "debug": args.debug,
        }
        if args.port is not None:
            config_kwargs["port"] = args.port
        if args.credential_file:
            config_kwargs["credential_file"] = args.credential_file

        config = Config(**config_kwargs)
    except ValueError as e:
        print(f"Configuration error: {e}")
        sys.exit(1)

    # Create manager and load zones
    manager = ZoneManager(
        config=config,
        zones_file=zones_file,
        interface=args.interface,
    )

    try:
        manager.load_zones()
    except FileNotFoundError as e:
        print(f"Error: {e}")
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Error parsing zones.json: {e}")
        sys.exit(1)

    # Show zone summary
    manager.print_zone_summary()

    # List current config if requested
    if args.list_config:
        manager.print_current_config()
        sys.exit(0)

    if args.summary:
        sys.exit(0)

    # Configure based on options
    # By default, VLANs are assigned to interfaces (use --no-assign to disable)
    # By default, firewall rules are configured (use --no-firewall-rules to disable)
    assign_vlans = not args.no_assign
    firewall_rules = not args.no_firewall_rules
    if args.vlans_only:
        results = {"vlans": manager.configure_vlans(check_mode=check_mode, assign=assign_vlans)}
    elif args.dhcp_only:
        results = {"dhcp": manager.configure_dhcp(check_mode=check_mode)}
    elif args.firewall_rules_only:
        results = {"firewall": manager.configure_firewall_rules(check_mode=check_mode)}
    else:
        results = manager.configure_all(
            check_mode=check_mode,
            assign_vlans=assign_vlans,
            firewall_rules=firewall_rules,
        )

    # Print results summary
    print("\n" + "=" * 60)
    print("Results Summary")
    print("=" * 60)
    if "vlans" in results:
        print(f"\nVLANs: {len(results['vlans'])} zones processed")
        for zone_name, result in results["vlans"].items():
            status = result.get("status", "unknown")
            vlan_tag = result.get("vlan", "")
            print(f"  {zone_name}: {status}" + (f" (VLAN {vlan_tag})" if vlan_tag else ""))

    if "dhcp" in results:
        print(f"\nDHCP: {len(results['dhcp'])} zones processed")
        for zone_name, result in results["dhcp"].items():
            status = result.get("status", "unknown")
            range_info = result.get("range", "")
            print(f"  {zone_name}: {status}" + (f" ({range_info})" if range_info else ""))

    if "firewall" in results:
        print(f"\nFirewall Rules: {len(results['firewall'])} zones processed")
        for zone_name, result in results["firewall"].items():
            status = result.get("status", "unknown")
            rules = result.get("rules", [])
            if rules:
                created = sum(1 for r in rules if r.get("status") in ("created", "would_create"))
                exists = sum(1 for r in rules if r.get("status") == "exists")
                errors = sum(1 for r in rules if r.get("status") == "error")
                parts = []
                if created:
                    parts.append(f"{created} new")
                if exists:
                    parts.append(f"{exists} existing")
                if errors:
                    parts.append(f"{errors} errors")
                print(f"  {zone_name}: {len(rules)} rules ({', '.join(parts)})")
            elif status in ("deleted", "would_delete"):
                count = result.get("rules_deleted", 0)
                print(f"  {zone_name}: {status} ({count} rules removed)")
            else:
                print(f"  {zone_name}: {status}")

    # Show current config after changes (if not in check mode)
    if not check_mode:
        print("\n" + "=" * 60)
        print("Verifying configuration...")
        print("=" * 60)
        manager.print_current_config()


if __name__ == "__main__":
    main()
