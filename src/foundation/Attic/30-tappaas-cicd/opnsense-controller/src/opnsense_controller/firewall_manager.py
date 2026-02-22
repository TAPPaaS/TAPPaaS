"""Firewall rule management operations for OPNsense."""

from dataclasses import dataclass, field
from enum import Enum
from oxl_opnsense_client import Client

from .config import Config


class RuleAction(str, Enum):
    """Firewall rule action."""

    PASS = "pass"
    BLOCK = "block"
    REJECT = "reject"


class RuleDirection(str, Enum):
    """Traffic direction for firewall rule."""

    IN = "in"
    OUT = "out"


class IpProtocol(str, Enum):
    """IP protocol version."""

    IPV4 = "inet"
    IPV6 = "inet6"
    BOTH = "inet46"


class Protocol(str, Enum):
    """Network protocol."""

    ANY = "any"
    TCP = "TCP"
    UDP = "UDP"
    TCP_UDP = "TCP/UDP"
    ICMP = "ICMP"
    ICMPV6 = "IPv6-ICMP"
    ESP = "ESP"
    AH = "AH"
    GRE = "GRE"
    IGMP = "IGMP"
    OSPF = "OSPF"
    PIM = "PIM"
    CARP = "CARP"
    PFSYNC = "PFSYNC"


@dataclass
class FirewallRule:
    """Firewall rule configuration for OPNsense."""

    description: str
    action: RuleAction = RuleAction.PASS
    interface: str | list[str] = "lan"  # Interface name(s), e.g., 'lan', 'wan', 'opt1'
    direction: RuleDirection = RuleDirection.IN
    ip_protocol: IpProtocol = IpProtocol.IPV4
    protocol: Protocol = Protocol.ANY

    # Source
    source_net: str = "any"  # IP, network (CIDR), alias name, or 'any'
    source_port: str | None = None  # Port, range, or alias (None = any)
    source_invert: bool = False

    # Destination
    destination_net: str = "any"  # IP, network (CIDR), alias name, or 'any'
    destination_port: str | None = None  # Port, range, or alias (None = any)
    destination_invert: bool = False

    # Advanced options
    gateway: str | None = None  # Gateway name for policy routing
    log: bool = True  # Log matching packets
    quick: bool = True  # Stop processing on match
    enabled: bool = True
    sequence: int | None = None  # Rule order (lower = higher priority)

    # Optional UUID for existing rules
    uuid: str | None = None


@dataclass
class FirewallRuleInfo:
    """Information about an existing firewall rule."""

    uuid: str
    description: str
    enabled: bool
    action: str
    interface: str
    direction: str
    protocol: str
    source_net: str
    source_port: str | None
    destination_net: str
    destination_port: str | None
    log: bool
    sequence: int | None = None

    @classmethod
    def from_api_response(cls, uuid: str, data: dict) -> "FirewallRuleInfo":
        """Create from OPNsense API response."""
        return cls(
            uuid=uuid,
            description=data.get("description", ""),
            enabled=data.get("enabled") == "1",
            action=data.get("action", ""),
            interface=data.get("interface", ""),
            direction=data.get("direction", ""),
            protocol=data.get("protocol", ""),
            source_net=data.get("source_net", ""),
            source_port=data.get("source_port"),
            destination_net=data.get("destination_net", ""),
            destination_port=data.get("destination_port"),
            log=data.get("log") == "1",
            sequence=int(data["sequence"]) if data.get("sequence") else None,
        )


