#!/usr/bin/env python3
"""Module Firewall Rules Manager for TAPPaaS.

This module implements the firewall:firewall service capability. It reads
per-module firewall declarations (ports / ingress / egress / aliases) from
a module's JSON file, validates them against zones.json, compiles them into
OPNsense firewall rules, and applies them atomically.

It is a TAPPaaS-aware orchestrator: it knows the module.json and zones.json
schemas and the pinhole-allowed-from policy. It delegates all raw OPNsense
API work to the existing FirewallManager primitives (composition, not
inheritance) -- the same way zone_manager.py composes FirewallManager,
DhcpManager and VlanManager.

Capability:   firewall:firewall   (declared in firewall.json `provides`)
Backend for:  src/foundation/firewall/services/firewall/*.sh
Analogous to: caddy_manager.py  (backend for firewall:proxy)

Usage:
    firewall-rules-manager add-rules <module> --no-ssl-verify
    firewall-rules-manager reconcile <module> --no-ssl-verify
    firewall-rules-manager remove-rules <module> --no-ssl-verify
    firewall-rules-manager verify-rules <module> --no-ssl-verify
    firewall-rules-manager list-rules [--module <module>] --no-ssl-verify
"""

import json
from dataclasses import dataclass, field
from pathlib import Path

from .config import Config
from .firewall_manager import (
    FirewallManager,
    FirewallRule,
    FirewallRuleInfo,
    Protocol,
    RuleAction,
    RuleDirection,
)
from .log import debug, error, info, warn
from .zone_manager import Zone

# Description prefix for every rule this manager creates. Mirrors the
# "TAPPaaS: <module>" idempotency tag used by caddy_manager / services/proxy.
# Extended with per-rule detail so a single module can own many rules while
# each rule still has a unique description for idempotent upsert:
#
#   TAPPaaS: <module> [<direction>:<peer>:<port>/<protocol>]
#
# Filtering on "TAPPaaS: <module>" (substring) still selects all of a
# module's rules, exactly like the proxy capability.
DESCRIPTION_PREFIX = "TAPPaaS"

# Sequence bands -- see issue #151 section 9. Module ingress and egress rules
# occupy dedicated bands so they always evaluate before zone-wide rules
# (band 3xxxx) and after foundation rules (bands 1xx-9xxx).
BAND_INGRESS = 10000
BAND_EGRESS = 20000
SLOT_SIZE = 100  # sequence numbers reserved per module per direction


# =============================================================================
# Schema dataclasses -- parsed from module.json
# =============================================================================


@dataclass
class PortSpec:
    """A port a module exposes for inbound traffic (module.json `ports[]`)."""

    port: str
    protocol: Protocol = Protocol.TCP
    description: str = ""

    @classmethod
    def from_json(cls, data: dict) -> "PortSpec":
        """Create from a module.json ports[] entry."""
        return cls(
            port=str(data.get("port", "")),
            protocol=_protocol_from_str(data.get("protocol", "TCP")),
            description=data.get("description", ""),
        )


@dataclass
class IngressRule:
    """An allowed inbound flow (module.json `ingress[]`)."""

    from_peer: str  # zone name | 'internet' | module name | 'alias:<name>'
    ports: list[str]
    protocol: Protocol = Protocol.TCP
    why: str = ""

    @classmethod
    def from_json(cls, data: dict) -> "IngressRule":
        """Create from a module.json ingress[] entry."""
        return cls(
            from_peer=str(data.get("from", "")),
            ports=[str(p) for p in data.get("ports", [])],
            protocol=_protocol_from_str(data.get("protocol", "TCP")),
            why=data.get("why", ""),
        )


@dataclass
class EgressRule:
    """An allowed outbound flow (module.json `egress[]`)."""

    to_peer: str  # zone name | 'internet' | module name | 'alias:<name>'
    ports: list[str]
    protocol: Protocol = Protocol.TCP
    why: str = ""

    @classmethod
    def from_json(cls, data: dict) -> "EgressRule":
        """Create from a module.json egress[] entry."""
        return cls(
            to_peer=str(data.get("to", "")),
            ports=[str(p) for p in data.get("ports", [])],
            protocol=_protocol_from_str(data.get("protocol", "TCP")),
            why=data.get("why", ""),
        )


