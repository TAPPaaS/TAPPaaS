"""Destination-NAT (port-forward) management operations for OPNsense.

Wraps the OPNsense ``firewall/d_nat`` API (the "Firewall → NAT → Port Forward"
controller, available since OPNsense 25.x / verified on 26.1) via the
oxl-opnsense-client ``raw`` module. There is no dedicated oxl module for
port-forwards, so every call is a raw API request — mirroring how
``firewall_manager`` already drives the ``filter`` controller.

Each rule is created as an *rdr-pass* rule (``pass = "pass"``): OPNsense both
translates the destination and passes the traffic in a single atomic rule, so
no companion filter rule is needed on the WAN interface.

Rules are identified for idempotency by their ``descr`` (description) field,
following the same convention as the other TAPPaaS managers
("TAPPaaS: <module> ...").
"""

from dataclasses import dataclass
from oxl_opnsense_client import Client

from .config import Config

# OPNsense API coordinates for the port-forward controller.
_MODULE = "firewall"
_CONTROLLER = "d_nat"


@dataclass
class NatRule:
    """A destination-NAT (port-forward) rule.

    Maps an external port on a firewall interface to an internal host:port.
    """

    description: str
    external_port: int | str  # Port exposed on the firewall interface (destination.port)
    internal_port: int | str  # Port on the internal target host (local-port)
    target: str  # Internal host IP (or alias) traffic is forwarded to
    protocol: str = "TCP"  # TCP, UDP, TCP/UDP
    interface: str = "wan"  # Firewall interface the rule listens on
    destination_net: str = "wanip"  # Match destination (default: the WAN address)
    source_net: str = "any"  # Match source
    ip_protocol: str = "inet"  # inet (IPv4), inet6, inet46
    enabled: bool = True

    def to_api_payload(self) -> dict:
        """Build the ``{"rule": {...}}`` body for add/set requests."""
        rule = {
            "interface": self.interface,
            "ipprotocol": self.ip_protocol,
            "protocol": self.protocol,
            "source": {"network": self.source_net},
            "destination": {
                "network": self.destination_net,
                "port": str(self.external_port),
            },
            "target": self.target,
            "local-port": str(self.internal_port),
            # rdr-pass: translate AND allow in one rule (no separate WAN rule).
            "pass": "pass",
            "disabled": "0" if self.enabled else "1",
            "descr": self.description,
        }
        return {"rule": rule}


@dataclass
class NatRuleInfo:
    """Information about an existing port-forward rule."""

    uuid: str
    description: str
    enabled: bool
    interface: str
    protocol: str
    destination_net: str
    destination_port: str
    target: str
    local_port: str


def _selected(field_data) -> str:
    """Extract the selected value from an OPNsense field (dict or plain str)."""
    if isinstance(field_data, str):
        return field_data
    if isinstance(field_data, dict):
        for key, info in field_data.items():
            if isinstance(info, dict) and info.get("selected") == 1:
                return key
    return ""


class NatManager:
    """Manage destination-NAT (port-forward) rules on OPNsense."""

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

    def connect(self) -> "NatManager":
        """Establish connection to OPNsense."""
        self._client = Client(**self._get_client_kwargs())
        return self

    def disconnect(self):
        """Close connection to OPNsense."""
        self._client = None

    def __enter__(self) -> "NatManager":
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

    # =========================================================================
    # Raw API helpers
    # =========================================================================

    def _raw(self, command: str, action: str = "get", data: dict | None = None) -> dict:
        """Issue a raw API call against the d_nat controller.

        Returns the parsed API ``response`` payload.
        """
        params = {
            "module": _MODULE,
            "controller": _CONTROLLER,
            "command": command,
            "action": action,
        }
        if data is not None:
            params["data"] = data
        result = self.client.run_module("raw", params=params)
        return result.get("result", {}).get("response", {})

    # =========================================================================
    # Rule operations
    # =========================================================================

    def list_rules(self, search_pattern: str = "") -> list[NatRuleInfo]:
        """List all port-forward rules, optionally filtered by description.

        Args:
            search_pattern: Case-insensitive substring matched against descr.

        Returns:
            List of NatRuleInfo objects.
        """
        response = self._raw("get", action="get")
        rules_config = response.get("DNat", {}).get("rule", {})

        # API returns an empty list (not a dict) when no rules exist.
        if not isinstance(rules_config, dict):
            return []

        rules: list[NatRuleInfo] = []
        for uuid, data in rules_config.items():
            info = self._parse_rule(uuid, data)
            if not search_pattern or search_pattern.lower() in info.description.lower():
                rules.append(info)
        return rules

    def _parse_rule(self, uuid: str, data: dict) -> NatRuleInfo:
        """Parse a rule from the d_nat ``get`` response format."""
        destination = data.get("destination", {}) or {}
        return NatRuleInfo(
            uuid=uuid,
            description=data.get("descr", "") if isinstance(data.get("descr"), str) else "",
            enabled=_selected(data.get("disabled", {})) != "1",
            interface=_selected(data.get("interface", {})),
            protocol=_selected(data.get("protocol", {})),
            destination_net=destination.get("network", "")
            if isinstance(destination.get("network"), str)
            else _selected(destination.get("network", {})),
            destination_port=destination.get("port", "")
            if isinstance(destination.get("port"), str)
            else _selected(destination.get("port", {})),
            target=data.get("target", "")
            if isinstance(data.get("target"), str)
            else _selected(data.get("target", {})),
            local_port=data.get("local-port", "")
            if isinstance(data.get("local-port"), str)
            else _selected(data.get("local-port", {})),
        )

    def get_rule_by_description(self, description: str) -> NatRuleInfo | None:
        """Find a rule by its exact description."""
        for rule in self.list_rules(description):
            if rule.description == description:
                return rule
        return None

    def add_rule(self, rule: NatRule, apply: bool = True) -> dict:
        """Create or update a port-forward rule (idempotent by description).

        If a rule with the same description already exists, it is updated in
        place (setRule); otherwise a new rule is created (addRule).

        Args:
            rule: The port-forward rule to create.
            apply: Apply changes immediately (default: True).

        Returns:
            The API result dict ({"result": "saved", "uuid": ...}).
        """
        existing = self.get_rule_by_description(rule.description)
        if existing:
            result = self._raw(
                f"setRule/{existing.uuid}", action="post", data=rule.to_api_payload()
            )
        else:
            result = self._raw("addRule", action="post", data=rule.to_api_payload())

        if apply:
            self.apply_changes()
        return result

    def delete_rule(self, description: str, apply: bool = True) -> dict:
        """Delete a port-forward rule by description.

        Args:
            description: Description of the rule to delete.
            apply: Apply changes immediately (default: True).

        Returns:
            The API result dict, or {"result": "not_found"} if absent.
        """
        existing = self.get_rule_by_description(description)
        if not existing:
            return {"result": "not_found"}

        result = self._raw(f"delRule/{existing.uuid}", action="post")
        if apply:
            self.apply_changes()
        return result

    def delete_rule_by_uuid(self, uuid: str, apply: bool = True) -> dict:
        """Delete a port-forward rule by UUID."""
        result = self._raw(f"delRule/{uuid}", action="post")
        if apply:
            self.apply_changes()
        return result

    def apply_changes(self) -> dict:
        """Apply pending port-forward configuration changes (reloads pf)."""
        return self._raw("apply", action="post")
