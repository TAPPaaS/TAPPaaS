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
import hashlib
import ipaddress
import json
import os
import socket
import sys
from dataclasses import dataclass
from pathlib import Path

from .config import Config


def _check_unbound_dns(label: str = "") -> bool:
    """Check if Unbound DNS at 10.0.0.1 is responding.

    Debug instrumentation to track when Unbound breaks during zone-manager
    operations. Returns True if DNS is working, False otherwise.
    """
    try:
        # Create a UDP socket for DNS query
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(2.0)

        # Simple DNS query for "firewall.mgmt.internal" (A record)
        # DNS header: ID=0x1234, flags=0x0100 (standard query), 1 question
        query = (
            b'\x12\x34'  # Transaction ID
            b'\x01\x00'  # Flags: standard query
            b'\x00\x01'  # Questions: 1
            b'\x00\x00'  # Answer RRs: 0
            b'\x00\x00'  # Authority RRs: 0
            b'\x00\x00'  # Additional RRs: 0
            # Query: firewall.mgmt.internal
            b'\x08firewall\x04mgmt\x08internal\x00'
            b'\x00\x01'  # Type: A
            b'\x00\x01'  # Class: IN
        )

        sock.sendto(query, ("10.0.0.1", 53))
        response, _ = sock.recvfrom(512)
        sock.close()

        # Check if we got a valid response (at least header + some data)
        if len(response) >= 12:
            prefix = f"[UNBOUND-CHECK {label}] " if label else "[UNBOUND-CHECK] "
            info(f"{prefix}DNS OK - Unbound responding on 10.0.0.1:53")
            return True
        return False
    except socket.timeout:
        prefix = f"[UNBOUND-CHECK {label}] " if label else "[UNBOUND-CHECK] "
        warn(f"{prefix}DNS FAILED - Unbound NOT responding on 10.0.0.1:53 (timeout)")
        return False
    except Exception as e:
        prefix = f"[UNBOUND-CHECK {label}] " if label else "[UNBOUND-CHECK] "
        warn(f"{prefix}DNS FAILED - Unbound check error: {e}")
        return False


def _check_egress(host: str = "1.1.1.1", port: int = 443,
                  timeout: float = 3.0, label: str = "") -> bool:
    """Check control-plane egress: can we open a TCP connection to host:port?

    Detects when a firewall mutation has broken outbound connectivity (e.g. a
    bad ruleset), independent of DNS — the target is an IP literal on purpose.
    Returns True if reachable, False otherwise. (#307)
    """
    prefix = f"[EGRESS-CHECK {label}] " if label else "[EGRESS-CHECK] "
    try:
        with socket.create_connection((host, port), timeout=timeout):
            info(f"{prefix}egress OK - TCP {host}:{port} reachable")
            return True
    except Exception as e:
        warn(f"{prefix}egress FAILED - cannot reach {host}:{port}: {e}")
        return False


def preflight_checks(skip_egress: bool = False) -> bool:
    """Probe control-plane health BEFORE any mutating zone operation (#307).

    Verifies Unbound DNS (10.0.0.1:53) and, unless skipped, control-plane egress
    (1.1.1.1:443) — both via IP literals so the probe never depends on DNS.
    Returns True if healthy. The caller should abort --execute on False: mutating
    an already-degraded firewall risks leaving DNS unrecoverable, and recovery
    SSH needs name resolution that would no longer work (UNBOUND-DNSBL-PYTHON).
    """
    dns_ok = _check_unbound_dns("PRE-FLIGHT")
    egress_ok = True if skip_egress else _check_egress(label="PRE-FLIGHT")
    if not dns_ok:
        error("Pre-flight: Unbound DNS (10.0.0.1:53) is DOWN — refusing to mutate "
              "(a zone change could make DNS unrecoverable). Restore DNS first, or "
              "override with --skip-preflight.")
    if not egress_ok:
        error("Pre-flight: control-plane egress (1.1.1.1:443) FAILED — refusing to "
              "mutate. Override with --skip-egress-check (air-gapped) or --skip-preflight.")
    return dns_ok and egress_ok


def postflight_checks(skip_egress: bool = False) -> bool:
    """Probe control-plane health AFTER zone mutations (#307).

    Same IP-literal probes as preflight. Returns True if still healthy; the caller
    exits non-zero on False so CI/CD stops before a degraded firewall is shipped.
    """
    dns_ok = _check_unbound_dns("POST-FLIGHT")
    egress_ok = True if skip_egress else _check_egress(label="POST-FLIGHT")
    if not dns_ok:
        error("Post-flight: Unbound DNS (10.0.0.1:53) is DOWN after zone changes — "
              "DNS may be unrecoverable. Recover via the firewall's mgmt IP "
              "(10.0.0.1), NOT via name resolution.")
    if not egress_ok:
        error("Post-flight: control-plane egress (1.1.1.1:443) FAILED after zone changes.")
    return dns_ok and egress_ok


from .dhcp_manager import DhcpManager, DhcpRange
from .firewall_manager import FirewallManager, FirewallRule, FirewallRuleInfo, Protocol, RuleAction
from .log import debug, error, info, warn
from .vlan_manager import Vlan, VlanManager

# Modules whose JSON files exist in the config directory but are NOT consumer
# modules — never apply per-module firewall validation to these.
_NON_MODULE_STEMS: frozenset[str] = frozenset(
    {"configuration", "firewall", "zones", "aliases",
     "sequence-map", "module-fields"}
)


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


# ─────────────────────────────────────────────────────────────────────────────
# pinhole-allowed-from validator (issue #163)
#
# zones.json declares, per zone, which OTHER zones may open per-module pinholes
# INTO it via the "pinhole-allowed-from" list. The rules_manager enforces this
# at compile time when a module is installed; this validator does the same
# check statically — without touching OPNsense — across every module.json on
# disk, so an operator can run `zone-manager --summary` and immediately see
# every policy mismatch in the deployed module set.
# ─────────────────────────────────────────────────────────────────────────────


@dataclass
class ValidationMessage:
    """A single warning or schema error emitted by the validator."""

    severity: str        # "error" | "warning"
    module: str          # module's vmname (or filename stem if vmname missing)
    file_path: str
    line: int            # 1-based; 1 when no precise location is available
    text: str


def discover_module_files(modules_dir: Path) -> list[Path]:
    """Return module.json file paths from `modules_dir`, sorted by name.

    Skips well-known non-module JSON files (configuration.json, zones.json,
    firewall.json, etc.) and `.orig` backup files.
    """
    if not modules_dir.is_dir():
        return []
    return sorted(
        p for p in modules_dir.glob("*.json")
        if p.stem not in _NON_MODULE_STEMS and not p.name.endswith(".orig")
    )


def _find_field_line(text: str, search: str) -> int:
    """Best-effort 1-based line lookup for a substring; returns 1 if not found."""
    for i, line in enumerate(text.splitlines(), start=1):
        if search in line:
            return i
    return 1


def _find_ingress_line(text: str, idx: int, field_value: str | None = None) -> int:
    """Locate the line of the idx-th ingress entry in raw module.json text.

    Walks lines after `"ingress"` and counts opening `{` braces. When
    `field_value` is supplied we additionally try to find a line containing
    `"<field_value>"` within the matched entry; falls back to the entry's
    opening line. Best-effort — meant to give an operator a clickable line
    reference, not perfect AST-level positions.
    """
    lines = text.splitlines()
    in_ingress = False
    bracket_depth = 0
    entry_open_line: int | None = None
    seen_entry = -1
    for i, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not in_ingress:
            if '"ingress"' in line:
                in_ingress = True
            continue
        if not entry_open_line and "{" in stripped and bracket_depth == 0:
            seen_entry += 1
            entry_open_line = i
            bracket_depth = 1
            # Honour fields on the same line (e.g. inline brace)
            if "}" in stripped:
                if field_value and f'"{field_value}"' in line and seen_entry == idx:
                    return i
                bracket_depth = 0
                if seen_entry == idx:
                    return entry_open_line
                entry_open_line = None
            continue
        if entry_open_line:
            bracket_depth += stripped.count("{") - stripped.count("}")
            if seen_entry == idx and field_value and f'"{field_value}"' in line:
                return i
            if bracket_depth <= 0:
                if seen_entry == idx:
                    return entry_open_line
                entry_open_line = None
                bracket_depth = 0
        # End of ingress array — stop walking
        if in_ingress and entry_open_line is None and stripped.startswith("]"):
            break
    return entry_open_line or 1