@dataclass
class AliasSpec:
    """A module-local OPNsense alias (module.json `aliases{}`)."""

    name: str
    alias_type: str  # host | network | port | url
    addresses: list[str]
    why: str = ""

    @classmethod
    def from_json(cls, name: str, data: dict) -> "AliasSpec":
        """Create from a module.json aliases{} entry."""
        return cls(
            name=name,
            alias_type=data.get("type", "host"),
            addresses=[str(a) for a in data.get("addresses", [])],
            why=data.get("why", ""),
        )


@dataclass
class ModuleFirewallSpec:
    """The firewall-relevant slice of a module.json file."""

    vmname: str
    zone0: str
    ports: list[PortSpec] = field(default_factory=list)
    ingress: list[IngressRule] = field(default_factory=list)
    egress: list[EgressRule] = field(default_factory=list)
    aliases: dict[str, AliasSpec] = field(default_factory=dict)
    firewall_type: str = "opnsense"

    @classmethod
    def from_json(cls, data: dict, firewall_type: str = "opnsense") -> "ModuleFirewallSpec":
        """Create from a parsed module.json document."""
        return cls(
            vmname=data.get("vmname", ""),
            zone0=data.get("zone0", ""),
            ports=[PortSpec.from_json(p) for p in data.get("ports", [])],
            ingress=[IngressRule.from_json(r) for r in data.get("ingress", [])],
            egress=[EgressRule.from_json(r) for r in data.get("egress", [])],
            aliases={
                name: AliasSpec.from_json(name, adata)
                for name, adata in data.get("aliases", {}).items()
            },
            firewall_type=firewall_type,
        )

    @property
    def has_rules(self) -> bool:
        """True if this module declares any firewall rules."""
        return bool(self.ingress or self.egress)

    @property
    def declared_ports(self) -> set[str]:
        """Set of ports declared in ports[] (for ingress validation)."""
        return {p.port for p in self.ports}


class ValidationError(Exception):
    """Raised when a module's firewall declarations are invalid."""


# =============================================================================
# Helpers
# =============================================================================


def _protocol_from_str(s: str) -> Protocol:
    """Map a JSON protocol string to a Protocol enum."""
    mapping = {
        "any": Protocol.ANY,
        "tcp": Protocol.TCP,
        "udp": Protocol.UDP,
        "tcp/udp": Protocol.TCP_UDP,
        "icmp": Protocol.ICMP,
    }
    return mapping.get(str(s).lower(), Protocol.TCP)


def _stable_slot(vmname: str) -> int:
    """Deterministically map a module name to a 0-99 sequence slot.

    Stable across runs and across machines (no salt, no randomness), so the
    same module always lands in the same band offset. Collisions between two
    modules hashing to the same slot are detected during compilation.
    """
    h = 0
    for ch in vmname:
        h = (h * 31 + ord(ch)) & 0xFFFFFFFF
    return h % SLOT_SIZE


def _is_special_peer(peer: str) -> bool:
    """True for peer references that are not zone names."""
    return peer == "internet" or peer.startswith("alias:")


def _port_value(port: str) -> str | None:
    """Convert a declared port to an OPNsense destination_port value.

    'alias:<name>' references pass through as the bare alias name; an empty
    or 'any' port becomes None (OPNsense treats None as 'any').
    """
    if not port or port == "any":
        return None
    if port.startswith("alias:"):
        return port.split(":", 1)[1]
    return port


# =============================================================================
# Manager
# =============================================================================


