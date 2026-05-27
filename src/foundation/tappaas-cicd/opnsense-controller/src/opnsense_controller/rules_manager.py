#!/usr/bin/env python3
"""TAPPaaS Rules Manager — per-module firewall rules from module.json.

Compiles `ports`, `ingress`, `egress`, and `aliases` from a consuming module's
JSON declaration into OPNsense firewall rules and aliases. Operates as a
TAPPaaS-aware orchestrator on top of the lower-level FirewallManager.

Description-based identity makes apply operations idempotent:
    tappaas-module:<vmname>:<direction>:<peer>:<port>[/<protocol>]

When a peer is another module's name (rather than a zone, 'internet', or an
'alias:<name>' reference), the manager creates and references an OPNsense alias
`tappaas_module_<peer_vmname>` (OPNsense aliases use underscores; any hyphens in
vmname are normalised). The alias content depends on the module's `aliasType`:

  - "host" (default): a host alias of the peer's FQDN `<vmname>.<zone0>.internal`.
    OPNsense's Unbound resolver looks up the FQDN against dnsmasq, so DHCP-driven
    IP changes flow through transparently without rule rewrites.
  - "network": a network alias of the peer's zone0 subnet CIDR (from zones.json).
    Used for modules that represent multiple devices with no single resolvable
    hostname — IoT device fleets, sets of physical appliances (#241).

Rules reference the alias by name, so the same compiled rule works regardless of
the alias's type.

CLI: rules-manager <subcommand> [--module <name>] ...
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Literal

from oxl_opnsense_client import Client

from .config import Config
from .firewall_manager import (
    FirewallManager,
    FirewallRule,
    FirewallRuleInfo,
    IpProtocol,
    Protocol,
    RuleAction,
    RuleDirection,
)
from .log import debug, error, info, warn
from .vlan_manager import VlanManager

# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────

DESCRIPTION_PREFIX = "tappaas-module"
# Auto-pinhole rules synthesised from <consumer>.dependsOn + <provider>/services/<svc>/pinhole.json
# (issue #173). Same shape as manual ingress rules but distinct prefix so the
# reconcile/teardown paths can tell them apart from manually-authored entries.
DESCRIPTION_PREFIX_SVCDEP = "tappaas-svcdep"
# All per-module rule prefixes recognised by remove/list/verify scans.
MODULE_RULE_PREFIXES: tuple[str, ...] = (DESCRIPTION_PREFIX, DESCRIPTION_PREFIX_SVCDEP)
MODULE_ALIAS_PREFIX = "tappaas_module_"
DEFAULT_DOMAIN_SUFFIX = "internal"

BAND_INGRESS_BASE = 10000
BAND_EGRESS_BASE = 20000
SLOT_SIZE = 100        # rules per module per direction
SLOT_COUNT = 100       # number of distinct slots within a band

DEFAULT_MODULES_DIR = Path("/home/tappaas/config")
DEFAULT_ZONES_FILE = Path("/home/tappaas/TAPPaaS/src/foundation/firewall/zones.json")
DEFAULT_GLOBAL_ALIASES_FILE = Path(
    "/home/tappaas/TAPPaaS/src/foundation/firewall/aliases.json"
)
DEFAULT_SEQUENCE_MAP_FILE = Path("/home/tappaas/config/firewall/sequence-map.json")


# ─────────────────────────────────────────────────────────────────────────────
# Dataclasses
# ─────────────────────────────────────────────────────────────────────────────


@dataclass
class ZoneSpec:
    """Minimal zone view used by the rules manager."""

    name: str
    ip_network: str
    bridge: str
    vlan_tag: int
    access_to: list[str]
    pinhole_allowed_from: list[str]


@dataclass
class ModuleSpec:
    """Minimal module view used by the rules manager."""

    vmname: str
    zone0: str
    bridge0: str
    ports: list[dict]
    ingress: list[dict]
    egress: list[dict]
    aliases: dict[str, dict]
    firewall_type: str  # "opnsense" | "NONE"
    # OPNsense alias type for tappaas_module_<vmname>: "host" (FQDN, default) or
    # "network" (zone0 subnet, for multi-device modules with no single FQDN — #241).
    alias_type: str = "host"
    # `dependsOn` and `location` are needed by the auto-pinhole pass (issue #173).
    # `location` is the absolute path of the module directory in the source tree
    # (set by copy-update-json.sh); auto-pinhole reads
    # <provider.location>/services/<service>/pinhole.json for each dependency.
    depends_on: list[str] = field(default_factory=list)
    location: str = ""


@dataclass
class AliasTarget:
    """The OPNsense alias to provision for a tappaas_module_<name> reference.

    `alias_type` is "host" (content = the module FQDN) or "network" (content =
    the module's zone0 subnet CIDR). Rules reference the alias by name, so the
    same rule works regardless of which target the alias resolves to (#241).
    """

    alias_type: str
    content: list[str]
    description: str


@dataclass
class ModuleFirewallRule:
    """A single compiled rule, before delegation to FirewallManager."""

    module_name: str
    direction: Literal["ingress", "egress"]
    peer: str                              # zone | 'internet' | module | 'alias:<n>'
    port: int | str
    protocol: str
    description: str                       # canonical, used as upsert key
    rule_description: str                  # human-readable, recorded in OPNsense
    sequence: int
    source_net: str                        # CIDR | alias-name | 'any'
    destination_net: str                   # CIDR | alias-name | 'any'
    interface: str                         # OPNsense interface identifier


@dataclass
class ValidationError:
    """A compile-time validation failure."""

    module: str
    path: str
    message: str

    def __str__(self) -> str:
        return f"{self.module}: {self.path}: {self.message}"


@dataclass
class ApplyResult:
    """Outcome of add_rules / reconcile."""

    module: str
    applied: int = 0
    deleted: int = 0
    aliases_created: int = 0
    errors: list[ValidationError] = field(default_factory=list)


@dataclass
class RemoveResult:
    """Outcome of remove_rules."""

    module: str
    deleted: int = 0
    aliases_removed: int = 0


@dataclass
class VerifyResult:
    """Outcome of verify_rules."""

    module: str
    desired: int = 0
    present: int = 0
    missing: list[str] = field(default_factory=list)
    extra: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.missing and not self.extra


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────


def stable_hash_index(name: str, count: int = SLOT_COUNT) -> int:
    """Return a deterministic 0..count-1 index for `name`."""
    digest = hashlib.sha256(name.encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big") % count


def _normalize_protocol(value: str | None) -> str:
    if not value:
        return Protocol.TCP.value
    upper = value.upper()
    if upper in {"TCP", "UDP", "ICMP"}:
        return upper
    if upper in {"TCP/UDP", "TCP-UDP", "BOTH"}:
        return Protocol.TCP_UDP.value
    return upper


def _port_to_str(value: int | str) -> str:
    return str(value)


def _canonical_description(
    module: str, direction: str, peer: str, port: int | str, protocol: str
) -> str:
    proto = protocol.upper()
    base = f"{DESCRIPTION_PREFIX}:{module}:{direction}:{peer}:{port}"
    if proto and proto != Protocol.TCP.value:
        base += f"/{proto}"
    return base


def _canonical_description_svcdep(
    consumer: str, service: str, provider: str, port: int | str, protocol: str
) -> str:
    """Canonical description for an auto-pinhole rule (issue #173).

    Format: ``tappaas-svcdep:<consumer>:<service>:<provider>:<port>[/<proto>]``

    The owner-module (position 1, the part `_extract_module` returns) is the
    *consumer* — auto-pinholes are created when a consumer's install runs and
    removed when the consumer is deleted, regardless of provider state.
    """
    proto = protocol.upper()
    base = f"{DESCRIPTION_PREFIX_SVCDEP}:{consumer}:{service}:{provider}:{port}"
    if proto and proto != Protocol.TCP.value:
        base += f"/{proto}"
    return base


def _parse_dependency(dep: str) -> tuple[str, str] | None:
    """Parse a ``"<module>:<service>"`` dependsOn entry; return (module, service) or None."""
    if not dep or ":" not in dep:
        return None
    parts = dep.split(":", 1)
    provider, service = parts[0].strip(), parts[1].strip()
    if not provider or not service:
        return None
    return provider, service


def load_pinhole_ports(provider_location: str, service: str) -> list[dict] | None:
    """Load <provider.location>/services/<service>/pinhole.json (issue #173).

    Returns the list of port specs (``{port, protocol, description}``), or
    ``None`` when the file is absent (which is the normal case for services
    that don't expose network ports, e.g. ``cluster:vm``).
    """
    if not provider_location:
        return None
    path = Path(provider_location) / "services" / service / "pinhole.json"
    if not path.is_file():
        return None
    with open(path) as f:
        data = json.load(f)
    ports = data.get("ports", []) or []
    if not isinstance(ports, list):
        return None
    return ports


def _module_alias_name(peer_vmname: str) -> str:
    """Generate an OPNsense-safe host alias name for a TAPPaaS module.

    OPNsense aliases must match `^[a-zA-Z_][a-zA-Z0-9_]{0,31}$` — only
    alphanumerics and underscores, max 32 chars. We sanitise the vmname by
    replacing any non-alphanumeric character with underscore, then truncate
    the combined name if necessary.
    """
    sanitised = "".join(c if c.isalnum() else "_" for c in peer_vmname)
    name = f"{MODULE_ALIAS_PREFIX}{sanitised}"
    # OPNsense alias name limit is 32 characters
    if len(name) > 32:
        name = name[:32].rstrip("_")
    return name


# ─────────────────────────────────────────────────────────────────────────────
# Loaders
# ─────────────────────────────────────────────────────────────────────────────


def load_zones(path: Path) -> dict[str, ZoneSpec]:
    """Load zones.json into a name→ZoneSpec map."""
    with open(path) as f:
        data = json.load(f)
    result: dict[str, ZoneSpec] = {}
    for name, entry in data.items():
        if not isinstance(entry, dict):
            continue
        result[name] = ZoneSpec(
            name=name,
            ip_network=entry.get("ip", ""),
            bridge=entry.get("bridge", "lan"),
            vlan_tag=int(entry.get("vlantag", 0) or 0),
            access_to=entry.get("access-to", []) or [],
            pinhole_allowed_from=entry.get("pinhole-allowed-from", []) or [],
        )
    return result


def load_module(modules_dir: Path, name: str) -> ModuleSpec:
    """Load <name>.json from the modules config directory."""
    path = modules_dir / f"{name}.json"
    if not path.is_file():
        raise FileNotFoundError(f"module config not found: {path}")
    with open(path) as f:
        data = json.load(f)
    return ModuleSpec(
        vmname=data.get("vmname", name),
        zone0=data.get("zone0", ""),
        bridge0=data.get("bridge0", "lan"),
        ports=data.get("ports", []) or [],
        ingress=data.get("ingress", []) or [],
        egress=data.get("egress", []) or [],
        aliases=data.get("aliases", {}) or {},
        firewall_type=data.get("firewallType", "opnsense"),
        alias_type=data.get("aliasType", "host") or "host",
        depends_on=data.get("dependsOn", []) or [],
        location=data.get("location", "") or "",
    )


def load_global_aliases(path: Path | None) -> dict[str, dict]:
    """Load firewall/aliases.json; returns {} if file missing."""
    if path is None or not path.is_file():
        return {}
    with open(path) as f:
        data = json.load(f)
    return {k: v for k, v in data.items() if isinstance(v, dict) and "type" in v}


def discover_modules(modules_dir: Path) -> list[str]:
    """Yield module names from <modules_dir>/*.json (excluding non-module configs)."""
    skip = {"configuration", "firewall", "zones", "aliases", "sequence-map"}
    return sorted(
        p.stem for p in modules_dir.glob("*.json") if p.stem not in skip
    )


# ─────────────────────────────────────────────────────────────────────────────
# RulesManager
# ─────────────────────────────────────────────────────────────────────────────


class RulesManager:
    """Orchestrate per-module firewall rules from module.json declarations."""

    def __init__(
        self,
        config: Config,
        zones: dict[str, ZoneSpec],
        modules_dir: Path = DEFAULT_MODULES_DIR,
        global_aliases: dict[str, dict] | None = None,
        sequence_map_file: Path | None = DEFAULT_SEQUENCE_MAP_FILE,
        check_mode: bool = False,
        firewall_type: str = "opnsense",
    ):
        self.config = config
        self.zones = zones
        self.modules_dir = modules_dir
        self.global_aliases = global_aliases or {}
        self.sequence_map_file = sequence_map_file
        self.check_mode = check_mode
        self.firewall_type = firewall_type.upper() if firewall_type else "OPNSENSE"
        self._fw: FirewallManager | None = None
        self._client: Client | None = None
        # Cache: peer-module spec lookup for alias targets (avoids re-reading JSON)
        self._peer_module_cache: dict[str, ModuleSpec | None] = {}
        # Cache: VLAN-tag → OPNsense interface identifier (lazy-loaded at first use)
        self._vlan_iface_cache: dict[int, str] | None = None

    @property
    def is_none_mode(self) -> bool:
        """True when firewallType is NONE — no OPNsense connection is used."""
        return self.firewall_type == "NONE"

    # ── Connection management ────────────────────────────────────────────

    def connect(self) -> "RulesManager":
        if self.is_none_mode:
            return self
        self._fw = FirewallManager(self.config).connect()
        self._client = self._fw.client
        return self

    def disconnect(self) -> None:
        if self._fw:
            self._fw.disconnect()
        self._fw = None
        self._client = None

    def __enter__(self) -> "RulesManager":
        return self.connect()

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        self.disconnect()

    @property
    def fw(self) -> FirewallManager:
        if not self._fw:
            raise RuntimeError("Not connected. Use connect() or context manager.")
        return self._fw

    # ── Public verbs (CLI-aligned) ───────────────────────────────────────

    def add_rules(self, module_name: str) -> ApplyResult:
        """Compile and apply rules for a single module."""
        return self._apply(module_name, prune=False)

    def reconcile(self, module_name: str) -> ApplyResult:
        """Compile, apply, and delete orphan rules for a single module."""
        return self._apply(module_name, prune=True)

    def remove_rules(self, module_name: str) -> RemoveResult:
        """Remove every rule and module-local alias owned by `module_name`."""
        module = load_module(self.modules_dir, module_name)
        result = RemoveResult(module=module.vmname)

        if self.is_none_mode:
            info(f"firewallType=NONE for {module.vmname}: nothing to remove on firewall")
            return result

        # Pick up both manual rules (tappaas-module:...) and auto-pinholes
        # (tappaas-svcdep:...) owned by this module.
        existing = self._list_owned_rules(module.vmname)
        if self.check_mode:
            info(f"[check] would delete {len(existing)} rule(s) for {module.vmname}")
            return result

        owned_prefixes = tuple(
            f"{p}:{module.vmname}:" for p in MODULE_RULE_PREFIXES
        )
        revision = self.fw.create_savepoint()
        try:
            for rule in existing:
                if rule.description.startswith(owned_prefixes):
                    self.fw.delete_rule_by_uuid(rule.uuid, apply=False)
                    result.deleted += 1
            self.fw.apply_changes()
        except Exception:
            self._revert(revision)
            raise

        # Remove module-local aliases (created in OPNsense by this module's rules).
        for alias_name in module.aliases.keys():
            if self._delete_alias(alias_name):
                result.aliases_removed += 1

        # Remove the FQDN alias for this module if no other module's rules still
        # reference it (refcount via description-prefix scan).
        own_alias = _module_alias_name(module.vmname)
        if self._alias_is_orphan(own_alias, exclude_module=module.vmname):
            if self._delete_alias(own_alias):
                result.aliases_removed += 1

        # Also drop any peer-module aliases this module's rules created if no
        # remaining module references them.
        for peer_alias in self._peer_module_aliases_for(module):
            if self._alias_is_orphan(peer_alias, exclude_module=module.vmname):
                if self._delete_alias(peer_alias):
                    result.aliases_removed += 1

        return result

    def list_rules(
        self, module_name: str | None = None, orphans: bool = False
    ) -> list[FirewallRuleInfo]:
        """List rules currently in OPNsense, optionally filtered.

        Covers both manual rules (``tappaas-module:``) and auto-pinholes
        (``tappaas-svcdep:``).
        """
        if module_name:
            return self._list_owned_rules(module_name)
        rules: list[FirewallRuleInfo] = []
        seen: set[str] = set()
        for prefix in MODULE_RULE_PREFIXES:
            for r in self.fw.list_rules(search_pattern=f"{prefix}:"):
                key = getattr(r, "uuid", None) or r.description
                if key in seen:
                    continue
                seen.add(key)
                rules.append(r)
        if not orphans:
            return rules
        known = set(discover_modules(self.modules_dir))
        return [r for r in rules if _extract_module(r.description) not in known]

    def _list_owned_rules(self, module_name: str) -> list[FirewallRuleInfo]:
        """Return every rule (manual + auto-pinhole) owned by ``module_name``."""
        rules: list[FirewallRuleInfo] = []
        seen: set[str] = set()
        for prefix in MODULE_RULE_PREFIXES:
            for r in self.fw.list_rules(
                search_pattern=f"{prefix}:{module_name}:"
            ):
                key = getattr(r, "uuid", None) or r.description
                if key in seen:
                    continue
                seen.add(key)
                rules.append(r)
        return rules

    def verify_rules(self, module_name: str, deep: bool = False) -> VerifyResult:
        """Verify that desired rules exist in OPNsense."""
        module = load_module(self.modules_dir, module_name)
        result = VerifyResult(module=module.vmname)
        if self.is_none_mode:
            info(f"firewallType=NONE for {module.vmname}: skipping verify")
            return result

        desired, errors = self._compile(module)
        if errors:
            for e in errors:
                error(str(e))
            return result

        result.desired = len(desired)
        desired_descs = {r.description for r in desired}
        existing = self._list_owned_rules(module.vmname)
        # Strip the " | <freetext>" suffix _to_firewall_rule stored, so a live
        # rule matches its compiled canonical description (#246).
        existing_descs = {_canonical_part(r.description) for r in existing}

        result.present = len(existing_descs & desired_descs)
        result.missing = sorted(desired_descs - existing_descs)
        result.extra = sorted(existing_descs - desired_descs)

        if deep:
            debug("--deep connectivity probing is not yet implemented")
        return result

    def create_alias(
        self, name: str, alias_type: str, addresses: list[str], description: str = ""
    ) -> None:
        """Create or update an OPNsense alias."""
        self._upsert_alias(name, alias_type, addresses, description)

    def remove_alias(self, name: str) -> bool:
        """Delete an OPNsense alias by name."""
        return self._delete_alias(name)

    # ── Apply pipeline ───────────────────────────────────────────────────

    def _apply(self, module_name: str, prune: bool) -> ApplyResult:
        module = load_module(self.modules_dir, module_name)
        result = ApplyResult(module=module.vmname)

        if self.is_none_mode:
            self._emit_manual_instructions(module)
            return result

        rules, errors = self._compile(module)
        if errors:
            for e in errors:
                error(str(e))
            result.errors = errors
            return result

        if self.check_mode:
            for r in rules:
                info(f"[check] +rule seq={r.sequence} desc='{r.description}'")
            if prune:
                live = self._list_owned_rules(module.vmname)
                desired_descs = {r.description for r in rules}
                for live_rule in live:
                    if _canonical_part(live_rule.description) not in desired_descs:
                        info(f"[check] -rule desc='{live_rule.description}'")
            return result

        # 1. Ensure aliases exist in OPNsense before any rule references them:
        #    a) module-local aliases declared in module.aliases
        #    b) peer-module FQDN aliases (tappaas_module_<peer>)
        #    c) global aliases from firewall/aliases.json that are referenced
        #       via "alias:<name>" in this module's ingress/egress
        for alias_name, alias_def in module.aliases.items():
            self._upsert_alias(
                alias_name,
                alias_def.get("type", "host"),
                alias_def.get("addresses", []),
                alias_def.get("description", ""),
            )
            result.aliases_created += 1
        for alias_name, target in self._module_aliases_to_provision(module).items():
            self._upsert_alias(
                alias_name,
                target.alias_type,
                target.content,
                target.description,
            )
            result.aliases_created += 1
        for global_name in self._referenced_global_aliases(module):
            alias_def = self.global_aliases[global_name]
            self._upsert_alias(
                global_name,
                alias_def.get("type", "host"),
                alias_def.get("addresses", []),
                alias_def.get("description", ""),
            )
            result.aliases_created += 1

        # 2. Apply rules atomically with a savepoint
        revision = self.fw.create_savepoint()
        try:
            existing = self._list_owned_rules(module.vmname) if prune else []
            desired_descs = {r.description for r in rules}

            for r in rules:
                self.fw.create_rule(self._to_firewall_rule(r), apply=False)
                result.applied += 1

            if prune:
                for live_rule in existing:
                    # Compare on canonical identity — the live description carries
                    # a " | <freetext>" suffix the desired set doesn't (#246).
                    if _canonical_part(live_rule.description) not in desired_descs:
                        self.fw.delete_rule_by_uuid(live_rule.uuid, apply=False)
                        result.deleted += 1

            self.fw.apply_changes()
        except Exception:
            self._revert(revision)
            raise

        self._write_sequence_map(module, rules)
        return result

    # ── Compilation ──────────────────────────────────────────────────────

    def _compile(self, module: ModuleSpec) -> tuple[list[ModuleFirewallRule], list[ValidationError]]:
        errors = self._validate(module)
        if errors:
            return [], errors

        rules: list[ModuleFirewallRule] = []
        slot = stable_hash_index(module.vmname)

        for idx, entry in enumerate(module.ingress):
            peer = entry["from"]
            protocol = _normalize_protocol(entry.get("protocol"))
            desc_human = entry["description"]
            interface = self._ingress_interface(peer)
            src_net = self._resolve_peer_net(peer, module=module)
            dst_net = self._resolve_self(module)

            for port_idx, port in enumerate(entry["ports"]):
                seq = self._assign_sequence("ingress", slot, len(rules))
                if seq is None:
                    errors.append(
                        ValidationError(
                            module.vmname,
                            f"ingress[{idx}]",
                            "module slot exhausted (>100 rules in band)",
                        )
                    )
                    continue
                rules.append(
                    ModuleFirewallRule(
                        module_name=module.vmname,
                        direction="ingress",
                        peer=peer,
                        port=port,
                        protocol=protocol,
                        description=_canonical_description(
                            module.vmname, "ingress", peer, port, protocol
                        ),
                        rule_description=desc_human,
                        sequence=seq,
                        source_net=src_net,
                        destination_net=dst_net,
                        interface=interface,
                    )
                )

        for idx, entry in enumerate(module.egress):
            peer = entry["to"]
            protocol = _normalize_protocol(entry.get("protocol"))
            desc_human = entry["description"]
            interface = self._egress_interface(module)
            src_net = self._resolve_self(module)
            dst_net = self._resolve_peer_net(peer, module=module)

            for port in entry["ports"]:
                seq = self._assign_sequence("egress", slot, sum(
                    1 for r in rules if r.direction == "egress"
                ))
                if seq is None:
                    errors.append(
                        ValidationError(
                            module.vmname,
                            f"egress[{idx}]",
                            "module slot exhausted (>100 rules in band)",
                        )
                    )
                    continue
                rules.append(
                    ModuleFirewallRule(
                        module_name=module.vmname,
                        direction="egress",
                        peer=peer,
                        port=port,
                        protocol=protocol,
                        description=_canonical_description(
                            module.vmname, "egress", peer, port, protocol
                        ),
                        rule_description=desc_human,
                        sequence=seq,
                        source_net=src_net,
                        destination_net=dst_net,
                        interface=interface,
                    )
                )

        # Auto-pinholes from dependsOn + provider's pinhole.json (issue #173).
        # Auto-pinholes are ingress-shaped rules; they share the consumer's
        # ingress slot, so seed the sequence allocator with the count of
        # manual ingress rules already compiled.
        manual_ingress_count = sum(1 for r in rules if r.direction == "ingress")
        rules.extend(self._compile_auto_pinholes(module, slot, manual_ingress_count))

        return rules, errors

    def _compile_auto_pinholes(
        self,
        module: ModuleSpec,
        slot: int,
        ingress_count_so_far: int,
    ) -> list[ModuleFirewallRule]:
        """Synthesise ingress pinhole rules from cross-zone service dependencies.

        For each ``<provider>:<service>`` in ``module.dependsOn`` where the
        provider ships a ``services/<service>/pinhole.json``: if the consumer's
        zone differs from the provider's zone AND the consumer's zone is not
        already in ``provider_zone.access-to``, emit one pinhole rule per port.

        Auto-pinholes share the consumer's ingress slot (band 3); the
        ``ingress_count_so_far`` argument is the number of manual ingress rules
        already compiled, so sequence numbers continue without collision.

        Policy: when the consumer's zone is missing from the provider zone's
        ``pinhole-allowed-from``, the pinhole is skipped with a warning
        (per #173 design choice — warn-and-skip rather than hard-error).
        """
        rules: list[ModuleFirewallRule] = []
        if not module.depends_on:
            return rules

        consumer_zone = self.zones.get(module.zone0)
        if not consumer_zone:
            return rules
        # Same convention as manual ingress: rules permitting "A -> B" sit on
        # A's zone interface (where the traffic enters the firewall).
        interface = self._zone_to_interface(consumer_zone)
        consumer_self_alias = _module_alias_name(module.vmname)

        for dep in module.depends_on:
            parsed = _parse_dependency(dep)
            if not parsed:
                continue
            provider_name, service = parsed

            # Load the provider's manifest. If it's missing, install-module.sh
            # has already failed validation upstream — skip silently here.
            try:
                provider = load_module(self.modules_dir, provider_name)
            except FileNotFoundError:
                continue

            # Most services don't expose network ports (e.g. cluster:vm).
            # No pinhole.json -> nothing to do.
            port_specs = load_pinhole_ports(provider.location, service)
            if not port_specs:
                continue

            # Intra-zone traffic already flows freely.
            if module.zone0 == provider.zone0:
                continue

            provider_zone = self.zones.get(provider.zone0)
            if not provider_zone:
                continue

            # Zone-level access-to already covers it.
            if module.zone0 in provider_zone.access_to:
                continue

            # Policy gate.
            if module.zone0 not in provider_zone.pinhole_allowed_from:
                warn(
                    f"{module.vmname}: dependsOn '{dep}' would need a pinhole "
                    f"from zone '{module.zone0}' into '{provider.zone0}', but "
                    f"'{module.zone0}' is not in "
                    f"{provider.zone0}.pinhole-allowed-from = "
                    f"{provider_zone.pinhole_allowed_from}. "
                    f"Auto-pinhole skipped; add '{module.zone0}' to "
                    f"{provider.zone0}.pinhole-allowed-from in zones.json "
                    f"to enable it."
                )
                continue

            dst_alias = _module_alias_name(provider.vmname)

            for spec in port_specs:
                port = spec.get("port")
                if port is None:
                    continue
                protocol = _normalize_protocol(spec.get("protocol"))
                human_desc = (
                    spec.get("description")
                    or f"auto-pinhole: {module.vmname} -> {provider.vmname}:{service}"
                )

                seq = self._assign_sequence("ingress", slot, ingress_count_so_far)
                if seq is None:
                    warn(
                        f"{module.vmname}: ingress slot exhausted; "
                        f"auto-pinhole for {dep}:{port} skipped"
                    )
                    continue
                ingress_count_so_far += 1

                rules.append(
                    ModuleFirewallRule(
                        module_name=module.vmname,
                        direction="ingress",
                        peer=provider.vmname,
                        port=port,
                        protocol=protocol,
                        description=_canonical_description_svcdep(
                            module.vmname, service, provider.vmname, port, protocol
                        ),
                        rule_description=human_desc,
                        sequence=seq,
                        source_net=consumer_self_alias,
                        destination_net=dst_alias,
                        interface=interface,
                    )
                )

        return rules

    # ── Validation ───────────────────────────────────────────────────────

    def _validate(self, module: ModuleSpec) -> list[ValidationError]:
        errors: list[ValidationError] = []
        declared_ports = {str(p.get("port")) for p in module.ports}

        # aliasType must be a recognised value, and "network" needs a zone0 subnet
        # to derive the alias content from (#241).
        if module.alias_type not in ("host", "network"):
            errors.append(
                ValidationError(
                    module.vmname,
                    "aliasType",
                    f"must be 'host' or 'network', got '{module.alias_type}'",
                )
            )
        elif module.alias_type == "network":
            subnet = self.zones[module.zone0].ip_network if module.zone0 in self.zones else ""
            if not subnet:
                errors.append(
                    ValidationError(
                        module.vmname,
                        "aliasType",
                        f"aliasType 'network' requires zone0 '{module.zone0}' to "
                        f"define a subnet ('ip') in zones.json",
                    )
                )

        # Module-local aliases must declare type+addresses+description
        for name, alias in module.aliases.items():
            if not isinstance(alias, dict):
                errors.append(
                    ValidationError(module.vmname, f"aliases.{name}", "must be an object")
                )
                continue
            for field_name in ("type", "addresses", "description"):
                if field_name not in alias:
                    errors.append(
                        ValidationError(
                            module.vmname,
                            f"aliases.{name}",
                            f"missing required field '{field_name}'",
                        )
                    )
            if name in self.global_aliases:
                warn(
                    f"{module.vmname}: alias '{name}' shadows a global alias from "
                    f"firewall/aliases.json (module-local takes precedence)"
                )

        # Ingress validation
        dest_zone = self.zones.get(module.zone0)
        for idx, entry in enumerate(module.ingress):
            path = f"ingress[{idx}]"
            for required in ("from", "ports", "description"):
                if required not in entry:
                    errors.append(
                        ValidationError(module.vmname, path, f"missing '{required}'")
                    )
            if "from" not in entry or "ports" not in entry:
                continue
            peer = entry["from"]
            self._validate_peer(peer, module, path + ".from", errors)
            # Policy: ingress.from must be in dest_zone.pinhole-allowed-from
            if dest_zone and peer in self.zones:
                if peer not in dest_zone.pinhole_allowed_from:
                    errors.append(
                        ValidationError(
                            module.vmname,
                            f"{path}.from",
                            f"'{peer}' violates policy — "
                            f"{module.zone0}.pinhole-allowed-from = "
                            f"{dest_zone.pinhole_allowed_from}. "
                            f"Add '{peer}' to {module.zone0}.pinhole-allowed-from "
                            f"in zones.json, or remove this entry.",
                        )
                    )
            # Port consistency: every ingress.ports must be in module.ports[]
            if declared_ports:
                for port in entry.get("ports", []):
                    if str(port) not in declared_ports:
                        errors.append(
                            ValidationError(
                                module.vmname,
                                f"{path}.ports",
                                f"port {port} not declared in module.ports[]",
                            )
                        )

        # Egress validation
        source_zone = self.zones.get(module.zone0)
        for idx, entry in enumerate(module.egress):
            path = f"egress[{idx}]"
            for required in ("to", "ports", "description"):
                if required not in entry:
                    errors.append(
                        ValidationError(module.vmname, path, f"missing '{required}'")
                    )
            if "to" not in entry:
                continue
            peer = entry["to"]
            self._validate_peer(peer, module, path + ".to", errors)
            # Warning (not error): egress to a zone not in access-to
            if source_zone and peer in self.zones:
                if peer not in source_zone.access_to:
                    warn(
                        f"{module.vmname}: egress to '{peer}' not in "
                        f"{module.zone0}.access-to (intentional exception?)"
                    )

        return errors

    def _validate_peer(
        self,
        peer: str,
        module: ModuleSpec,
        path: str,
        errors: list[ValidationError],
    ) -> None:
        if peer == "internet":
            return
        if peer.startswith("alias:"):
            name = peer[len("alias:") :]
            if name not in module.aliases and name not in self.global_aliases:
                errors.append(
                    ValidationError(
                        module.vmname,
                        path,
                        f"alias '{name}' not found in module.aliases or "
                        f"firewall/aliases.json",
                    )
                )
            return
        if peer in self.zones:
            return
        # Treat as module name — peer module must exist on disk
        peer_path = self.modules_dir / f"{peer}.json"
        if not peer_path.is_file():
            errors.append(
                ValidationError(
                    module.vmname,
                    path,
                    f"'{peer}' is not a known zone, alias, or module on disk "
                    f"(expected {peer_path})",
                )
            )

    # ── Peer & interface resolution ──────────────────────────────────────

    def _resolve_peer_net(self, peer: str, module: ModuleSpec) -> str:
        """Resolve a peer reference to a source/destination_net value."""
        if peer == "internet":
            return "any"
        if peer.startswith("alias:"):
            return peer[len("alias:") :]
        if peer in self.zones:
            return self.zones[peer].ip_network or "any"
        # Module-named peer: ensure FQDN alias exists, reference by alias name.
        return _module_alias_name(peer)

    def _resolve_self(self, module: ModuleSpec) -> str:
        """Resolve self (the module itself) for rules destined to/from this module."""
        return _module_alias_name(module.vmname)

    def _module_aliases_to_provision(self, module: ModuleSpec) -> dict[str, AliasTarget]:
        """Return {alias_name: AliasTarget} for the module itself and every peer.

        Walks manual ingress/egress entries plus auto-pinhole providers
        (issue #173) so that every alias referenced by a compiled rule has a
        corresponding OPNsense alias before the rule is applied. Each target is
        a "host" alias (the module FQDN) or, when the module declares
        ``aliasType: network``, a "network" alias of its zone0 subnet (#241).
        """
        result: dict[str, AliasTarget] = {}
        # Self alias — destination for ingress, source for egress (and for
        # auto-pinhole rules, which use the self alias as the source).
        self_target = self._alias_target_for(
            module.vmname, module.zone0, module.alias_type
        )
        if self_target:
            result[_module_alias_name(module.vmname)] = self_target
        # Peer aliases (module-name peers in ingress.from and egress.to)
        peers: list[str] = []
        for entry in module.ingress:
            peers.append(entry.get("from"))
        for entry in module.egress:
            peers.append(entry.get("to"))
        # Auto-pinhole peers: every provider whose pinhole.json would emit a
        # cross-zone rule. We re-derive the same predicate the compile step
        # uses (cross-zone, not covered by zone access-to, and policy-allowed).
        peers.extend(self._auto_pinhole_provider_names(module))
        for peer in peers:
            if not peer or peer == "internet" or peer.startswith("alias:") or peer in self.zones:
                continue
            target = self._peer_alias_target(peer)
            if target:
                result[_module_alias_name(peer)] = target
        return result

    def _referenced_global_aliases(self, module: ModuleSpec) -> list[str]:
        """Return the names of global aliases referenced by this module's rules.

        A rule entry `from: "alias:foo"` or `to: "alias:foo"` references alias
        `foo`. Module-local aliases override globals (per design), so this only
        includes names that are in `self.global_aliases` AND NOT in
        `module.aliases`. The caller upserts these into OPNsense before applying
        any rule that depends on them.
        """
        names: set[str] = set()
        for entry in (*module.ingress, *module.egress):
            peer = entry.get("from") or entry.get("to") or ""
            if peer.startswith("alias:"):
                alias_name = peer[len("alias:") :]
                if alias_name in self.global_aliases and alias_name not in module.aliases:
                    names.add(alias_name)
        return sorted(names)

    def _peer_module_aliases_for(self, module: ModuleSpec) -> list[str]:
        """Return the list of peer-module alias names referenced by `module`.

        Includes peers from auto-pinhole rules (issue #173) so removal also
        considers them for orphan checking.
        """
        names: list[str] = []
        for entry in (*module.ingress, *module.egress):
            peer = entry.get("from") or entry.get("to")
            if peer and peer != "internet" and not peer.startswith("alias:") and peer not in self.zones:
                names.append(_module_alias_name(peer))
        for provider_name in self._auto_pinhole_provider_names(module):
            names.append(_module_alias_name(provider_name))
        return names

    def _auto_pinhole_provider_names(self, module: ModuleSpec) -> list[str]:
        """Return providers whose dependsOn entry would emit an auto-pinhole.

        Applies the same predicate as ``_compile_auto_pinholes`` (cross-zone,
        not already in ``access-to``, in ``pinhole-allowed-from``, pinhole.json
        present) so callers — alias provisioning, orphan checks — see the
        same peer set the compile pass sees.
        """
        if not module.depends_on:
            return []
        names: list[str] = []
        for dep in module.depends_on:
            parsed = _parse_dependency(dep)
            if not parsed:
                continue
            provider_name, service = parsed
            try:
                provider = load_module(self.modules_dir, provider_name)
            except FileNotFoundError:
                continue
            if not load_pinhole_ports(provider.location, service):
                continue
            if module.zone0 == provider.zone0:
                continue
            provider_zone = self.zones.get(provider.zone0)
            if not provider_zone:
                continue
            if module.zone0 in provider_zone.access_to:
                continue
            if module.zone0 not in provider_zone.pinhole_allowed_from:
                continue
            names.append(provider.vmname)
        return names

    def _alias_target_for(
        self, vmname: str, zone0: str, alias_type: str
    ) -> AliasTarget | None:
        """Build the AliasTarget for tappaas_module_<vmname> from its alias type.

        "host" → the module FQDN (resolved via Unbound/dnsmasq). "network" →
        the zone0 subnet CIDR from zones.json, for multi-device modules with no
        single resolvable hostname (#241). Returns None if the module has no
        zone0 (host) or its zone0 has no subnet (network) — the caller / the
        validation pass surfaces that.
        """
        if not zone0:
            return None
        if alias_type == "network":
            subnet = self.zones[zone0].ip_network if zone0 in self.zones else ""
            if not subnet:
                return None
            return AliasTarget(
                "network",
                [subnet],
                f"Network alias for module '{vmname}' (zone '{zone0}' subnet) "
                f"— multi-device module, no single FQDN",
            )
        fqdn = f"{vmname}.{zone0}.{DEFAULT_DOMAIN_SUFFIX}"
        return AliasTarget(
            "host",
            [fqdn],
            f"FQDN alias for module '{vmname}' (DHCP IP resolved via Unbound/dnsmasq)",
        )

    def _peer_alias_target(self, peer_vmname: str) -> AliasTarget | None:
        """Resolve a peer module's AliasTarget by reading its module.json.

        Honors the peer's own ``aliasType`` so a module that references e.g. a
        multi-device peer gets a network alias just like the peer's self alias.
        """
        peer_module = self._load_peer_cached(peer_vmname)
        if peer_module is None:
            return None
        return self._alias_target_for(
            peer_module.vmname, peer_module.zone0, peer_module.alias_type
        )

    def _load_peer_cached(self, peer_vmname: str) -> ModuleSpec | None:
        """Load (and cache) a peer module spec; None if its JSON is missing."""
        if peer_vmname in self._peer_module_cache:
            return self._peer_module_cache[peer_vmname]
        try:
            peer_module: ModuleSpec | None = load_module(self.modules_dir, peer_vmname)
        except FileNotFoundError:
            peer_module = None
        self._peer_module_cache[peer_vmname] = peer_module
        return peer_module

    def _ingress_interface(self, peer: str) -> str:
        """Return the OPNsense interface a rule for inbound traffic from `peer` lives on."""
        if peer == "internet":
            return "wan"
        if peer.startswith("alias:"):
            # Aliases may span interfaces; use a floating rule keyed on LAN.
            return "lan"
        if peer in self.zones:
            return self._zone_to_interface(self.zones[peer])
        # Module-named peer — resolve to that module's zone interface.
        try:
            peer_module = load_module(self.modules_dir, peer)
        except FileNotFoundError:
            return "lan"
        peer_zone = self.zones.get(peer_module.zone0)
        return self._zone_to_interface(peer_zone) if peer_zone else "lan"

    def _egress_interface(self, module: ModuleSpec) -> str:
        """Egress rules sit on the source module's zone interface."""
        zone = self.zones.get(module.zone0)
        if zone:
            return self._zone_to_interface(zone)
        return module.bridge0 or "lan"

    def _zone_to_interface(self, zone: ZoneSpec) -> str:
        """Map a zone to its OPNsense interface identifier.

        VLAN zones: queries OPNsense for the actual interface ID (opt1, opt5, ...)
        assigned to the zone's VLAN tag. zone-manager assigns VLAN interfaces
        with description = zone name, but the OPNsense rule API requires the
        underlying identifier (opt<n>), not the description.

        Non-VLAN zones: the bridge name (lan/wan).

        Falls back to the bridge name if the VLAN→interface lookup fails (the
        rule API will then reject with a clear error, surfacing the mismatch).
        """
        if zone.vlan_tag > 0:
            iface = self._vlan_interface_for_tag(zone.vlan_tag)
            if iface:
                return iface
            warn(
                f"Zone '{zone.name}' (VLAN {zone.vlan_tag}) is not assigned to "
                f"any OPNsense interface — falling back to bridge '{zone.bridge}'"
            )
        return zone.bridge.lower()

    def _vlan_interface_for_tag(self, vlan_tag: int) -> str | None:
        """Look up the OPNsense interface identifier (e.g. 'opt5') for a VLAN tag."""
        if self._vlan_iface_cache is None:
            self._vlan_iface_cache = {}
            if not self.is_none_mode:
                try:
                    with VlanManager(self.config) as vlan_mgr:
                        for v in vlan_mgr.get_assigned_vlans():
                            tag_str = str(v.get("vlan_tag", ""))
                            ident = v.get("identifier")
                            if tag_str and ident:
                                try:
                                    self._vlan_iface_cache[int(tag_str)] = ident
                                except ValueError:
                                    continue
                except Exception as exc:
                    warn(f"Could not load VLAN→interface map from OPNsense: {exc}")
        return self._vlan_iface_cache.get(vlan_tag)

    # ── Sequence allocation ──────────────────────────────────────────────

    def _assign_sequence(
        self, direction: str, slot: int, rule_index: int
    ) -> int | None:
        """Assign a sequence number; return None if the slot is exhausted."""
        if rule_index >= SLOT_SIZE:
            return None
        base = BAND_INGRESS_BASE if direction == "ingress" else BAND_EGRESS_BASE
        return base + slot * SLOT_SIZE + rule_index

    # ── OPNsense delegations ─────────────────────────────────────────────

    def _to_firewall_rule(self, r: ModuleFirewallRule) -> FirewallRule:
        protocol = Protocol(r.protocol) if r.protocol in [p.value for p in Protocol] else Protocol.TCP
        rule_desc = f"{r.description} | {r.rule_description}" if r.rule_description else r.description
        port_str = _port_to_str(r.port)
        return FirewallRule(
            description=rule_desc,
            action=RuleAction.PASS,
            interface=r.interface,
            direction=RuleDirection.IN,
            ip_protocol=IpProtocol.IPV4,
            protocol=protocol,
            source_net=r.source_net,
            destination_net=r.destination_net,
            destination_port=port_str,
            log=True,
            quick=True,
            enabled=True,
            sequence=r.sequence,
        )

    def _upsert_alias(
        self, name: str, alias_type: str, addresses: list[str], description: str
    ) -> None:
        """Create or update an OPNsense alias (idempotent — matched by name)."""
        if self.check_mode:
            info(f"[check] +alias {name} ({alias_type}) → {addresses}")
            return
        params = {
            "name": name,
            "type": alias_type,
            "content": list(addresses),
            "description": description,
            "state": "present",
            "reload": False,
        }
        self.fw.client.run_module("alias", params=params)

    def _delete_alias(self, name: str) -> bool:
        if self.check_mode:
            info(f"[check] -alias {name}")
            return True
        try:
            self.fw.client.run_module(
                "alias",
                params={"name": name, "state": "absent", "reload": False},
            )
            return True
        except Exception as exc:
            warn(f"Failed to remove alias '{name}': {exc}")
            return False

    def _alias_is_orphan(self, alias_name: str, exclude_module: str) -> bool:
        """Return True if no rule outside `exclude_module` references `alias_name`.

        Scans both manual rules (``tappaas-module:``) and auto-pinholes
        (``tappaas-svcdep:``).
        """
        exclude_prefixes = tuple(
            f"{p}:{exclude_module}:" for p in MODULE_RULE_PREFIXES
        )
        seen: set[str] = set()
        for prefix in MODULE_RULE_PREFIXES:
            for r in self.fw.list_rules(search_pattern=f"{prefix}:"):
                key = getattr(r, "uuid", None) or r.description
                if key in seen:
                    continue
                seen.add(key)
                if r.description.startswith(exclude_prefixes):
                    continue
                if alias_name in (r.source_net or "") or alias_name in (r.destination_net or ""):
                    return False
        return True

    def _revert(self, revision) -> None:
        # create_savepoint() returns {"result": {"response": {"revision": "..."}}}
        rev_id = ""
        if isinstance(revision, dict):
            rev_id = (
                revision.get("result", {}).get("response", {}).get("revision")
                or revision.get("revision")
                or ""
            )
        if not rev_id:
            warn("Cannot revert: no revision id in savepoint response")
            return
        try:
            self.fw.client.run_module(
                "raw",
                params={
                    "module": "firewall",
                    "controller": "filter",
                    "command": f"revert/{rev_id}",
                    "action": "post",
                },
            )
        except Exception as exc:
            error(f"Savepoint revert failed: {exc}")

    # ── firewallType: "NONE" fallback ───────────────────────────────────

    def _emit_manual_instructions(self, module: ModuleSpec) -> None:
        info(
            f"firewall:rules — firewallType is NONE for module '{module.vmname}'. "
            f"Manual firewall configuration required."
        )
        info("")
        if module.ingress:
            info(f"INGRESS to {module.vmname} ({module.vmname}.{module.zone0}.{DEFAULT_DOMAIN_SUFFIX}):")
            for entry in module.ingress:
                src = self._render_peer(entry.get("from", ""))
                proto = _normalize_protocol(entry.get("protocol"))
                ports = ",".join(str(p) for p in entry.get("ports", []))
                info(
                    f"  PASS  {src:30s} → {module.vmname}:{ports}/{proto}   "
                    f"\"{entry.get('description', '')}\""
                )
        if module.egress:
            info("")
            info(f"EGRESS from {module.vmname}:")
            for entry in module.egress:
                dst = self._render_peer(entry.get("to", ""))
                proto = _normalize_protocol(entry.get("protocol"))
                ports = ",".join(str(p) for p in entry.get("ports", []))
                info(
                    f"  PASS  → {dst:30s} :{ports}/{proto}   "
                    f"\"{entry.get('description', '')}\""
                )

        # Auto-pinholes from dependsOn + provider's pinhole.json (issue #173).
        # Apply the same predicate as _compile_auto_pinholes so NONE-mode
        # output stays consistent with what would actually be installed.
        auto_descriptions: list[str] = []
        for dep in module.depends_on:
            parsed = _parse_dependency(dep)
            if not parsed:
                continue
            provider_name, service = parsed
            try:
                provider = load_module(self.modules_dir, provider_name)
            except FileNotFoundError:
                continue
            port_specs = load_pinhole_ports(provider.location, service)
            if not port_specs:
                continue
            if module.zone0 == provider.zone0:
                continue
            provider_zone = self.zones.get(provider.zone0)
            if not provider_zone:
                continue
            if module.zone0 in provider_zone.access_to:
                continue
            if module.zone0 not in provider_zone.pinhole_allowed_from:
                warn(
                    f"{module.vmname}: dependsOn '{dep}' would need a pinhole "
                    f"from zone '{module.zone0}' into '{provider.zone0}', but "
                    f"'{module.zone0}' is not in "
                    f"{provider.zone0}.pinhole-allowed-from = "
                    f"{provider_zone.pinhole_allowed_from}. Skipped."
                )
                continue
            for spec in port_specs:
                port = spec.get("port")
                proto = _normalize_protocol(spec.get("protocol"))
                desc = spec.get("description") or service
                auto_descriptions.append(
                    f"  PASS  {module.vmname:20s} → "
                    f"{provider.vmname:20s}:{port}/{proto}   \"{desc}\""
                )
        if auto_descriptions:
            info("")
            info(f"AUTO-PINHOLES (dependsOn-derived, issue #173) for {module.vmname}:")
            for line in auto_descriptions:
                info(line)
        info("")
        info("No automated changes were made.")

    def _render_peer(self, peer: str) -> str:
        if not peer:
            return ""
        if peer == "internet":
            return "internet (0.0.0.0/0)"
        if peer.startswith("alias:"):
            return f"alias:{peer[len('alias:'):]}"
        if peer in self.zones:
            return f"{peer} ({self.zones[peer].ip_network})"
        return f"{peer} (module)"

    # ── Sequence map artifact ────────────────────────────────────────────

    def _write_sequence_map(
        self, module: ModuleSpec, rules: list[ModuleFirewallRule]
    ) -> None:
        if not self.sequence_map_file:
            return
        try:
            self.sequence_map_file.parent.mkdir(parents=True, exist_ok=True)
            existing: dict = {}
            if self.sequence_map_file.exists():
                with open(self.sequence_map_file) as f:
                    existing = json.load(f)
            slot = stable_hash_index(module.vmname)
            ing_seqs = [r.sequence for r in rules if r.direction == "ingress"]
            egr_seqs = [r.sequence for r in rules if r.direction == "egress"]
            modules = existing.get("modules", {})
            modules[module.vmname] = {
                "slot": slot,
                "ingress_range": [BAND_INGRESS_BASE + slot * SLOT_SIZE,
                                   BAND_INGRESS_BASE + slot * SLOT_SIZE + SLOT_SIZE - 1],
                "egress_range": [BAND_EGRESS_BASE + slot * SLOT_SIZE,
                                  BAND_EGRESS_BASE + slot * SLOT_SIZE + SLOT_SIZE - 1],
                "ingress_used": ing_seqs,
                "egress_used": egr_seqs,
            }
            doc = {
                "version": 1,
                "bands": {
                    "ingress": {"start": BAND_INGRESS_BASE,
                                 "end": BAND_INGRESS_BASE + SLOT_COUNT * SLOT_SIZE - 1,
                                 "slot_size": SLOT_SIZE},
                    "egress": {"start": BAND_EGRESS_BASE,
                                "end": BAND_EGRESS_BASE + SLOT_COUNT * SLOT_SIZE - 1,
                                "slot_size": SLOT_SIZE},
                },
                "modules": modules,
            }
            with open(self.sequence_map_file, "w") as f:
                json.dump(doc, f, indent=2)
        except Exception as exc:
            warn(f"Could not update sequence-map artifact: {exc}")


def _extract_module(description: str) -> str:
    parts = description.split(":")
    return parts[1] if len(parts) >= 2 else ""


def _canonical_part(description: str) -> str:
    """Canonical ``tappaas-…`` identity of a stored rule description.

    ``_to_firewall_rule`` records OPNsense rule descriptions as
    ``"{canonical} | {freetext}"`` (e.g. the human ingress description), but the
    compile step keys rules by the bare canonical form. Comparisons (verify and
    reconcile-prune) must therefore strip the ``" | <freetext>"`` suffix from the
    live description, or every described rule reads as simultaneously missing and
    extra — and reconcile prunes rules it just (re)created (#246).
    """
    return description.split("|", 1)[0].strip()


# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────


def _find_zones_file(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit)
    candidates = [
        Path("/home/tappaas/config/zones.json"),
        DEFAULT_ZONES_FILE,
        Path("zones.json"),
        Path("src/foundation/firewall/zones.json"),
    ]
    for c in candidates:
        if c.is_file():
            return c
    error(
        "Could not locate zones.json. Use --zones-file to specify the path."
    )
    sys.exit(2)


def _find_aliases_file(explicit: str | None) -> Path | None:
    if explicit:
        p = Path(explicit)
        return p if p.is_file() else None
    if DEFAULT_GLOBAL_ALIASES_FILE.is_file():
        return DEFAULT_GLOBAL_ALIASES_FILE
    return None


def _build_manager(args: argparse.Namespace) -> RulesManager:
    config_kwargs = {
        "firewall": args.firewall,
        "ssl_verify": not args.no_ssl_verify,
        "debug": args.debug,
    }
    if args.api_port is not None:
        config_kwargs["port"] = args.api_port
    if args.credential_file:
        config_kwargs["credential_file"] = args.credential_file
    config = Config(**config_kwargs)
    zones = load_zones(_find_zones_file(args.zones_file))
    global_aliases = load_global_aliases(_find_aliases_file(args.aliases_file))
    return RulesManager(
        config=config,
        zones=zones,
        modules_dir=Path(args.modules_dir),
        global_aliases=global_aliases,
        check_mode=args.check_mode,
        firewall_type=args.firewall_type,
    )


def _output(payload: dict, args: argparse.Namespace) -> None:
    if args.output == "json":
        json.dump(payload, sys.stdout, indent=2)
        sys.stdout.write("\n")


def main() -> int:
    global_parser = argparse.ArgumentParser(add_help=False)
    global_parser.add_argument("--firewall", default=os.environ.get("OPNSENSE_HOST", "firewall.mgmt.internal"),
                                help="OPNsense firewall hostname (default: firewall.mgmt.internal)")
    global_parser.add_argument("--api-port", type=int, default=None, help="OPNsense API port")
    global_parser.add_argument("--no-ssl-verify", action="store_true", help="Skip TLS verification")
    global_parser.add_argument("--credential-file", help="Path to OPNsense API credential file")
    global_parser.add_argument("--zones-file", help="Path to zones.json")
    global_parser.add_argument("--aliases-file", help="Path to firewall/aliases.json")
    global_parser.add_argument("--modules-dir", default=str(DEFAULT_MODULES_DIR),
                                help="Directory containing <module>.json files")
    global_parser.add_argument("--check-mode", action="store_true",
                                help="Dry-run: report intended changes without applying")
    global_parser.add_argument("--output", choices=["text", "json"], default="text",
                                help="Output format (default: text)")
    global_parser.add_argument("--firewall-type", default="opnsense",
                                choices=["opnsense", "NONE"],
                                help="Firewall type (opnsense applies; NONE prints manual instructions)")
    global_parser.add_argument("--debug", action="store_true", help="Enable debug output")

    parser = argparse.ArgumentParser(
        prog="rules-manager",
        description="TAPPaaS per-module firewall rules manager",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        parents=[global_parser],
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    p_add = subparsers.add_parser("add-rules", parents=[global_parser],
                                    help="Compile and apply rules for a module")
    p_add.add_argument("module", help="Module name (consumer of firewall:rules)")

    p_rec = subparsers.add_parser("reconcile", parents=[global_parser],
                                    help="Diff live state against module.json; apply and prune")
    p_rec.add_argument("module", help="Module name")

    p_rm = subparsers.add_parser("remove-rules", parents=[global_parser],
                                   help="Remove all rules and aliases owned by a module")
    p_rm.add_argument("module", help="Module name")

    p_ver = subparsers.add_parser("verify-rules", parents=[global_parser],
                                    help="Verify rules exist in OPNsense")
    p_ver.add_argument("module", help="Module name")
    p_ver.add_argument("--deep", action="store_true",
                        help="Run connectivity probes in addition to rule presence")

    p_ls = subparsers.add_parser("list-rules", parents=[global_parser],
                                   help="List rules currently in OPNsense")
    p_ls.add_argument("--module", help="Filter by module name")
    p_ls.add_argument("--orphans", action="store_true",
                       help="Only rules whose module no longer exists on disk")

    p_ca = subparsers.add_parser("create-alias", parents=[global_parser],
                                   help="Create or update an OPNsense alias")
    p_ca.add_argument("name", help="Alias name")
    p_ca.add_argument("--type", default="host",
                       choices=["host", "network", "port", "url"],
                       help="Alias type (default: host)")
    p_ca.add_argument("--addresses", required=True,
                       help="Comma-separated alias contents")
    p_ca.add_argument("--description", default="", help="Alias description")

    p_da = subparsers.add_parser("remove-alias", parents=[global_parser],
                                   help="Remove an OPNsense alias")
    p_da.add_argument("name", help="Alias name")

    args = parser.parse_args()

    try:
        manager = _build_manager(args)
    except Exception as exc:
        error(f"Failed to initialise rules-manager: {exc}")
        return 2

    try:
        with manager:
            return _dispatch(args, manager)
    except FileNotFoundError as exc:
        error(str(exc))
        return 2
    except Exception as exc:
        error(f"Unhandled error: {exc}")
        if args.debug:
            raise
        return 1


def _dispatch(args: argparse.Namespace, manager: RulesManager) -> int:
    # When the caller asked for JSON, suppress info() log output so the JSON
    # document is the only thing on stdout (jq-friendly).
    if args.output == "json":
        os.environ["TAPPAAS_SILENT"] = "1"
    cmd = args.command
    if cmd == "add-rules":
        result = manager.add_rules(args.module)
        if result.errors:
            return 1
        info(
            f"{result.module}: applied={result.applied} "
            f"aliases={result.aliases_created}"
        )
        _output({"module": result.module, "applied": result.applied,
                  "aliases_created": result.aliases_created,
                  "errors": [str(e) for e in result.errors]}, args)
        return 0

    if cmd == "reconcile":
        result = manager.reconcile(args.module)
        if result.errors:
            return 1
        info(
            f"{result.module}: applied={result.applied} deleted={result.deleted} "
            f"aliases={result.aliases_created}"
        )
        _output({"module": result.module, "applied": result.applied,
                  "deleted": result.deleted,
                  "aliases_created": result.aliases_created,
                  "errors": [str(e) for e in result.errors]}, args)
        return 0

    if cmd == "remove-rules":
        result = manager.remove_rules(args.module)
        info(
            f"{result.module}: deleted={result.deleted} "
            f"aliases_removed={result.aliases_removed}"
        )
        _output({"module": result.module, "deleted": result.deleted,
                  "aliases_removed": result.aliases_removed}, args)
        return 0

    if cmd == "verify-rules":
        result = manager.verify_rules(args.module, deep=args.deep)
        info(f"{result.module}: desired={result.desired} present={result.present} "
             f"missing={len(result.missing)} extra={len(result.extra)}")
        for d in result.missing:
            warn(f"  missing: {d}")
        for d in result.extra:
            warn(f"  extra:   {d}")
        _output({"module": result.module, "desired": result.desired,
                  "present": result.present, "missing": result.missing,
                  "extra": result.extra, "ok": result.ok}, args)
        return 0 if result.ok else 1

    if cmd == "list-rules":
        rules = manager.list_rules(module_name=args.module, orphans=args.orphans)
        for r in rules:
            info(f"  {r.description}  (seq={r.sequence}, iface={r.interface})")
        _output({"count": len(rules),
                  "rules": [{"description": r.description, "sequence": r.sequence,
                              "interface": r.interface, "uuid": r.uuid}
                             for r in rules]}, args)
        return 0

    if cmd == "create-alias":
        addresses = [s.strip() for s in args.addresses.split(",") if s.strip()]
        manager.create_alias(args.name, args.type, addresses, args.description)
        info(f"alias '{args.name}' upserted ({args.type}: {addresses})")
        return 0

    if cmd == "remove-alias":
        ok = manager.remove_alias(args.name)
        return 0 if ok else 1

    error(f"Unknown command: {cmd}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