def _load_pinhole_ports(provider_location: str, service: str) -> list[dict] | None:
    """Mirror of rules_manager.load_pinhole_ports (kept local to avoid a circular import).

    Returns the ports list, or None when the provider has no pinhole.json for
    that service (which is the normal case for most services).
    """
    if not provider_location:
        return None
    path = Path(provider_location) / "services" / service / "pinhole.json"
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text())
    except Exception:
        return None
    ports = data.get("ports", []) or []
    return ports if isinstance(ports, list) else None


def validate_pinhole_allowed_from(
    zones: dict[str, "Zone"],
    modules_dir: Path,
) -> tuple[list[ValidationMessage], list[ValidationMessage]]:
    """Cross-check every module's ingress entries against zone policy.

    Returns ``(warnings, errors)``.

    Warnings cover policy mismatches (an ingress entry — or a dependsOn-driven
    auto-pinhole, see issue #173 — would open a pinhole into a destination
    zone whose pinhole-allowed-from does NOT list the source zone). Errors
    cover schema problems that prevent meaningful evaluation (malformed JSON,
    `ingress` not an array, ingress entry without a `from` field, `from`
    references a non-existent peer or zone, …).

    By contract: errors → CLI exit code 2; warnings alone → exit 0.
    """
    warnings: list[ValidationMessage] = []
    errors: list[ValidationMessage] = []

    for mod_file in discover_module_files(modules_dir):
        try:
            raw = mod_file.read_text()
            data = json.loads(raw)
        except json.JSONDecodeError as e:
            errors.append(ValidationMessage(
                severity="error",
                module=mod_file.stem,
                file_path=str(mod_file),
                line=getattr(e, "lineno", 1) or 1,
                text=f"invalid JSON: {e.msg}",
            ))
            continue
        except OSError as e:
            errors.append(ValidationMessage(
                severity="error",
                module=mod_file.stem,
                file_path=str(mod_file),
                line=1,
                text=f"cannot read: {e}",
            ))
            continue
        if not isinstance(data, dict):
            errors.append(ValidationMessage(
                severity="error",
                module=mod_file.stem,
                file_path=str(mod_file),
                line=1,
                text="top-level JSON value is not an object",
            ))
            continue

        vmname = data.get("vmname", mod_file.stem)
        dest_zone_name = data.get("zone0", "")

        # Manual ingress entries -------------------------------------------------
        ingress_entries = data.get("ingress", []) or []
        if not isinstance(ingress_entries, list):
            errors.append(ValidationMessage(
                severity="error",
                module=vmname,
                file_path=str(mod_file),
                line=_find_field_line(raw, '"ingress"'),
                text="'ingress' is not an array",
            ))
            ingress_entries = []

        for idx, entry in enumerate(ingress_entries):
            if not isinstance(entry, dict):
                errors.append(ValidationMessage(
                    severity="error",
                    module=vmname,
                    file_path=str(mod_file),
                    line=_find_ingress_line(raw, idx),
                    text=f"ingress[{idx}] is not an object",
                ))
                continue
            from_value = entry.get("from")
            if not isinstance(from_value, str) or not from_value:
                errors.append(ValidationMessage(
                    severity="error",
                    module=vmname,
                    file_path=str(mod_file),
                    line=_find_ingress_line(raw, idx),
                    text=f"ingress[{idx}] missing required 'from' field",
                ))
                continue

            # 'internet' and alias references are out of scope for the pinhole
            # policy gate.
            if from_value == "internet" or from_value.startswith("alias:"):
                continue

            # Resolve from_value to a source zone. It is either a zone name
            # directly, or a peer module's vmname (in which case we look up
            # that peer's zone0).
            if from_value in zones:
                src_zone_name = from_value
            else:
                peer_file = modules_dir / f"{from_value}.json"
                if not peer_file.is_file():
                    errors.append(ValidationMessage(
                        severity="error",
                        module=vmname,
                        file_path=str(mod_file),
                        line=_find_ingress_line(raw, idx, from_value),
                        text=(f"ingress[{idx}].from = '{from_value}' is not a "
                              f"known zone, 'internet', alias:..., or peer "
                              f"module on disk"),
                    ))
                    continue
                try:
                    peer_data = json.loads(peer_file.read_text())
                except Exception:
                    continue
                src_zone_name = peer_data.get("zone0", "") if isinstance(peer_data, dict) else ""

            if not src_zone_name or not dest_zone_name:
                continue
            if src_zone_name == dest_zone_name:
                continue  # intra-zone traffic doesn't need a pinhole
            dest_zone = zones.get(dest_zone_name)
            if dest_zone is None:
                continue  # surfaced by other checks; not our job
            if src_zone_name in dest_zone.pinhole_allowed_from:
                continue  # policy permits — happy path

            warnings.append(ValidationMessage(
                severity="warning",
                module=vmname,
                file_path=str(mod_file),
                line=_find_ingress_line(raw, idx, from_value),
                text=(f"ingress[{idx}].from = '{from_value}' "
                      f"(source zone '{src_zone_name}') would pinhole into "
                      f"'{dest_zone_name}', but "
                      f"'{dest_zone_name}'.pinhole-allowed-from = "
                      f"{dest_zone.pinhole_allowed_from} — policy denies. "
                      f"Add '{src_zone_name}' to "
                      f"{dest_zone_name}.pinhole-allowed-from in zones.json, "
                      f"or remove this entry."),
            ))

        # Auto-pinholes from dependsOn (issue #173) ----------------------------
        # If a module depends on `<provider>:<service>` and the provider ships
        # a services/<service>/pinhole.json, the rules_manager will (or won't)
        # emit a synthesised pinhole — same policy gate. Report violations
        # here so the operator catches them before install time.
        deps = data.get("dependsOn", []) or []
        if not isinstance(deps, list):
            continue
        for dep in deps:
            if not isinstance(dep, str) or ":" not in dep:
                continue
            provider_name, _, service = dep.partition(":")
            provider_name = provider_name.strip()
            service = service.strip()
            if not provider_name or not service:
                continue
            peer_file = modules_dir / f"{provider_name}.json"
            if not peer_file.is_file():
                continue  # provider not installed yet; install-time will catch
            try:
                peer_data = json.loads(peer_file.read_text())
            except Exception:
                continue
            if not isinstance(peer_data, dict):
                continue
            provider_location = peer_data.get("location", "")
            ports = _load_pinhole_ports(provider_location, service)
            if not ports:
                continue
            provider_zone_name = peer_data.get("zone0", "")
            if not provider_zone_name or not dest_zone_name:
                continue
            if provider_zone_name == dest_zone_name:
                continue  # intra-zone — no pinhole
            provider_zone = zones.get(provider_zone_name)
            if provider_zone is None:
                continue
            if dest_zone_name in provider_zone.access_to:
                continue  # zone-level access-to already permits
            if dest_zone_name in provider_zone.pinhole_allowed_from:
                continue  # policy permits the auto-pinhole

            warnings.append(ValidationMessage(
                severity="warning",
                module=vmname,
                file_path=str(mod_file),
                line=_find_field_line(raw, f'"{dep}"'),
                text=(f"dependsOn '{dep}' would create an auto-pinhole from "
                      f"'{dest_zone_name}' into '{provider_zone_name}', but "
                      f"'{provider_zone_name}'.pinhole-allowed-from = "
                      f"{provider_zone.pinhole_allowed_from} — policy denies. "
                      f"Auto-pinhole will be silently skipped at install time."),
            ))

    return warnings, errors