class FirewallRulesManager:
    """Orchestrate per-module firewall rules on OPNsense.

    Composes FirewallManager for all raw API work. Reads module.json and
    zones.json to compile high-level ingress/egress declarations into
    OPNsense FirewallRule objects, then applies them atomically with a
    savepoint so a mid-batch failure rolls back cleanly.
    """

    def __init__(
        self,
        config: Config,
        config_dir: str | Path = "/home/tappaas/config",
    ):
        """Initialise the manager.

        Args:
            config: OPNsense connection configuration.
            config_dir: Directory holding module JSONs, zones.json and
                firewall/aliases.json (default: /home/tappaas/config).
        """
        self.config = config
        self.config_dir = Path(config_dir)
        self.zones_file = self.config_dir / "zones.json"
        self.global_aliases_file = self.config_dir / "firewall" / "aliases.json"
        self._firewall: FirewallManager | None = None
        self.zones: dict[str, Zone] = {}

    # -- connection lifecycle (mirrors caddy_manager.py) ----------------------

    def connect(self) -> "FirewallRulesManager":
        """Establish the OPNsense connection via FirewallManager."""
        self._firewall = FirewallManager(self.config).connect()
        return self

    def disconnect(self) -> None:
        """Close the OPNsense connection."""
        if self._firewall:
            self._firewall.disconnect()
        self._firewall = None

    def __enter__(self) -> "FirewallRulesManager":
        return self.connect()

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.disconnect()

    @property
    def firewall(self) -> FirewallManager:
        """Get the active FirewallManager, raising if not connected."""
        if not self._firewall:
            raise RuntimeError("Not connected. Use connect() or context manager.")
        return self._firewall

    def test_connection(self) -> bool:
        """Test the connection to OPNsense."""
        return self.firewall.test_connection()

    # -- loading --------------------------------------------------------------

    def load_zones(self) -> dict[str, Zone]:
        """Load and index zones from zones.json by name."""
        if not self.zones_file.exists():
            raise ValidationError(f"zones.json not found: {self.zones_file}")
        with open(self.zones_file) as fh:
            raw = json.load(fh)
        self.zones = {
            name: Zone.from_json(name, zdata) for name, zdata in raw.items()
        }
        debug(f"Loaded {len(self.zones)} zones from {self.zones_file}")
        return self.zones

    def load_module(self, module_name: str) -> ModuleFirewallSpec:
        """Load a module's firewall declarations from <module>.json."""
        module_json = self.config_dir / f"{module_name}.json"
        if not module_json.exists():
            raise ValidationError(f"Module config not found: {module_json}")
        with open(module_json) as fh:
            raw = json.load(fh)

        # firewallType lives in firewall.json, not in the consumer module.
        firewall_type = "opnsense"
        firewall_json = self.config_dir / "firewall.json"
        if firewall_json.exists():
            with open(firewall_json) as fh:
                firewall_type = json.load(fh).get("firewallType", "opnsense")

        spec = ModuleFirewallSpec.from_json(raw, firewall_type=firewall_type)
        if not spec.vmname:
            spec.vmname = module_name
        return spec

    def load_global_aliases(self) -> dict[str, AliasSpec]:
        """Load the shared alias catalogue from firewall/aliases.json."""
        if not self.global_aliases_file.exists():
            return {}
        with open(self.global_aliases_file) as fh:
            raw = json.load(fh)
        return {
            name: AliasSpec.from_json(name, adata) for name, adata in raw.items()
        }

    # -- validation -----------------------------------------------------------

    def validate_module(self, spec: ModuleFirewallSpec) -> list[str]:
        """Validate a module's firewall declarations.

        Four layers, mirroring issue #151 section 10: zone existence, pinhole
        policy, port consistency, and basic structural checks. Returns a
        list of human-readable error strings (empty list == valid).
        """
        errors: list[str] = []

        if not self.zones:
            self.load_zones()

        # Layer 1: the module's own zone must exist
        if spec.zone0 and spec.zone0 not in self.zones:
            errors.append(
                f"{spec.vmname}: zone0 '{spec.zone0}' not found in zones.json"
            )

        # Layer 2 + 3: ingress -- zone existence, pinhole policy, port consistency
        dest_zone = self.zones.get(spec.zone0)
        for idx, rule in enumerate(spec.ingress):
            peer = rule.from_peer
            if not _is_special_peer(peer) and peer not in self.zones:
                # could still be a module name; modules are resolved later,
                # so only note it -- not a hard error
                debug(
                    f"{spec.vmname}: ingress[{idx}] from '{peer}' is not a "
                    f"zone -- assuming module name, resolved at compile time"
                )
            # pinhole-allowed-from policy
            if dest_zone and peer in self.zones:
                if peer not in dest_zone.pinhole_allowed_from:
                    errors.append(
                        f"{spec.vmname}: ingress[{idx}] from '{peer}' violates "
                        f"policy -- {spec.zone0}.pinhole-allowed-from = "
                        f"{dest_zone.pinhole_allowed_from}"
                    )
            # port consistency: every ingress port must be declared in ports[]
            if spec.declared_ports:
                for port in rule.ports:
                    if port not in spec.declared_ports and not port.startswith("alias:"):
                        errors.append(
                            f"{spec.vmname}: ingress[{idx}] port '{port}' not "
                            f"declared in ports[]"
                        )

        # Layer 2: egress -- zone existence only (egress is explicit by design)
        for idx, rule in enumerate(spec.egress):
            peer = rule.to_peer
            if not _is_special_peer(peer) and peer not in self.zones:
                debug(
                    f"{spec.vmname}: egress[{idx}] to '{peer}' is not a "
                    f"zone -- assuming module name, resolved at compile time"
                )

        return errors

    # -- compilation ----------------------------------------------------------

    def compile_module(self, spec: ModuleFirewallSpec) -> list[FirewallRule]:
        """Compile a module's declarations into OPNsense FirewallRule objects."""
        if not self.zones:
            self.load_zones()

        rules: list[FirewallRule] = []
        slot = _stable_slot(spec.vmname)
        dest_zone = self.zones.get(spec.zone0)
        dest_net = self._resolve_module_destination(spec, dest_zone)

        # Ingress: rules sit on the SOURCE zone's interface, direction IN.
        seq = BAND_INGRESS + slot * SLOT_SIZE
        for rule in spec.ingress:
            src_net = self._resolve_peer(rule.from_peer)
            src_iface = self._resolve_peer_interface(rule.from_peer)
            for port in rule.ports:
                rules.append(
                    FirewallRule(
                        description=self._describe(
                            spec.vmname, "ingress", rule.from_peer, port, rule.protocol
                        ),
                        action=RuleAction.PASS,
                        interface=src_iface,
                        direction=RuleDirection.IN,
                        protocol=rule.protocol,
                        source_net=src_net,
                        destination_net=dest_net,
                        destination_port=_port_value(port),
                        sequence=seq,
                        log=True,
                    )
                )
                seq += 1

        # Egress: rules sit on the MODULE zone's interface, direction IN
        # (traffic leaving the module enters the firewall on zone0's interface).
        seq = BAND_EGRESS + slot * SLOT_SIZE
        src_iface = dest_zone.bridge if dest_zone else "lan"
        for rule in spec.egress:
            dst_net = self._resolve_peer(rule.to_peer)
            for port in rule.ports:
                rules.append(
                    FirewallRule(
                        description=self._describe(
                            spec.vmname, "egress", rule.to_peer, port, rule.protocol
                        ),
                        action=RuleAction.PASS,
                        interface=src_iface,
                        direction=RuleDirection.IN,
                        protocol=rule.protocol,
                        source_net=dest_net,
                        destination_net=dst_net,
                        destination_port=_port_value(port),
                        sequence=seq,
                        log=True,
                    )
                )
                seq += 1

        return rules

    # -- CRUD verbs (CLI-aligned) ---------------------------------------------

    def add_rules(self, module_name: str) -> dict:
        """Compile and apply a module's firewall rules atomically.

        Returns a result summary dict: {module, applied, aliases}.
        """
        spec = self.load_module(module_name)

        if spec.firewall_type == "NONE":
            warn(f"firewallType=NONE -- no automated rules applied for {module_name}")
            return {"module": module_name, "applied": 0, "skipped": "firewallType=NONE"}

        errors = self.validate_module(spec)
        if errors:
            for e in errors:
                error(e)
            raise ValidationError(
                f"{module_name}: {len(errors)} validation error(s) -- aborting"
            )

        # Create module-local aliases first (rules may reference them).
        alias_count = 0
        for alias in spec.aliases.values():
            self.create_alias(alias)
            alias_count += 1

        rules = self.compile_module(spec)
        if not rules:
            info(f"{module_name}: no ingress/egress declared -- nothing to apply")
            return {"module": module_name, "applied": 0, "aliases": alias_count}

        # Atomic apply: savepoint -> batch create -> apply; revert on failure.
        savepoint = self.firewall.create_savepoint()
        revision = savepoint.get("revision") or savepoint.get("result", {}).get("revision")
        try:
            self.firewall.create_multiple_rules(rules, apply=True)
        except Exception as exc:
            if revision:
                warn(f"Apply failed -- reverting to savepoint {revision}")
                self.firewall.revert_changes(revision)
            raise RuntimeError(f"{module_name}: rule apply failed: {exc}") from exc

        info(f"{module_name}: applied {len(rules)} rule(s), {alias_count} alias(es)")
        return {"module": module_name, "applied": len(rules), "aliases": alias_count}

    def reconcile(self, module_name: str) -> dict:
        """Diff desired vs live state, apply changes, prune orphans.

        This is the idempotent convergence verb invoked by update-service.sh.
        Returns {module, applied, deleted}.
        """
        spec = self.load_module(module_name)

        if spec.firewall_type == "NONE":
            warn(f"firewallType=NONE -- skipping reconcile for {module_name}")
            return {"module": module_name, "applied": 0, "deleted": 0}

        errors = self.validate_module(spec)
        if errors:
            for e in errors:
                error(e)
            raise ValidationError(
                f"{module_name}: {len(errors)} validation error(s) -- aborting"
            )

        desired = self.compile_module(spec)
        desired_descriptions = {r.description for r in desired}

        # Live rules owned by this module (substring match on "TAPPaaS: <module>").
        live = self.firewall.list_rules(f"{DESCRIPTION_PREFIX}: {spec.vmname}")
        orphans = [r for r in live if r.description not in desired_descriptions]

        savepoint = self.firewall.create_savepoint()
        revision = savepoint.get("revision") or savepoint.get("result", {}).get("revision")
        try:
            # ensure aliases exist before (re)creating rules
            for alias in spec.aliases.values():
                self.create_alias(alias)
            # upsert desired rules (description match_fields makes this idempotent)
            self.firewall.create_multiple_rules(desired, apply=False)
            # prune rules that are no longer declared
            for orphan in orphans:
                self.firewall.delete_rule_by_uuid(orphan.uuid, apply=False)
            self.firewall.apply_changes()
        except Exception as exc:
            if revision:
                warn(f"Reconcile failed -- reverting to savepoint {revision}")
                self.firewall.revert_changes(revision)
            raise RuntimeError(f"{module_name}: reconcile failed: {exc}") from exc

        info(
            f"{module_name}: reconciled -- {len(desired)} desired, "
            f"{len(orphans)} orphan(s) pruned"
        )
        return {
            "module": module_name,
            "applied": len(desired),
            "deleted": len(orphans),
        }

    def remove_rules(self, module_name: str) -> dict:
        """Remove all rules and module-local aliases owned by a module."""
        # Try to load the spec for alias cleanup; tolerate a missing file.
        aliases: dict[str, AliasSpec] = {}
        vmname = module_name
        try:
            spec = self.load_module(module_name)
            vmname = spec.vmname
            aliases = spec.aliases
            if spec.firewall_type == "NONE":
                warn(f"firewallType=NONE -- manual cleanup required for {module_name}")
                return {"module": module_name, "deleted": 0}
        except ValidationError:
            warn(
                f"{module_name}.json not found -- cleaning up by description prefix only"
            )

        live = self.firewall.list_rules(f"{DESCRIPTION_PREFIX}: {vmname}")
        savepoint = self.firewall.create_savepoint()
        revision = savepoint.get("revision") or savepoint.get("result", {}).get("revision")
        try:
            for rule in live:
                self.firewall.delete_rule_by_uuid(rule.uuid, apply=False)
            self.firewall.apply_changes()
            for alias in aliases.values():
                self.remove_alias(alias.name)
        except Exception as exc:
            if revision:
                warn(f"Removal failed -- reverting to savepoint {revision}")
                self.firewall.revert_changes(revision)
            raise RuntimeError(f"{module_name}: rule removal failed: {exc}") from exc

        info(f"{module_name}: removed {len(live)} rule(s)")
        return {"module": module_name, "deleted": len(live)}

    def list_rules(self, module_name: str | None = None) -> list[FirewallRuleInfo]:
        """List rules created by this manager, optionally filtered by module."""
        search = (
            f"{DESCRIPTION_PREFIX}: {module_name}"
            if module_name
            else f"{DESCRIPTION_PREFIX}: "
        )
        return self.firewall.list_rules(search)

    def verify_rules(self, module_name: str) -> dict:
        """Verify that a module's declared rules exist in OPNsense.

        Returns {module, expected, found, missing}.
        """
        spec = self.load_module(module_name)
        if spec.firewall_type == "NONE":
            return {"module": module_name, "skipped": "firewallType=NONE"}

        desired = self.compile_module(spec)
        desired_descriptions = {r.description for r in desired}
        live_descriptions = {r.description for r in self.list_rules(spec.vmname)}
        missing = sorted(desired_descriptions - live_descriptions)

        return {
            "module": module_name,
            "expected": len(desired_descriptions),
            "found": len(desired_descriptions & live_descriptions),
            "missing": missing,
        }

    # -- alias management -----------------------------------------------------

    def create_alias(self, alias: AliasSpec) -> dict:
        """Create or update an OPNsense alias (idempotent via name match)."""
        return self.firewall.client.run_module(
            "alias",
            params={
                "name": alias.name,
                "type": alias.alias_type,
                "content": alias.addresses,
                "description": f"{DESCRIPTION_PREFIX}: alias {alias.name}",
                "state": "present",
                "match_fields": ["name"],
                "reload": False,
            },
        )

    def remove_alias(self, name: str) -> dict:
        """Remove an OPNsense alias by name."""
        return self.firewall.client.run_module(
            "alias",
            params={
                "name": name,
                "state": "absent",
                "match_fields": ["name"],
                "reload": False,
            },
        )

    # -- internal resolution helpers ------------------------------------------

    def _describe(
        self, vmname: str, direction: str, peer: str, port: str, protocol: Protocol
    ) -> str:
        """Build the canonical, unique rule description.

        Format: "TAPPaaS: <module> [<direction>:<peer>:<port>/<protocol>]"
        Keeps the "TAPPaaS: <module>" prefix (greppable, same as proxy) and
        appends per-rule detail so each rule has a unique key for upsert.
        """
        return (
            f"{DESCRIPTION_PREFIX}: {vmname} "
            f"[{direction}:{peer}:{port}/{protocol.value}]"
        )

    def _resolve_peer(self, peer: str) -> str:
        """Resolve a from/to reference to an OPNsense source/destination value.

        - 'internet'      -> 'any'
        - 'alias:<name>'  -> '<name>'        (OPNsense resolves the alias)
        - zone name       -> the zone's CIDR
        - module name     -> '<module>.<zone>.internal' (resolved via Unbound)
        """
        if peer == "internet":
            return "any"
        if peer.startswith("alias:"):
            return peer.split(":", 1)[1]
        if peer in self.zones:
            return self.zones[peer].ip_network
        # treat as a module name; resolve to its internal FQDN
        module_zone = self._module_zone(peer)
        if module_zone:
            return f"{peer}.{module_zone}.internal"
        warn(f"Could not resolve peer '{peer}' -- falling back to 'any'")
        return "any"

    def _resolve_peer_interface(self, peer: str) -> str:
        """Resolve which OPNsense interface an ingress rule should sit on.

        Ingress rules are placed on the SOURCE zone's interface. For
        'internet' that is the WAN bridge; for a zone it is that zone's
        bridge; for a module it is that module's zone's bridge.
        """
        if peer == "internet":
            return "wan"
        if peer in self.zones:
            return self.zones[peer].bridge
        module_zone = self._module_zone(peer)
        if module_zone and module_zone in self.zones:
            return self.zones[module_zone].bridge
        return "lan"

    def _resolve_module_destination(
        self, spec: ModuleFirewallSpec, dest_zone: Zone | None
    ) -> str:
        """Resolve a module's own address for use as a rule destination/source.

        Uses the module's internal FQDN (<vmname>.<zone>.internal), which
        OPNsense resolves via Unbound to the DHCP-reserved address. This
        avoids hard-coding an IP in module.json (issue #151 F7).
        """
        if dest_zone:
            return f"{spec.vmname}.{dest_zone.name}.internal"
        return f"{spec.vmname}.internal"

    def _module_zone(self, module_name: str) -> str | None:
        """Look up which zone a referenced module lives in (best effort)."""
        module_json = self.config_dir / f"{module_name}.json"
        if not module_json.exists():
            return None
        try:
            with open(module_json) as fh:
                return json.load(fh).get("zone0")
        except (json.JSONDecodeError, OSError):
            return None