class FirewallManager:
    """Manage firewall rules on OPNsense."""

    def __init__(self, config: Config):
        self.config = config
        self._client: Client | None = None

    def _get_client_kwargs(self) -> dict:
        """Build client connection kwargs from config."""
        kwargs = {
            "firewall": self.config.firewall,
            "port": self.config.resolve_port(),
            "ssl_verify": self.config.ssl_verify,
            "debug": self.config.debug,
            "api_timeout": self.config.api_timeout,
            "api_retries": self.config.api_retries,
        }

        if self.config.credential_file:
            kwargs["credential_file"] = self.config.credential_file
        elif self.config.token and self.config.secret:
            kwargs["token"] = self.config.token
            kwargs["secret"] = self.config.secret

        if self.config.ssl_ca_file:
            kwargs["ssl_ca_file"] = self.config.ssl_ca_file

        return kwargs

    def connect(self) -> "FirewallManager":
        """Establish connection to OPNsense."""
        self._client = Client(**self._get_client_kwargs())
        return self

    def disconnect(self):
        """Close connection to OPNsense."""
        self._client = None

    def __enter__(self) -> "FirewallManager":
        return self.connect()

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.disconnect()

    @property
    def client(self) -> Client:
        """Get the active client, raising if not connected."""
        if not self._client:
            raise RuntimeError("Not connected. Use connect() or context manager.")
        return self._client

    def test_connection(self) -> bool:
        """Test the connection to OPNsense."""
        return self.client.test()

    def get_rule_spec(self) -> dict:
        """Get the specification for the rule module."""
        return self.client.module_specs("rule")

    # =========================================================================
    # Firewall Rule Operations
    # =========================================================================

    def list_rules(self, search_pattern: str = "") -> list[FirewallRuleInfo]:
        """List all firewall rules.

        Args:
            search_pattern: Search pattern to filter rules (default: all)

        Returns:
            List of FirewallRuleInfo objects
        """
        # Use the /api/firewall/filter/get endpoint which shows the full config
        result = self.client.run_module(
            "raw",
            params={
                "module": "firewall",
                "controller": "filter",
                "command": "get",
                "action": "get",
            },
        )

        response = result.get("result", {}).get("response", {})
        filter_config = response.get("filter", {})
        rules_config = filter_config.get("rules", {}).get("rule", {})

        # API may return an empty list instead of dict when no rules exist
        if isinstance(rules_config, list):
            return []

        rules = []
        for rule_uuid, rule_data in rules_config.items():
            # Extract selected values from the OPNsense API format
            rule_info = self._parse_rule_from_get(rule_uuid, rule_data)
            if rule_info:
                # Apply search filter if provided
                if not search_pattern or search_pattern.lower() in rule_info.description.lower():
                    rules.append(rule_info)

        return rules

    def _parse_rule_from_get(self, uuid: str, data: dict) -> FirewallRuleInfo | None:
        """Parse a rule from the /api/firewall/filter/get response format.

        The get endpoint returns each field as a dict of options with 'selected' flags.
        """
        def get_selected_value(field_data: dict | str) -> str:
            """Extract the selected value from an OPNsense field dict."""
            if isinstance(field_data, str):
                return field_data
            for key, info in field_data.items():
                if isinstance(info, dict) and info.get("selected") == 1:
                    return key
            return ""

        def get_selected_interface(field_data: dict) -> str:
            """Extract selected interface(s)."""
            if isinstance(field_data, str):
                return field_data
            selected = []
            for key, info in field_data.items():
                if isinstance(info, dict) and info.get("selected") == 1:
                    selected.append(key)
            return ",".join(selected) if selected else ""

        return FirewallRuleInfo(
            uuid=uuid,
            description=data.get("description", ""),
            enabled=data.get("enabled") == "1",
            action=get_selected_value(data.get("action", {})),
            interface=get_selected_interface(data.get("interface", {})),
            direction=get_selected_value(data.get("direction", {})),
            protocol=get_selected_value(data.get("protocol", {})),
            source_net=data.get("source_net", ""),
            source_port=data.get("source_port") or None,
            destination_net=data.get("destination_net", ""),
            destination_port=data.get("destination_port") or None,
            log=data.get("log") == "1",
            sequence=int(data["sequence"]) if data.get("sequence") else None,
        )

    def get_rule(self, uuid: str) -> dict:
        """Get details of a specific firewall rule.

        Args:
            uuid: UUID of the rule to retrieve

        Returns:
            Rule details dictionary
        """
        result = self.client.run_module(
            "raw",
            params={
                "module": "firewall",
                "controller": "filter",
                "command": f"getRule/{uuid}",
                "action": "get",
            },
        )
        return result.get("result", {}).get("response", {})

    def get_rule_by_description(self, description: str) -> FirewallRuleInfo | None:
        """Find a rule by its description.

        Args:
            description: Rule description to search for

        Returns:
            FirewallRuleInfo if found, None otherwise
        """
        rules = self.list_rules(description)
        for rule in rules:
            if rule.description == description:
                return rule
        return None

    def create_rule(self, rule: FirewallRule, apply: bool = True) -> dict:
        """Create a new firewall rule.

        Args:
            rule: Firewall rule configuration
            apply: Whether to apply changes immediately (default: True)

        Returns:
            Result dictionary from the API with 'uuid' on success
        """
        # Build rule parameters
        params = {
            "description": rule.description,
            "action": rule.action.value if isinstance(rule.action, RuleAction) else rule.action,
            "direction": rule.direction.value if isinstance(rule.direction, RuleDirection) else rule.direction,
            "ip_protocol": rule.ip_protocol.value if isinstance(rule.ip_protocol, IpProtocol) else rule.ip_protocol,
            "protocol": rule.protocol.value if isinstance(rule.protocol, Protocol) else rule.protocol,
            "source_net": rule.source_net,
            "destination_net": rule.destination_net,
            "log": rule.log,
            "quick": rule.quick,
            "enabled": rule.enabled,
            # match_fields determines how to identify existing rules for updates
            "match_fields": ["description"],
            # Don't reload after each rule, we'll call apply_changes manually
            "reload": False,
        }

        # Handle interface (can be single or multiple)
        if isinstance(rule.interface, list):
            params["interface"] = ",".join(rule.interface)
        else:
            params["interface"] = rule.interface

        # Optional source port
        if rule.source_port:
            params["source_port"] = rule.source_port
        if rule.source_invert:
            params["source_not"] = "1"

        # Optional destination port
        if rule.destination_port:
            params["destination_port"] = rule.destination_port
        if rule.destination_invert:
            params["destination_not"] = "1"

        # Optional gateway for policy routing
        if rule.gateway:
            params["gateway"] = rule.gateway

        # Optional sequence
        if rule.sequence is not None:
            params["sequence"] = str(rule.sequence)

        # Use the oxl-opnsense-client rule module
        result = self.client.run_module(
            "rule",
            params=params,
        )

        # Apply changes if requested
        if apply:
            self.apply_changes()

        return result

    def update_rule(self, rule: FirewallRule, apply: bool = True) -> dict:
        """Update an existing firewall rule (matched by description).

        Args:
            rule: Firewall rule configuration with updated values
            apply: Whether to apply changes immediately (default: True)

        Returns:
            Result dictionary from the API
        """
        # The oxl-opnsense-client rule module handles updates via description matching
        return self.create_rule(rule, apply=apply)

    def delete_rule(self, description: str, apply: bool = True) -> dict:
        """Delete a firewall rule by description.

        Args:
            description: Description of the rule to delete
            apply: Whether to apply changes immediately (default: True)

        Returns:
            Result dictionary from the API
        """
        result = self.client.run_module(
            "rule",
            params={
                "description": description,
                "state": "absent",
                "match_fields": ["description"],
                "reload": False,
            },
        )

        if apply:
            self.apply_changes()

        return result

    def delete_rule_by_uuid(self, uuid: str, apply: bool = True) -> dict:
        """Delete a firewall rule by UUID.

        Args:
            uuid: UUID of the rule to delete
            apply: Whether to apply changes immediately (default: True)

        Returns:
            Result dictionary from the API
        """
        result = self.client.run_module(
            "raw",
            params={
                "module": "firewall",
                "controller": "filter",
                "command": f"delRule/{uuid}",
                "action": "post",
            },
        )

        if apply:
            self.apply_changes()

        return result

    def toggle_rule(self, uuid: str, enabled: bool, apply: bool = True) -> dict:
        """Enable or disable a firewall rule.

        Args:
            uuid: UUID of the rule
            enabled: Whether to enable (True) or disable (False)
            apply: Whether to apply changes immediately (default: True)

        Returns:
            Result dictionary from the API
        """
        enabled_val = "1" if enabled else "0"
        result = self.client.run_module(
            "raw",
            params={
                "module": "firewall",
                "controller": "filter",
                "command": f"toggleRule/{uuid}/{enabled_val}",
                "action": "post",
            },
        )

        if apply:
            self.apply_changes()

        return result

    def apply_changes(self) -> dict:
        """Apply firewall configuration changes.

        Returns:
            Result dictionary from the API
        """
        result = self.client.run_module(
            "raw",
            params={
                "module": "firewall",
                "controller": "filter",
                "command": "apply",
                "action": "post",
            },
        )
        return result

    def create_savepoint(self) -> dict:
        """Create a savepoint before making changes.

        This allows reverting changes if something goes wrong.

        Returns:
            Result dictionary with revision info
        """
        result = self.client.run_module(
            "raw",
            params={
                "module": "firewall",
                "controller": "filter",
                "command": "savepoint",
                "action": "post",
            },
        )
        return result

    def revert_changes(self, revision: str) -> dict:
        """Revert to a previous configuration.

        Args:
            revision: Revision ID to revert to

        Returns:
            Result dictionary from the API
        """
        result = self.client.run_module(
            "raw",
            params={
                "module": "firewall",
                "controller": "filter",
                "command": f"revert/{revision}",
                "action": "post",
            },
        )
        return result

    # =========================================================================
    # Convenience Methods
    # =========================================================================

    def create_allow_rule(
        self,
        description: str,
        interface: str | list[str],
        source: str = "any",
        destination: str = "any",
        protocol: Protocol = Protocol.ANY,
        destination_port: str | None = None,
        log: bool = True,
        apply: bool = True,
    ) -> dict:
        """Create a simple allow (pass) rule.

        Args:
            description: Rule description
            interface: Interface(s) to apply rule on
            source: Source network/host/alias (default: any)
            destination: Destination network/host/alias (default: any)
            protocol: Protocol (default: any)
            destination_port: Destination port (optional)
            log: Enable logging (default: True)
            apply: Apply changes immediately (default: True)

        Returns:
            Result dictionary from the API
        """
        rule = FirewallRule(
            description=description,
            action=RuleAction.PASS,
            interface=interface,
            source_net=source,
            destination_net=destination,
            protocol=protocol,
            destination_port=destination_port,
            log=log,
        )
        return self.create_rule(rule, apply=apply)

    def create_block_rule(
        self,
        description: str,
        interface: str | list[str],
        source: str = "any",
        destination: str = "any",
        protocol: Protocol = Protocol.ANY,
        destination_port: str | None = None,
        log: bool = True,
        apply: bool = True,
    ) -> dict:
        """Create a simple block rule.

        Args:
            description: Rule description
            interface: Interface(s) to apply rule on
            source: Source network/host/alias (default: any)
            destination: Destination network/host/alias (default: any)
            protocol: Protocol (default: any)
            destination_port: Destination port (optional)
            log: Enable logging (default: True)
            apply: Apply changes immediately (default: True)

        Returns:
            Result dictionary from the API
        """
        rule = FirewallRule(
            description=description,
            action=RuleAction.BLOCK,
            interface=interface,
            source_net=source,
            destination_net=destination,
            protocol=protocol,
            destination_port=destination_port,
            log=log,
        )
        return self.create_rule(rule, apply=apply)

    def create_multiple_rules(
        self,
        rules: list[FirewallRule],
        apply: bool = True,
    ) -> list[dict]:
        """Create multiple firewall rules.

        Args:
            rules: List of firewall rule configurations
            apply: Whether to apply changes after all rules are created

        Returns:
            List of result dictionaries from the API
        """
        results = []
        for rule in rules:
            # Don't apply after each rule, only at the end
            result = self.create_rule(rule, apply=False)
            results.append(result)

        if apply:
            self.apply_changes()

        return results