def print_validation_report(
    warnings: list[ValidationMessage],
    errors: list[ValidationMessage],
) -> None:
    """Render the validator's findings via the standard log functions."""
    info("Pinhole policy validation:")
    info("-" * 80)
    if not warnings and not errors:
        info("  All ingress and dependsOn entries comply with destination "
             "zones' pinhole-allowed-from.")
        info("-" * 80)
        return
    for m in errors:
        error(f"  {m.file_path}:{m.line}: [error] {m.module}: {m.text}")
    for m in warnings:
        warn(f"  {m.file_path}:{m.line}: [warn]  {m.module}: {m.text}")
    info("-" * 80)
    info(f"  Validation summary: {len(errors)} error(s), {len(warnings)} warning(s)")


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

    # Zone-level access-to rules live in band 5 (30000-39999) per the firewall
    # sequence-band architecture (see src/foundation/firewall/README.md). This is
    # ABOVE the rules-manager module bands (3: 10000-19999 ingress, 4: 20000-29999
    # egress), so — under first-match-quick — per-module pinholes are evaluated
    # before a zone's rfc1918 catch-all block and are no longer shadowed (#243).
    #
    # Each zone gets a deterministic 100-sequence slot; within a slot the offsets
    # are FIXED (independent of how many access-to entries a zone has) so adding a
    # zone to access-to fills the next pass offset without shifting — and thus
    # never colliding with — the block/internet rules (#243):
    #   base+0          gateway pass (DNS/NTP to own gateway)
    #   base+1 .. +N    one pass per explicitly allowed zone (N capped below)
    #   base+90/91/92   rfc1918 block (zone isolation catch-all)
    #   base+99         internet pass (only non-RFC1918 reaches here)
    # Slots are derived from a stable hash of the zone name; collisions across
    # zones are harmless because every zone's rules are bound to its own
    # interface (pf only matches a rule against its own interface).
    ZONE_RULE_BAND_BASE = 30000
    ZONE_RULE_SLOT_SIZE = 100
    ZONE_RULE_SLOT_COUNT = 100
    ZONE_RULE_GATEWAY_OFFSET = 0
    ZONE_RULE_PASS_OFFSET = 1          # first access-to pass
    ZONE_RULE_PASS_MAX = 88            # access-to passes occupy base+1 .. base+89
    ZONE_RULE_BLOCK_OFFSET = 90        # rfc1918 blocks at base+90/91/92
    ZONE_RULE_INTERNET_OFFSET = 99     # internet pass last (lowest priority)

    # Caddy reverse-proxy reachability (#366). Split-horizon DNS resolves every
    # proxied name to the DMZ gateway IP (where os-caddy listens on 0.0.0.0:443).
    # Client zones such as home/work have no `access-to: dmz`, so their band-5
    # rfc1918 block (base+90, 30000+) would drop traffic to that IP. We therefore
    # emit a blanket PASS to the DMZ gateway on tcp/80+443 from every zone, low in
    # band 1 (100-999) so — under first-match-quick — it is evaluated *before* the
    # rfc1918 block and lets the packet reach Caddy. This is L3 reachability only:
    # Caddy's own `proxyAllowedZones` ACL remains the real authorization gate, so
    # opening the path from all zones does not grant any zone access to a service.
    CADDY_REACH_SEQUENCE = 990         # band 1; https=990, http=991
    CADDY_REACH_SOURCE = "10.0.0.0/8"  # blanket internal source (rule is iface-bound)
    CADDY_REACH_PORTS = (("443", "https"), ("80", "http"))

    def _zone_rule_base(self, zone: "Zone") -> int:
        """Deterministic band-5 base sequence for a zone's access-to rules."""
        digest = hashlib.sha256(zone.name.encode("utf-8")).digest()
        slot = int.from_bytes(digest[:8], "big") % self.ZONE_RULE_SLOT_COUNT
        return self.ZONE_RULE_BAND_BASE + slot * self.ZONE_RULE_SLOT_SIZE

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

        # Keys beginning with '_' (e.g. _README) are documentation blocks, not
        # zones — skip them so they never become inert Zone objects.
        self.zones = [
            Zone.from_json(name, zone_data)
            for name, zone_data in data.items()
            if not name.startswith("_")
        ]
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
                    # Check by VLAN tag or by interface description/name.
                    # Normalise both sides — the OPNsense interfacesInfo endpoint
                    # has been observed returning vlan_tag as either int or str
                    # depending on version (issue #179).
                    if str(v["vlan_tag"]) == str(zone.vlan_tag):
                        return v["identifier"]
                    # Also check if the interface label matches the zone name.
                    # Post-#237 the SSOT is underscore-aligned so labels and
                    # zone keys match directly with no transformation.
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

    def _rename_interface_label(
        self, manager, zone, assigned, desired_label, check_mode, results,
    ) -> None:
        """Disruptively rename a drifted interface label to ``desired_label``.

        OPNsense has no in-place update for an interface-assignment label, so
        this is an unassign + reassign (delItem+addItem) that briefly tears the
        interface down and re-applies the zone's static gateway IP. Anything
        bound to the interface (firewall rules, DHCP) may need a reconcile run
        afterwards. Opt-in via --force-rename-labels (issue #213).
        """
        label = assigned.get("description") or ""
        iface_id = assigned.get("identifier")
        device = assigned.get("device")

        if check_mode:
            warn(f"  {zone.name}: would force-rename interface label "
                 f"'{label}' -> '{desired_label}' (disruptive)")
            results[zone.name] = {
                "status": "would_rename_label", "from": label,
                "to": desired_label, "vlan": zone.vlan_tag,
            }
            return

        if not iface_id or not device:
            error(f"  {zone.name}: cannot force-rename label — missing interface "
                  f"identifier/device")
            results[zone.name] = {"status": "error",
                                  "error": "missing identifier/device for label rename"}
            return

        warn(f"  {zone.name}: force-renaming interface label '{label}' -> "
             f"'{desired_label}' (disruptive unassign+reassign)")
        try:
            manager.unassign_interface(iface_id)
            res = manager.assign_interface(
                device=device,
                description=desired_label,
                enable=True,
                ipv4_type="static",
                ipv4_address=zone.gateway_ip,
                ipv4_subnet=zone.network.prefixlen,
            )
            new_id = res.get("ifname") if isinstance(res, dict) else None
            if new_id:
                try:
                    manager.reload_interface(new_id)
                except Exception:  # noqa: BLE001 - reload is best-effort
                    pass
            info(f"  {zone.name}: interface label renamed to '{desired_label}' "
                 f"(re-run zone-manager --firewall-rules to refresh bound rules)")
            results[zone.name] = {
                "status": "renamed_label", "from": label,
                "to": desired_label, "vlan": zone.vlan_tag,
            }
        except Exception as e:  # noqa: BLE001 - surface the API error
            error(f"  {zone.name}: force-rename failed: {e}")
            results[zone.name] = {"status": "error", "error": f"label rename failed: {e}"}

    def configure_vlans(
        self,
        check_mode: bool = True,
        assign: bool = True,
        force_rename_labels: bool = False,
    ) -> dict[str, dict]:
        """Configure VLANs for all enabled zones.

        Checks if VLANs already exist before creating them.
        Also deletes VLANs for disabled zones if they exist.
        By default, VLANs are assigned to OPNsense interfaces.

        Args:
            check_mode: If True, don't make changes (dry-run)
            assign: If True (default), also assign VLANs to interfaces
            force_rename_labels: If True, reconcile a drifted interface label to
                the normalized (underscore) zone name via a disruptive
                unassign+reassign API call (issue #213). Default warns only.

        Returns:
            Dictionary mapping zone names to results
        """
        results = {}
        vlan_zones = self.get_vlan_zones()
        disabled_zones = self.get_disabled_vlan_zones()
        manual_zones = [z for z in self.get_manual_zones() if z.needs_vlan]
        untagged_zones = [z for z in self.get_enabled_zones() if not z.needs_vlan]

        debug(f"  Enabled zones requiring VLANs: {len(vlan_zones)}")
        debug(f"  Disabled zones with VLANs to remove: {len(disabled_zones)}")
        debug(f"  Manual zones (skipped): {len(manual_zones)}")
        debug(f"  Untagged zones (skipped, vlantag=0): {len(untagged_zones)}")

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
                    debug(f"  {zone.name}: Deleting VLAN {zone.vlan_tag} (zone disabled)")
                    if check_mode:
                        results[zone.name] = {"status": "would_delete", "vlan": zone.vlan_tag}
                    else:
                        try:
                            # Check if VLAN is assigned to an interface
                            assigned = assigned_by_tag.get(zone.vlan_tag)

                            # If not found in assigned_by_tag, search manually by device
                            # or label (post-#237 the SSOT is underscore so labels
                            # and zone keys compare directly).
                            if not assigned:
                                vlan_device = existing.get("device")
                                zname = zone.name.lower()
                                for v in assigned_vlans:
                                    if (v.get("device") == vlan_device
                                            or v.get("description", "").lower() == zname):
                                        assigned = v
                                        break

                            if assigned:
                                iface_id = assigned.get("identifier")
                                debug(f"    Unassigning interface {iface_id} first...")
                                manager.unassign_interface(iface_id)

                            # Now delete the VLAN
                            result = manager.delete_vlan(existing["description"], check_mode=False)
                            results[zone.name] = {"status": "deleted", "result": result}
                        except Exception as e:
                            error_msg = str(e)
                            # If deletion fails because interface is still assigned, provide helpful error
                            if "assigned as an interface" in error_msg.lower():
                                error(f"VLAN is assigned to an interface but could not be unassigned automatically.")
                                error(f"Please manually delete the interface in OPNsense first, then re-run zone-manager.")
                            else:
                                error(f"{zone.name}: {e}")
                            results[zone.name] = {"status": "error", "error": error_msg}
                else:
                    debug(f"  {zone.name}: VLAN {zone.vlan_tag} not found (nothing to delete)")
                    results[zone.name] = {"status": "not_found", "vlan": zone.vlan_tag}

            # Then, create VLANs for enabled zones
            for zone in vlan_zones:
                vlan_desc = zone.vlan_description
                # Prioritize tag-based lookup to avoid matching wrong VLANs with duplicate descriptions
                existing = existing_tags.get(zone.vlan_tag) or existing_descriptions.get(vlan_desc)

                if existing:
                    # Reconcile a drifted VLAN description in place (issue #186).
                    # Renaming/redescribing a zone in zones.json must update the
                    # existing VLAN's description rather than leave it stale.
                    existing_descr = existing.get("description") or ""
                    if existing_descr != vlan_desc:
                        if check_mode:
                            debug(f"  {zone.name}: VLAN {zone.vlan_tag} description drift "
                                  f"({existing_descr!r} → {vlan_desc!r})")
                            results[zone.name] = {
                                "status": "would_update_description",
                                "vlan": zone.vlan_tag,
                                "from": existing_descr,
                                "to": vlan_desc,
                            }
                        else:
                            try:
                                manager.update_vlan_description(
                                    uuid=existing["uuid"],
                                    interface=existing["interface"],
                                    tag=zone.vlan_tag,
                                    description=vlan_desc,
                                    priority=existing.get("priority", 0),
                                    check_mode=False,
                                )
                                debug(f"  {zone.name}: VLAN {zone.vlan_tag} description updated "
                                      f"({existing_descr!r} → {vlan_desc!r})")
                                results[zone.name] = {
                                    "status": "updated_description",
                                    "vlan": zone.vlan_tag,
                                    "from": existing_descr,
                                    "to": vlan_desc,
                                }
                            except Exception as e:
                                results[zone.name] = {"status": "error", "error": str(e)}
                                error(f"{zone.name}: {e}")
                    else:
                        debug(f"  {zone.name}: VLAN {zone.vlan_tag} already exists (skipping)")
                        results[zone.name] = {
                            "status": "exists",
                            "vlan": zone.vlan_tag,
                            "device": existing.get("device"),
                        }

                    # The assigned-interface label (the "[name]" shown in the GUI)
                    # is the interface-assignment description, set at creation to
                    # the zone name with hyphens normalized to underscores
                    # (issue #213 — the GUI strips hyphens, so underscores are the
                    # only form that survives manual edits). OPNsense has no safe
                    # in-place update for it (only delItem+addItem, which is
                    # disruptive), so by default we warn on drift. Pass
                    # --force-rename-labels to opt into the disruptive rename.
                    assigned = assigned_by_tag.get(zone.vlan_tag)
                    if assigned:
                        label = (assigned.get("description") or "")
                        desired_label = zone.name
                        if label and label.lower() != desired_label.lower():
                            if force_rename_labels:
                                self._rename_interface_label(
                                    manager, zone, assigned, desired_label,
                                    check_mode, results,
                                )
                            else:
                                # Drift is surfaced inline in the unified summary
                                # table (print_zone_summary computes it from the
                                # live label), so just trace it here — no detached
                                # warning (issues #212/#213).
                                debug(f"  {zone.name}: interface label '{label}' "
                                      f"drifted (desired '{desired_label}')")
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
                debug(f"  {zone.name}: Creating VLAN {zone.vlan_tag} on {vlan_interface} (bridge: {zone.bridge}, gateway: {gateway_ip}/{subnet_bits})")

                if check_mode:
                    results[zone.name] = {"status": "would_create", "vlan": zone.vlan_tag}
                else:
                    # DEBUG: Check Unbound before VLAN creation
                    _check_unbound_dns(f"BEFORE create_vlan {zone.name}")

                    try:
                        # Name the assigned interface after the zone, with
                        # zone keys are already underscore-aligned with OPNsense
                        # interface labels (#237). Also assign the gateway IP
                        # statically.
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

                        # DEBUG: Check Unbound after VLAN creation
                        _check_unbound_dns(f"AFTER create_vlan {zone.name}")

                    except Exception as e:
                        results[zone.name] = {"status": "error", "error": str(e)}
                        error(f"{zone.name}: {e}")

            # Report on manual zones (not created or deleted)
            for zone in manual_zones:
                debug(f"  {zone.name}: VLAN {zone.vlan_tag} skipped (manual zone)")
                results[zone.name] = {"status": "skipped_manual", "vlan": zone.vlan_tag}

            # Report on untagged zones (vlantag=0, not managed by zone-manager)
            for zone in untagged_zones:
                debug(f"  {zone.name}: VLAN skipped (untagged zone, vlantag=0)")
                results[zone.name] = {"status": "skipped_untagged", "reason": "vlantag=0"}

            # Belt-and-suspenders: force OPNsense to reconcile every VLAN
            # interface from /conf/config.xml. The custom InterfaceAssign
            # controller already does this after each addItem; this extra call
            # catches drift where an interface exists in config but its kernel
            # IP fell out of sync (observed in the #237 verification after a
            # configd restart). Cheap and idempotent.
            if not check_mode:
                # DEBUG: Check Unbound before apply_vlan_settings
                _check_unbound_dns("BEFORE apply_vlan_settings")

                try:
                    manager.apply_vlan_settings()
                except Exception as e:
                    debug(f"  apply_vlan_settings: {e}")

                # DEBUG: Check Unbound after apply_vlan_settings
                _check_unbound_dns("AFTER apply_vlan_settings")

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

        debug(f"  Enabled zones requiring DHCP: {len(dhcp_zones)}")
        debug(f"  Disabled zones with DHCP to remove: {len(disabled_zones)}")
        debug(f"  Manual zones (skipped): {len(manual_zones)}")
        debug(f"  Untagged zones (skipped, vlantag=0): {len(untagged_zones)}")

        with DhcpManager(self.config) as manager:
            # Get existing DHCP ranges once for efficiency
            existing_ranges = manager.list_ranges()
            existing_by_desc = {r["description"]: r for r in existing_ranges}

            # Stage all create/delete changes, then reconfigure dnsmasq once.
            changed = False

            # First, delete DHCP ranges for disabled zones
            for zone in disabled_zones:
                dhcp_desc = zone.dhcp_description
                existing = existing_by_desc.get(dhcp_desc)

                if existing:
                    debug(f"  {zone.name}: Deleting DHCP range (zone disabled)")
                    if check_mode:
                        results[zone.name] = {
                            "status": "would_delete",
                            "range": f"{zone.dhcp_start}-{zone.dhcp_end}",
                        }
                    else:
                        try:
                            result = manager.delete_range(
                                dhcp_desc, check_mode=False, reconfigure=False
                            )
                            changed = True
                            results[zone.name] = {"status": "deleted", "result": result}
                        except Exception as e:
                            results[zone.name] = {"status": "error", "error": str(e)}
                            error(f"{zone.name}: {e}")
                else:
                    debug(f"  {zone.name}: DHCP range not found (nothing to delete)")
                    results[zone.name] = {"status": "not_found"}

            # Then, create (or rebind) DHCP ranges for enabled zones with VLANs
            for zone in dhcp_zones:
                dhcp_desc = zone.dhcp_description

                # Determine the interface for DHCP first — it is needed both to
                # create the range and to detect an existing-but-unbound range
                # (the issue #179 failure mode) that must be rebound.
                # The bridge field may be 'lan', 'wan', or a logical name;
                # OPNsense dnsmasq accepts identifiers like 'lan'/'wan'/'opt1'.
                dhcp_interface = None
                if zone.needs_vlan:
                    # For VLAN zones, look up the assigned interface identifier.
                    with VlanManager(self.config) as vlan_mgr:
                        assigned = vlan_mgr.get_assigned_vlans()
                        for v in assigned:
                            # Normalise both sides — see issue #179.
                            if str(v["vlan_tag"]) == str(zone.vlan_tag):
                                dhcp_interface = v["identifier"]
                                break
                else:
                    bridge_lower = zone.bridge.lower()
                    if bridge_lower in ("lan", "wan") or bridge_lower.startswith("opt"):
                        dhcp_interface = zone.bridge

                existing = existing_by_desc.get(dhcp_desc)
                existing_iface = (existing.get("interface") or "") if existing else ""

                # Skip only when the range is already present AND bound to the
                # CURRENT interface (or when no binding is expected). If it is
                # bound to a different identifier — e.g. left orphaned after an
                # interface-label rename churned opt1→opt11 (issue #213) — fall
                # through to (re)create so create_range rebinds it. create_range
                # is idempotent and also rebinds a previously-unbound (interface
                # = '') range.
                iface_ok = (not dhcp_interface) or (existing_iface == dhcp_interface)
                if existing and iface_ok:
                    debug(f"  {zone.name}: DHCP range already correct (skipping)")
                    results[zone.name] = {
                        "status": "exists",
                        "range": f"{existing.get('start_addr')}-{existing.get('end_addr')}",
                        "interface": existing_iface or "any",
                    }
                    continue

                dhcp_range = DhcpRange(
                    description=dhcp_desc,
                    start_addr=zone.dhcp_start,
                    end_addr=zone.dhcp_end,
                    interface=dhcp_interface,  # May be None (any) if not assigned
                    domain=zone.domain,
                    lease_time=86400,  # 24 hours
                )

                interface_info = dhcp_interface or "any"
                will_rebind = existing is not None
                debug(f"  {zone.name}: {zone.dhcp_start} - {zone.dhcp_end} ({zone.domain}) on {interface_info}")

                if check_mode:
                    results[zone.name] = {
                        "status": "would_rebind" if will_rebind else "would_create",
                        "range": f"{zone.dhcp_start}-{zone.dhcp_end}",
                        "domain": zone.domain,
                        "interface": interface_info,
                    }
                else:
                    try:
                        # Stage the change; reconfigure once after the loop.
                        result = manager.create_range(
                            dhcp_range, check_mode=False, reconfigure=False
                        )
                        changed = True
                        results[zone.name] = {
                            "status": "rebound" if will_rebind else "created",
                            "interface": interface_info,
                            "result": result,
                        }
                    except Exception as e:
                        # Surface binding failures instead of silently
                        # downgrading to an unbound range (the old fallback
                        # masked issue #179).
                        results[zone.name] = {"status": "error", "error": str(e)}
                        error(f"{zone.name}: {e}")

            # Apply all staged DHCP changes in a single reconfigure.
            if changed and not check_mode:
                # DEBUG: Check Unbound before dnsmasq reconfigure
                _check_unbound_dns("BEFORE dnsmasq reconfigure")

                debug("  Reconfiguring dnsmasq to apply DHCP changes...")
                manager.reconfigure()

                # DEBUG: Check Unbound after dnsmasq reconfigure
                _check_unbound_dns("AFTER dnsmasq reconfigure")

            # Report on manual zones (not created or deleted)
            for zone in manual_zones:
                debug(f"  {zone.name}: DHCP skipped (manual zone)")
                results[zone.name] = {
                    "status": "skipped_manual",
                    "range": f"{zone.dhcp_start}-{zone.dhcp_end}",
                }

            # Report on untagged zones (vlantag=0, not managed by zone-manager)
            for zone in untagged_zones:
                debug(f"  {zone.name}: DHCP skipped (untagged zone, vlantag=0)")
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
        protocol: Protocol = Protocol.ANY,
        destination_port: str | None = None,
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
            protocol: L4 protocol to match (default ANY — zone access-to rules)
            destination_port: Destination port/range to match (None = any)
        """
        action_str = "pass" if action == RuleAction.PASS else "block"

        existing = existing_by_desc.get(description)
        if existing:
            # A rule with this description already exists. Rules are keyed by
            # description, but the *bound interface* (and other match fields) can
            # drift out from under a description — most notably after an
            # interface label rename (issue #213) reassigns a zone's opt-id
            # (e.g. srv-home opt1 -> opt11). A stale interface points the rule at
            # a now-nonexistent opt-id, which makes the whole os-firewall
            # ruleset fail to compile and silently load *zero* automation rules
            # into pf. So reconcile drift instead of blindly skipping.
            # Sequence is part of the desired state: a rule left at a stale
            # sequence (e.g. carried over from the old vlan*10 numbering, or
            # from before an access-to zone was added) must be renumbered or it
            # collides with / mis-orders against the other zone rules (#243).
            seq_drift = existing.sequence is None or int(existing.sequence) != sequence
            drifted = (
                existing.interface != interface
                or (existing.action or "").lower() != action_str
                or existing.destination_net != destination_net
                or existing.source_net != source_net
                or (existing.destination_port or None) != destination_port
                or seq_drift
            )
            if not drifted:
                debug(f"    {action_str}: {description} (exists, in sync, skipping)")
                results_list.append({
                    "description": description,
                    "status": "exists",
                    "action": action_str,
                    "destination": destination_net,
                })
                return

            debug(f"    {action_str}: {description} (drift: iface "
                  f"{existing.interface!r}->{interface!r}, seq "
                  f"{existing.sequence!r}->{sequence!r}; reconciling)")
            if check_mode:
                results_list.append({
                    "description": description,
                    "status": "would_update",
                    "action": action_str,
                    "destination": destination_net,
                    "from_interface": existing.interface,
                    "to_interface": interface,
                })
                return
            # Delete the stale rule, then fall through to recreate it cleanly
            # with the correct interface (delete+create is reliable regardless
            # of the oxl rule module's upsert semantics — see oxl-client notes).
            try:
                manager.delete_rule(existing.description, apply=False)
            except Exception as e:  # noqa: BLE001 - surface but continue to recreate
                error(f"Reconciling '{description}': delete of stale rule failed: {e}")

        else:
            debug(f"    {action_str}: {description}")

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
                    protocol=protocol,
                    source_net=source_net,
                    destination_net=destination_net,
                    destination_port=destination_port,
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
                error(f"Firewall rule '{description}': {e}")

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

        Rule ordering per zone (using sequence numbers, band 5 = 30000-39999 so
        the rfc1918 block trails the rules-manager module pinhole bands and no
        longer shadows them — #243):
        1. Pass to own gateway (DNS/NTP access)        — base+0
        2. Pass to each explicitly allowed zone network — base+1 .. base+89
        3. Block RFC1918 private ranges (zone isolation)— base+90/91/92
        4. Pass to any (internet access)               — base+99
        Offsets are fixed regardless of how many zones are in access-to, so
        adding a zone never renumbers (or collides with) the block/internet rules.

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

        debug(f"  Zones with access-to rules: {len(firewall_zones)}")
        debug(f"  Isolated zones (empty access-to): {len(isolated_zones)}")
        debug(f"  Disabled zones (rules to clean up): {len(disabled_zones)}")
        debug(f"  Manual zones (skipped): {len(manual_zones)}")

        with FirewallManager(self.config) as manager:
            # Get existing rules for comparison
            existing_rules = manager.list_rules()
            existing_by_desc = {r.description: r for r in existing_rules}

            # Delete firewall rules for disabled zones
            for zone in disabled_zones:
                zone_prefix = f"Zone {zone.name} "
                matching = [r for r in existing_rules if r.description.startswith(zone_prefix)]
                if matching:
                    debug(f"  {zone.name}: Deleting {len(matching)} rules (zone disabled)")
                    if not check_mode:
                        for rule_info in matching:
                            try:
                                manager.delete_rule(rule_info.description, apply=False)
                            except Exception as e:
                                error(f"Deleting '{rule_info.description}': {e}")
                    results[zone.name] = {
                        "status": "would_delete" if check_mode else "deleted",
                        "rules_deleted": len(matching),
                    }

            # Create rules for enabled zones
            for zone in firewall_zones:
                zone_results = []
                zone_interface = self.get_zone_interface(zone)

                if not zone_interface:
                    warn(f"{zone.name}: Cannot find interface (skipping)")
                    results[zone.name] = {
                        "status": "error",
                        "error": "Interface not found",
                        "rules": [],
                    }
                    continue

                debug(f"  {zone.name} (interface: {zone_interface}):")

                # Categorise targets
                targets_lower = [t.lower() for t in zone.access_to]
                has_all = "all" in targets_lower
                has_internet = "internet" in targets_lower
                specific_targets = [t for t in zone.access_to if t.lower() not in ("all", "internet")]

                # Deterministic band-5 base for this zone (#243). Intra-zone
                # offsets are FIXED so adding an access-to zone never shifts the
                # block/internet rules into a colliding sequence.
                base = self._zone_rule_base(zone)

                if has_all:
                    # Full access — single pass rule to any
                    self._create_or_skip_rule(
                        manager, existing_by_desc,
                        f"Zone {zone.name} -> all",
                        zone_interface, zone.ip_network, "any",
                        RuleAction.PASS, base + self.ZONE_RULE_GATEWAY_OFFSET,
                        check_mode, zone_results,
                    )
                else:
                    # Step 1: Allow access to own gateway (DNS, NTP)
                    self._create_or_skip_rule(
                        manager, existing_by_desc,
                        f"Zone {zone.name} -> gateway",
                        zone_interface, zone.ip_network, f"{zone.gateway_ip}/32",
                        RuleAction.PASS, base + self.ZONE_RULE_GATEWAY_OFFSET,
                        check_mode, zone_results,
                    )

                    # Step 2: Allow access to each explicitly named zone. These
                    # occupy fixed offsets base+1 .. base+89, so the block band
                    # below stays put regardless of how many zones are listed.
                    if len(specific_targets) > self.ZONE_RULE_PASS_MAX:
                        error(
                            f"{zone.name}: {len(specific_targets)} access-to zones "
                            f"exceeds the {self.ZONE_RULE_PASS_MAX}-slot pass band; "
                            f"rules beyond that would collide with the block band"
                        )
                    for offset, target in enumerate(
                        specific_targets[: self.ZONE_RULE_PASS_MAX]
                    ):
                        target_zone = self.get_zone_by_name(target)
                        if target_zone:
                            dest = target_zone.ip_network
                        else:
                            warn(f"target zone '{target}' not found in zones.json, using name as alias")
                            dest = target
                        self._create_or_skip_rule(
                            manager, existing_by_desc,
                            f"Zone {zone.name} -> {target}",
                            zone_interface, zone.ip_network, dest,
                            RuleAction.PASS, base + self.ZONE_RULE_PASS_OFFSET + offset,
                            check_mode, zone_results,
                        )

                    if has_internet:
                        # Step 3: Block RFC1918 to prevent reaching unlisted internal
                        # zones — fixed offsets base+90/91/92, always trailing the
                        # access-to passes above.
                        for offset, (network, label) in enumerate(self.RFC1918_NETWORKS):
                            self._create_or_skip_rule(
                                manager, existing_by_desc,
                                f"Zone {zone.name} block {label}",
                                zone_interface, zone.ip_network, network,
                                RuleAction.BLOCK,
                                base + self.ZONE_RULE_BLOCK_OFFSET + offset,
                                check_mode, zone_results,
                            )

                        # Step 4: Allow internet (pass to any — only non-RFC1918 reaches here)
                        self._create_or_skip_rule(
                            manager, existing_by_desc,
                            f"Zone {zone.name} -> internet",
                            zone_interface, zone.ip_network, "any",
                            RuleAction.PASS, base + self.ZONE_RULE_INTERNET_OFFSET,
                            check_mode, zone_results,
                        )

                results[zone.name] = {
                    "status": "processed",
                    "interface": zone_interface,
                    "rules": zone_results,
                }

            # Blanket reverse-proxy reachability (#366): every zone may reach the
            # DMZ gateway (Caddy) on tcp/80+443 regardless of access-to, so
            # split-horizon DNS to the DMZ gateway works for client zones that have
            # no access-to: dmz. Emitted across all zone interfaces, in band 1.
            self._configure_caddy_reachability(
                manager, existing_by_desc, results, check_mode
            )

            # Apply all changes at once if not in check mode
            if not check_mode:
                debug("  Applying firewall changes...")
                try:
                    manager.apply_changes()
                    debug("  Changes applied successfully")
                except Exception as e:
                    error(f"Applying firewall changes: {e}")

            # Report on isolated zones (enabled but empty access-to)
            for zone in isolated_zones:
                debug(f"  {zone.name}: No rules (fully isolated, default block)")
                results[zone.name] = {"status": "isolated", "access_to": []}

            # Report on manual zones
            for zone in manual_zones:
                if zone.access_to:
                    debug(f"  {zone.name}: Firewall rules skipped (manual zone)")
                    results[zone.name] = {
                        "status": "skipped_manual",
                        "access_to": zone.access_to,
                    }

        return results

    def _configure_caddy_reachability(
        self,
        manager: FirewallManager,
        existing_by_desc: dict[str, FirewallRuleInfo],
        results: dict,
        check_mode: bool,
    ) -> None:
        """Emit a blanket PASS to the DMZ gateway (Caddy) from every zone (#366).

        Split-horizon DNS points every proxied name at the DMZ gateway IP, where
        os-caddy listens on 0.0.0.0:443. Client zones (home, work, …) have no
        `access-to: dmz`, so their band-5 rfc1918 block would drop that traffic.
        This adds an interface-bound PASS on tcp/80+443 to the DMZ gateway low in
        band 1, so under first-match-quick it wins over the rfc1918 block. It is
        pure L3 reachability — Caddy's `proxyAllowedZones` ACL still authorizes per
        service, so no zone gains service access it would not otherwise have.

        Rules are named ``Zone <name> -> caddy <proto>`` so the existing
        disabled-zone cleanup (which deletes by the ``Zone <name> `` prefix) tears
        them down when a zone is disabled.
        """
        dmz = self.get_zone_by_name("dmz")
        if dmz is None:
            warn("  Caddy reachability (#366): no 'dmz' zone in zones.json — skipping")
            return
        try:
            caddy_dest = f"{dmz.gateway_ip}/32"
        except Exception as e:  # noqa: BLE001 - malformed dmz.ip should not abort reconcile
            warn(f"  Caddy reachability (#366): cannot derive DMZ gateway: {e} — skipping")
            return

        # Every zone whose clients enter on their own interface needs the pass:
        # enabled zones (incl. fully-isolated ones) plus manual zones (e.g. mgmt).
        # The dmz zone itself reaches the gateway locally and is skipped.
        candidate_zones = [
            z for z in (self.get_enabled_zones() + self.get_manual_zones())
            if z.name != dmz.name
        ]

        for zone in candidate_zones:
            zone_interface = self.get_zone_interface(zone)
            if not zone_interface:
                continue
            zone_results = results.setdefault(
                zone.name, {"status": "processed", "rules": []}
            ).setdefault("rules", [])
            for offset, (port, label) in enumerate(self.CADDY_REACH_PORTS):
                self._create_or_skip_rule(
                    manager, existing_by_desc,
                    f"Zone {zone.name} -> caddy {label}",
                    zone_interface, self.CADDY_REACH_SOURCE, caddy_dest,
                    RuleAction.PASS, self.CADDY_REACH_SEQUENCE + offset,
                    check_mode, zone_results,
                    protocol=Protocol.TCP, destination_port=port,
                )

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

        debug(f"  Dnsmasq interfaces: {', '.join(interfaces)}")

        if check_mode:
            return {"status": "would_update", "interfaces": interfaces}

        # DEBUG: Check Unbound before set_dnsmasq_interfaces
        _check_unbound_dns("BEFORE set_dnsmasq_interfaces")

        try:
            with DhcpManager(self.config) as manager:
                result = manager.set_dnsmasq_interfaces(
                    interfaces=interfaces,
                    check_mode=check_mode,
                )
                debug(f"  Updated dnsmasq to listen on {len(interfaces)} interfaces")

                # DEBUG: Check Unbound after set_dnsmasq_interfaces
                _check_unbound_dns("AFTER set_dnsmasq_interfaces")

                return {"status": "updated", "interfaces": interfaces, "result": result}
        except Exception as e:
            error(f"Updating dnsmasq interfaces: {e}")
            return {"status": "error", "error": str(e)}

    def configure_all(
        self,
        check_mode: bool = True,
        assign_vlans: bool = True,
        firewall_rules: bool = True,
        force_rename_labels: bool = False,
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
        # Configure VLANs first, then update dnsmasq bindings so it
        # recognises the new interfaces, then create DHCP ranges.
        info("Step 1: Configuring VLANs")
        vlan_results = self.configure_vlans(
            check_mode=check_mode, assign=assign_vlans,
            force_rename_labels=force_rename_labels,
        )

        # Update dnsmasq to listen on all VLAN interfaces *before* creating
        # DHCP ranges — otherwise dnsmasq rejects the interface identifiers
        # (opt1, opt2, …) because it doesn't know about them yet.
        info("Step 2: Updating dnsmasq interface bindings")
        dnsmasq_result = self.update_dnsmasq_interfaces(check_mode=check_mode)

        info("Step 3: Configuring DHCP ranges")
        dhcp_results = self.configure_dhcp(check_mode=check_mode)

        result = {
            "vlans": vlan_results,
            "dhcp": dhcp_results,
            "dnsmasq_interfaces": dnsmasq_result,
        }

        if firewall_rules:
            info("Step 4: Configuring Firewall Rules")
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
        """Print the current VLAN and DHCP configuration from OPNsense.

        Uses info() — this is the explicitly requested output of --list-config
        and the post-execute verification step (issue #180). Was previously
        emitted via debug() and therefore invisible without --debug.
        """
        config = self.list_current_config()

        info("Current OPNsense Configuration:")
        info("=" * 80)

        info("VLANs:")
        info("-" * 80)
        if not config["vlans"]:
            info("  No VLANs configured")
        else:
            info(f"  {'Tag':<6} {'Device':<15} {'Interface':<12} {'Description'}")
            info("  " + "-" * 70)
            for vlan in config["vlans"]:
                info(f"  {vlan['tag']:<6} {vlan['device'] or '-':<15} {vlan['interface']:<12} {vlan['description']}")

        info("DHCP Ranges:")
        info("-" * 80)
        if not config["dhcp_ranges"]:
            info("  No DHCP ranges configured")
        else:
            info(f"  {'Description':<20} {'Start':<16} {'End':<16} {'Interface':<10} {'Domain'}")
            info("  " + "-" * 75)
            for r in config["dhcp_ranges"]:
                info(
                    f"  {r['description'] or '-':<20} {r['start_addr'] or '-':<16} "
                    f"{r['end_addr'] or '-':<16} {r['interface'] or 'any':<10} {r['domain'] or '-'}"
                )

        info("=" * 80)

    def print_zone_summary(self, results: dict | None = None) -> None:
        """Print one VLAN-tag-sorted table of all zones (issue #212).

        Replaces the previously separate VLAN, DHCP and warnings tables with a
        single table keyed on the zone name and sorted by VLAN tag. A trailing
        Flags column carries the per-zone change summary (created/updated/
        renamed) and warnings (label drift) inline, so a warning is never
        detached from the zone it describes. Rows with a warning flag are
        emitted via warn(); all others via info().

        Args:
            results: optional dict returned by configure_* (configure_all's
                {"vlans":..,"dhcp":..} or a bare vlan-results dict). When given,
                change/warning flags are derived from it.
        """
        vlan_results = (results or {}).get("vlans", results or {})
        if not isinstance(vlan_results, dict):
            vlan_results = {}

        # Query live OPNsense once (best-effort). Two sources:
        #   • assigned interfaces (get_assigned_vlans): tag → identifier (opt1)
        #     and the assignment label (for drift detection — issue #213).
        #   • DHCP ranges: domain → range and the lan/opt id for untagged zones.
        assigned_by_tag: dict[int, dict] = {}
        iface_by_domain: dict[str, str] = {}
        dhcp_by_domain: dict[str, tuple[str, str]] = {}
        try:
            with VlanManager(self.config) as _vm:
                for a in _vm.get_assigned_vlans():
                    try:
                        assigned_by_tag[int(a["vlan_tag"])] = a
                    except (TypeError, ValueError, KeyError):
                        continue
            live = self.list_current_config()
            for r in live.get("dhcp_ranges", []):
                dom = r.get("domain") or ""
                if dom:
                    iface_by_domain[dom] = r.get("interface") or ""
                    dhcp_by_domain[dom] = (r.get("start_addr") or "", r.get("end_addr") or "")
        except Exception as e:  # noqa: BLE001 - summary degrades gracefully offline
            debug(f"  (live OPNsense config unavailable for summary: {e})")

        def _last_octet(addr: str) -> str:
            return f".{addr.rsplit('.', 1)[1]}" if addr and "." in addr else addr

        def _flag_for(zone: "Zone") -> tuple[str, bool]:
            """Return (flag_text, is_warning): live label drift takes priority,
            then the change status from a configure run (if any)."""
            # Live label drift — computed from the assigned label so it shows in
            # read-only --list too, not just after a configure run. Post-#237 the
            # SSOT zone key IS the desired OPNsense label (no transformation).
            if zone.needs_vlan:
                a = assigned_by_tag.get(zone.vlan_tag)
                live_label = (a or {}).get("description") or ""
                desired = zone.name
                if live_label and live_label.lower() != desired.lower():
                    return (f"label drift '{live_label}' → rename to '{desired}' "
                            f"(--force-rename-labels)", True)
            res = vlan_results.get(zone.name, {})
            status = res.get("status", "")
            if status == "error":
                return (f"ERROR: {res.get('error', 'see log')}", True)
            if status in ("created", "would_create"):
                return ("created", False)
            if status in ("updated_description", "would_update_description"):
                return ("updated", False)
            if status in ("renamed_label", "would_rename_label"):
                return ("renamed label", False)
            return ("—", False)

        info("Zone Summary:")
        sep = "─" * 150
        info(sep)
        info(f"  {'VLAN':>4}  {'Zone':<13} {'Type':<11} {'State':<9} {'IF':<7} "
             f"{'Network':<19} {'DHCP':<11} {'Domain':<22} {'Flags':<10} Description")
        info(sep)

        warn_count = created_count = 0
        for zone in sorted(self.zones, key=lambda z: z.vlan_tag):
            if zone.is_enabled:
                state = "enabled"
            elif zone.is_manual:
                state = "manual"
            else:
                state = "disabled"

            vlan = str(zone.vlan_tag) if zone.vlan_tag > 0 else "0"
            network = zone.ip_network or "—"
            domain = zone.domain or "—"

            # IF: assigned identifier for tagged zones; untagged/manual fall back
            # to the DHCP-range interface (e.g. mgmt → lan) then the bridge.
            if zone.needs_vlan and zone.vlan_tag in assigned_by_tag:
                iface = assigned_by_tag[zone.vlan_tag].get("identifier") or "—"
            else:
                iface = iface_by_domain.get(domain) or (
                    zone.bridge if (not zone.needs_vlan or zone.is_manual) else "") or "—"

            rng = dhcp_by_domain.get(domain)
            if rng and rng[0]:
                dhcp = f"{_last_octet(rng[0])}-{_last_octet(rng[1])}"
            elif zone.is_enabled and zone.needs_vlan:
                dhcp = f"{_last_octet(zone.dhcp_start)}-{_last_octet(zone.dhcp_end)}"
            else:
                dhcp = "—"

            flag, is_warn = _flag_for(zone)
            if is_warn:
                warn_count += 1
            elif flag == "created":
                created_count += 1

            description = zone.description or "—"
            row = (f"  {vlan:>4}  {zone.name:<13} {zone.zone_type:<11} {state:<9} "
                   f"{iface:<7} {network:<19} {dhcp:<11} {domain:<22} {flag:<10} {description}")
            if is_warn:
                warn(row)
            else:
                info(row)

        info(sep)
        enabled = len(self.get_enabled_zones())
        disabled = len(self.get_disabled_zones())
        manual = len(self.get_manual_zones())
        footer = (f"  {len(self.zones)} zones · {enabled} enabled · {disabled} disabled · "
                  f"{manual} manual")
        if warn_count or created_count:
            extras = []
            if warn_count:
                extras.append(f"{warn_count} warning{'s' if warn_count != 1 else ''}")
            if created_count:
                extras.append(f"{created_count} created")
            footer += " — " + " · ".join(extras)
        info(footer)


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
        "--force-rename-labels",
        action="store_true",
        help="Reconcile a drifted interface label to the normalized (underscore) "
             "zone name via a DISRUPTIVE unassign+reassign API call (issue #213). "
             "Default warns only. Re-run zone-manager --firewall-rules afterwards.",
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
        help=("Only show zone summary and run the pinhole-allowed-from "
              "policy validator (issue #163); don't configure anything"),
    )
    parser.add_argument(
        "--list-config", "--list",
        action="store_true",
        dest="list_config",
        help="List the current zone configuration as the unified zone summary "
             "table (live interface IDs, DHCP ranges, drift flags)",
    )
    parser.add_argument(
        "--modules-dir",
        default="/home/tappaas/config",
        help=("Directory containing module.json files used by --summary's "
              "pinhole-allowed-from validator (default: /home/tappaas/config)"),
    )
    parser.add_argument(
        "--skip-preflight",
        action="store_true",
        help="Skip the pre-flight AND post-flight DNS/egress health gates (#307). "
             "Use for recovery or air-gapped runs where the 10.0.0.1/1.1.1.1 probes "
             "do not apply. By default --execute aborts if DNS/egress is degraded.",
    )
    parser.add_argument(
        "--skip-egress-check",
        action="store_true",
        help="Skip only the egress probe (1.1.1.1:443) in the health gates (#307), "
             "keeping the Unbound DNS check. Use on air-gapped clusters with no "
             "internet egress but a working local resolver.",
    )

    args = parser.parse_args()
    check_mode = not args.execute

    # Find zones.json file
    zones_file = args.zones_file
    if not zones_file:
        # Try to find it relative to common locations
        possible_paths = [
            Path("zones.json"),
            Path("src/foundation/firewall/zones.json"),
            Path("/home/tappaas/TAPPaaS/src/foundation/firewall/zones.json"),
        ]
        for path in possible_paths:
            if path.exists():
                zones_file = str(path)
                break

    if not zones_file:
        error("Could not find zones.json. Use --zones-file to specify the path.")
        sys.exit(1)

    # Map --debug flag to environment variable so log module picks it up
    if args.debug:
        os.environ["TAPPAAS_DEBUG"] = "1"

    if check_mode and not args.summary and not args.list_config:
        warn("RUNNING IN CHECK MODE (dry-run) - no changes will be made. Use --execute to actually make changes.")

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
        error(f"Configuration error: {e}")
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
        error(str(e))
        sys.exit(1)
    except json.JSONDecodeError as e:
        error(f"Parsing zones.json: {e}")
        sys.exit(1)

    # The unified zone summary (issue #212) is printed once AFTER configuration
    # so its Flags column can carry the change/warning outcome. (--list-config
    # and --summary below have their own dedicated output and exit early.)

    # List current config if requested — same unified table as the configure
    # run (issue #212), read-only (no results → flags reflect live drift only).
    if args.list_config:
        # Surface API/auth/reachability failures clearly with a non-zero exit
        # rather than silently leaving the operator with only the local zone
        # summary (issue #180).
        try:
            manager.print_zone_summary()
        except Exception as e:
            error(f"Failed to fetch live OPNsense configuration: {e}")
            sys.exit(1)
        sys.exit(0)

    if args.summary:
        # Pinhole-allowed-from validator (issue #163): cross-check every
        # module.json's ingress + dependsOn against the policy in zones.json.
        # Exit code: 0 if at most warnings; 2 if any schema error.
        zones_map = {z.name: z for z in manager.zones}
        warnings, errors = validate_pinhole_allowed_from(
            zones_map, Path(args.modules_dir),
        )
        print_validation_report(warnings, errors)
        sys.exit(2 if errors else 0)

    # Pre-flight health gate (#307): refuse to mutate a firewall whose DNS or
    # egress is already degraded — a further zone change can make DNS
    # unrecoverable (and recovery SSH would itself need DNS). Probes use IP
    # literals (10.0.0.1, 1.1.1.1) so they never depend on name resolution.
    if args.execute and not args.skip_preflight:
        if not preflight_checks(skip_egress=args.skip_egress_check):
            error("Aborting --execute on pre-flight health failure. "
                  "Override with --skip-preflight (recovery/air-gapped).")
            sys.exit(2)

    # Configure based on options
    # By default, VLANs are assigned to interfaces (use --no-assign to disable)
    # By default, firewall rules are configured (use --no-firewall-rules to disable)
    assign_vlans = not args.no_assign
    firewall_rules = not args.no_firewall_rules
    if args.vlans_only:
        results = {"vlans": manager.configure_vlans(
            check_mode=check_mode, assign=assign_vlans,
            force_rename_labels=args.force_rename_labels,
        )}
    elif args.dhcp_only:
        results = {"dhcp": manager.configure_dhcp(check_mode=check_mode)}
    elif args.firewall_rules_only:
        results = {"firewall": manager.configure_firewall_rules(check_mode=check_mode)}
    else:
        results = manager.configure_all(
            check_mode=check_mode,
            assign_vlans=assign_vlans,
            firewall_rules=firewall_rules,
            force_rename_labels=args.force_rename_labels,
        )

    # One unified, VLAN-tag-sorted summary with inline change/warning flags
    # (issue #212). It queries the live OPNsense config for interface IDs and
    # DHCP ranges, so it doubles as the post-execute verification — replacing
    # the former separate VLAN/DHCP/warnings tables.
    manager.print_zone_summary(results)

    # Firewall rules are not a per-zone column in the table; keep a concise
    # processed-count line (per-zone detail at --debug).
    if "firewall" in results:
        fw = results["firewall"]
        info(f"  Firewall rules: {len(fw)} zones processed")
        for zone_name, result in fw.items():
            debug(f"    {zone_name}: {result.get('status', 'unknown')}")

    # Post-flight health gate (#307): if the zone changes degraded DNS or egress,
    # exit non-zero so the deploy pipeline stops before shipping a broken
    # firewall. Recovery must use the firewall's mgmt IP (10.0.0.1), not DNS.
    if args.execute and not args.skip_preflight:
        if not postflight_checks(skip_egress=args.skip_egress_check):
            error("Post-flight health check failed — zone changes degraded "
                  "DNS/egress. Recover via the firewall mgmt IP (10.0.0.1), not DNS.")
            sys.exit(2)


if __name__ == "__main__":
    main()
