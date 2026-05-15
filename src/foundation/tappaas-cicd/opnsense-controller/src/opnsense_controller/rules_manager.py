#!/usr/bin/env python3
"""TAPPaaS Rules Manager — per-module firewall rules from module.json.

Compiles `ports`, `ingress`, `egress`, and `aliases` from a consuming module's
JSON declaration into OPNsense firewall rules and aliases. Operates as a
TAPPaaS-aware orchestrator on top of the lower-level FirewallManager.

Description-based identity makes apply operations idempotent:
    tappaas-module:<vmname>:<direction>:<peer>:<port>[/<protocol>]

When a peer is another module's name (rather than a zone, 'internet', or an
'alias:<name>' reference), the manager creates and references an OPNsense host
alias `tappaas_module_<peer_vmname>` (OPNsense aliases use underscores; any
hyphens in vmname are normalised) containing the peer's FQDN
(`<vmname>.<zone0>.internal`). OPNsense's Unbound resolver looks up the FQDN
against dnsmasq, so DHCP-driven IP changes flow through transparently without
rule rewrites.

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

# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────

DESCRIPTION_PREFIX = "tappaas-module"
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
        # Cache: peer-module zone lookup for FQDN aliases (avoids re-reading JSON)
        self._peer_zone_cache: dict[str, str] = {}

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

        prefix = f"{DESCRIPTION_PREFIX}:{module.vmname}:"
        existing = self.fw.list_rules(search_pattern=prefix)
        if self.check_mode:
            info(f"[check] would delete {len(existing)} rule(s) for {module.vmname}")
            return result

        revision = self.fw.create_savepoint()
        try:
            for rule in existing:
                if rule.description.startswith(prefix):
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
        """List rules currently in OPNsense, optionally filtered."""
        if module_name:
            return self.fw.list_rules(
                search_pattern=f"{DESCRIPTION_PREFIX}:{module_name}:"
            )
        rules = self.fw.list_rules(search_pattern=f"{DESCRIPTION_PREFIX}:")
        if not orphans:
            return rules
        known = set(discover_modules(self.modules_dir))
        return [r for r in rules if _extract_module(r.description) not in known]

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
        existing = self.fw.list_rules(
            search_pattern=f"{DESCRIPTION_PREFIX}:{module.vmname}:"
        )
        existing_descs = {r.description for r in existing}

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
                prefix = f"{DESCRIPTION_PREFIX}:{module.vmname}:"
                live = self.fw.list_rules(search_pattern=prefix)
                desired_descs = {r.description for r in rules}
                for live_rule in live:
                    if live_rule.description not in desired_descs:
                        info(f"[check] -rule desc='{live_rule.description}'")
            return result

        # 1. Ensure aliases (module-local + peer-module FQDN aliases) exist
        for alias_name, alias_def in module.aliases.items():
            self._upsert_alias(
                alias_name,
                alias_def.get("type", "host"),
                alias_def.get("addresses", []),
                alias_def.get("description", ""),
            )
            result.aliases_created += 1
        for peer_alias_name, peer_fqdn in self._peer_module_fqdn_aliases(module).items():
            self._upsert_alias(
                peer_alias_name,
                "host",
                [peer_fqdn],
                f"FQDN alias for module '{peer_fqdn.split('.')[0]}' "
                f"(DHCP IP resolved via Unbound/dnsmasq)",
            )
            result.aliases_created += 1

        # 2. Apply rules atomically with a savepoint
        revision = self.fw.create_savepoint()
        try:
            prefix = f"{DESCRIPTION_PREFIX}:{module.vmname}:"
            existing = self.fw.list_rules(search_pattern=prefix) if prune else []
            desired_descs = {r.description for r in rules}

            for r in rules:
                self.fw.create_rule(self._to_firewall_rule(r), apply=False)
                result.applied += 1

            if prune:
                for live_rule in existing:
                    if live_rule.description not in desired_descs:
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

        return rules, errors

    # ── Validation ───────────────────────────────────────────────────────

    def _validate(self, module: ModuleSpec) -> list[ValidationError]:
        errors: list[ValidationError] = []
        declared_ports = {str(p.get("port")) for p in module.ports}

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

    def _peer_module_fqdn_aliases(self, module: ModuleSpec) -> dict[str, str]:
        """Return {alias_name: fqdn} for the module itself and every module-named peer."""
        result: dict[str, str] = {}
        # Self alias — destination for ingress, source for egress
        if module.zone0:
            result[_module_alias_name(module.vmname)] = (
                f"{module.vmname}.{module.zone0}.{DEFAULT_DOMAIN_SUFFIX}"
            )
        # Peer aliases (module-name peers in ingress.from and egress.to)
        for entry in module.ingress:
            peer = entry.get("from")
            if peer and peer != "internet" and not peer.startswith("alias:") and peer not in self.zones:
                fqdn = self._peer_fqdn(peer)
                if fqdn:
                    result[_module_alias_name(peer)] = fqdn
        for entry in module.egress:
            peer = entry.get("to")
            if peer and peer != "internet" and not peer.startswith("alias:") and peer not in self.zones:
                fqdn = self._peer_fqdn(peer)
                if fqdn:
                    result[_module_alias_name(peer)] = fqdn
        return result

    def _peer_module_aliases_for(self, module: ModuleSpec) -> list[str]:
        """Return the list of peer-module alias names referenced by `module`."""
        names: list[str] = []
        for entry in (*module.ingress, *module.egress):
            peer = entry.get("from") or entry.get("to")
            if peer and peer != "internet" and not peer.startswith("alias:") and peer not in self.zones:
                names.append(_module_alias_name(peer))
        return names

    def _peer_fqdn(self, peer_vmname: str) -> str | None:
        """Resolve <peer_vmname>.<zone>.internal by reading the peer's module.json."""
        if peer_vmname in self._peer_zone_cache:
            zone = self._peer_zone_cache[peer_vmname]
            return f"{peer_vmname}.{zone}.{DEFAULT_DOMAIN_SUFFIX}" if zone else None
        try:
            peer_module = load_module(self.modules_dir, peer_vmname)
        except FileNotFoundError:
            return None
        zone = peer_module.zone0 or ""
        self._peer_zone_cache[peer_vmname] = zone
        if not zone:
            return None
        return f"{peer_vmname}.{zone}.{DEFAULT_DOMAIN_SUFFIX}"

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

        VLAN zones: the zone name is used (zone_manager assigns
        VLAN interface descriptions matching the zone name).
        Non-VLAN zones: the bridge name (lan/wan).
        """
        if zone.vlan_tag > 0:
            return zone.name
        return zone.bridge.lower()

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
        """Return True if no rule outside `exclude_module` references `alias_name`."""
        rules = self.fw.list_rules(search_pattern=DESCRIPTION_PREFIX + ":")
        exclude_prefix = f"{DESCRIPTION_PREFIX}:{exclude_module}:"
        for r in rules:
            if r.description.startswith(exclude_prefix):
                continue
            if alias_name in (r.source_net or "") or alias_name in (r.destination_net or ""):
                return False
        return True

    def _revert(self, revision) -> None:
        try:
            self.fw.client.run_module(
                "raw",
                params={
                    "module": "firewall",
                    "controller": "filter",
                    "command": "revert/" + str(revision.get("revision", "")),
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
