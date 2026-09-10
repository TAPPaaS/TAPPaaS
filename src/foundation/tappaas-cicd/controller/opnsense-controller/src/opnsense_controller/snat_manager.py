"""Source-NAT (masquerade) management operations for OPNsense.

Wraps the OPNsense ``firewall/source_nat`` API (the "Firewall -> NAT ->
Outbound" controller) via the oxl-opnsense-client ``raw`` module, mirroring
``nat_manager`` — which drives ``firewall/d_nat`` for destination NAT (#285).
The two are one letter apart and opposite in direction: destination NAT
publishes an inside port outward, source NAT rewrites the *source* address of
traffic entering a zone (ADR-016).

Rules are identified for idempotency by their ``description``, following the
convention the other TAPPaaS managers already use
("tappaas-snat:<module>:<from>-><zone0>").

Two things here have no counterpart in ``nat_manager``:

**Listing reads the config model, not searchRule.** ADR-016 D4 specifies
``searchRule`` for list. This module reads ``get`` -> ``filter.snatrules.rule``
instead. ``searchRule`` merges the rules OPNsense *generates* with the ones
stored in config, and #623 reports that under ``snat_mode=automatic`` it omits
the stored ones entirely — unverified, because it needs a site with a live
custom rule. The stored model has no such ambiguity: it is what config.xml
holds, whatever the mode. Reading it makes ownership and idempotency
mode-independent by construction rather than by assumption.

**Presence is not enforcement.** A source-NAT rule is accepted into config and
then silently excluded from the generated ruleset while ``snat_mode`` is
``automatic`` — which is the entire failure of #239, reported as installed for
three weeks and never once in the ruleset. Callers that need the rule to
actually carry traffic must consult :meth:`SnatManager.is_enforcing`, not just
find the rule in :meth:`SnatManager.list_rules`.
"""

from dataclasses import dataclass
from oxl_opnsense_client import Client

from .config import Config

# OPNsense API coordinates for the outbound-NAT controller.
_MODULE = "firewall"
_CONTROLLER = "source_nat"

# The four outbound-NAT modes, as the API spells them. Note ``advanced``: the
# GUI labels it "Manual", and a --set manual would simply fail.
MODES = ("automatic", "hybrid", "advanced", "disabled")

# The modes in which a custom (config-stored) rule is actually evaluated.
# Under ``automatic`` OPNsense generates only internal->WAN rules and ignores
# stored ones; ``disabled`` generates nothing at all.
ENFORCING_MODES = ("hybrid", "advanced")

# The only transition safe to make on a caller's behalf. It is purely additive:
# OPNsense keeps generating its automatic per-interface rules and merely starts
# evaluating stored ones alongside them. ``advanced`` REPLACES automatic
# generation, so entering or leaving it can drop outbound connectivity for
# every zone at once and stays a deliberate operator action.
SAFE_TRANSITION = ("automatic", "hybrid")


@dataclass
class SnatRule:
    """A source-NAT (masquerade) rule.

    Rewrites the source address of traffic from ``source_net`` to
    ``destination_net`` so it appears to originate from ``target``.
    """

    description: str
    interface: str  # OPNsense interface of the destination zone (e.g. "opt4")
    source_net: str  # Source zone CIDR (e.g. "10.3.10.0/24")
    destination_net: str  # Destination zone CIDR (e.g. "10.4.20.0/24")
    target: str  # Address traffic is translated to (e.g. "opt4ip")
    ip_protocol: str = "inet"  # inet (IPv4), inet6
    enabled: bool = True

    def to_api_payload(self) -> dict:
        """Build the ``{"rule": {...}}`` body for add/set requests."""
        rule = {
            "enabled": "1" if self.enabled else "0",
            "interface": self.interface,
            "ipprotocol": self.ip_protocol,
            "source_net": self.source_net,
            "destination_net": self.destination_net,
            "target": self.target,
            "description": self.description,
        }
        return {"rule": rule}


@dataclass
class SnatRuleInfo:
    """Information about an existing source-NAT rule."""

    uuid: str
    description: str
    enabled: bool
    interface: str
    source_net: str
    destination_net: str
    target: str


def _selected(field_data) -> str:
    """Extract the selected value from an OPNsense field (dict or plain str).

    OPNsense returns enumerable fields as an option dict — every choice, with
    ``selected: 1`` on the current one — rather than as a scalar.
    """
    if isinstance(field_data, str):
        return field_data
    if isinstance(field_data, dict):
        for key, info in field_data.items():
            if isinstance(info, dict) and str(info.get("selected")) == "1":
                return key
    return ""


class SnatModeError(RuntimeError):
    """Raised when the outbound-NAT mode blocks an operation.

    Distinct from a transport or API failure: the request was understood and
    refused on policy, and the caller is expected to report the mode rather
    than retry.
    """


class SnatManager:
    """Manage source-NAT (masquerade) rules and the outbound-NAT mode."""

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

    def connect(self) -> "SnatManager":
        """Establish connection to OPNsense."""
        self._client = Client(**self._get_client_kwargs())
        return self

    def disconnect(self):
        """Close connection to OPNsense."""
        self._client = None

    def __enter__(self) -> "SnatManager":
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
        """Issue a raw API call against the source_nat controller.

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

    def _filter(self) -> dict:
        """Return the ``filter`` model this controller exposes.

        It holds ``general`` (where the mode lives), ``snatrules`` (source NAT
        — ours), plus ``rules``, ``npt`` and ``onetoone``, which belong to
        other controllers. Reading the wrong node here is how #583 concluded
        the mode was unreadable: it stopped at ``filter`` and never opened
        ``general``.
        """
        return self._raw("get", action="get").get("filter", {}) or {}

    # =========================================================================
    # Outbound-NAT mode
    # =========================================================================

    def get_mode(self) -> str:
        """Read the firewall-wide outbound-NAT mode.

        Returns one of :data:`MODES`, or "" if it could not be determined.
        """
        general = self._filter().get("general", {}) or {}
        return _selected(general.get("snat_mode", {}))

    def is_enforcing(self, mode: str | None = None) -> bool:
        """Whether stored custom rules are evaluated in the current mode.

        This is the question a verify must ask. A rule can be present in
        config and still carry no traffic.
        """
        return (mode if mode is not None else self.get_mode()) in ENFORCING_MODES

    def set_mode(self, mode: str, apply: bool = True) -> dict:
        """Set the outbound-NAT mode.

        Refuses any value outside :data:`MODES`. Callers — not this method —
        decide whether a given transition is permissible; see
        :data:`SAFE_TRANSITION`.
        """
        if mode not in MODES:
            raise SnatModeError(
                f"unknown outbound-NAT mode {mode!r} — expected one of {', '.join(MODES)}"
                " (note: the API spells the GUI's 'Manual' mode 'advanced')"
            )
        result = self._raw(
            "set", action="post", data={"filter": {"general": {"snat_mode": mode}}}
        )
        if apply:
            self.apply_changes()
        return result

    def ensure_enforcing(self, apply: bool = True) -> tuple[str, bool]:
        """Make stored rules evaluable, flipping automatic -> hybrid if needed.

        Returns ``(mode_now, flipped)``. Never silent: the caller is expected
        to report a flip, because it is a firewall-wide change.

        Refuses on ``disabled`` — an unusual, deliberate state that is never
        touched automatically — and leaves ``advanced`` alone, since it is
        already enforcing.
        """
        mode = self.get_mode()
        if mode in ENFORCING_MODES:
            return mode, False
        if mode == "disabled":
            raise SnatModeError(
                "outbound NAT is disabled on this firewall — refusing to enable it "
                "automatically. Set it deliberately (network-manager snat mode --set hybrid) "
                "once you know why it was disabled."
            )
        if mode != SAFE_TRANSITION[0]:
            raise SnatModeError(
                f"cannot make source-NAT rules enforceable from mode {mode!r}"
            )
        self.set_mode(SAFE_TRANSITION[1], apply=apply)
        return SAFE_TRANSITION[1], True

    # =========================================================================
    # Rule operations
    # =========================================================================

    def list_rules(self, search_pattern: str = "") -> list[SnatRuleInfo]:
        """List source-NAT rules stored in config, optionally filtered.

        Reads the config model rather than ``searchRule``; see the module
        docstring for why. Automatically-generated per-interface rules are not
        stored in config and so never appear here — which is the separation
        ADR-016 wanted from ``searchRule`` and could not confirm it provides.

        Args:
            search_pattern: Case-insensitive substring matched against the
                description.
        """
        rules_config = (self._filter().get("snatrules", {}) or {}).get("rule", {})

        # The API returns an empty list (not a dict) when no rules exist.
        if not isinstance(rules_config, dict):
            return []

        rules: list[SnatRuleInfo] = []
        for uuid, data in rules_config.items():
            info = self._parse_rule(uuid, data)
            if not search_pattern or search_pattern.lower() in info.description.lower():
                rules.append(info)
        return rules

    def _parse_rule(self, uuid: str, data: dict) -> SnatRuleInfo:
        """Parse a rule from the source_nat ``get`` response format."""

        def field(name: str) -> str:
            value = data.get(name, "")
            return value if isinstance(value, str) else _selected(value)

        description = data.get("description", "")
        return SnatRuleInfo(
            uuid=uuid,
            description=description if isinstance(description, str) else "",
            enabled=field("enabled") != "0",
            interface=field("interface"),
            source_net=field("source_net"),
            destination_net=field("destination_net"),
            target=field("target"),
        )

    def get_rule_by_description(self, description: str) -> SnatRuleInfo | None:
        """Find a rule by its exact description."""
        for rule in self.list_rules(description):
            if rule.description == description:
                return rule
        return None

    def add_rule(self, rule: SnatRule, apply: bool = True) -> dict:
        """Create or update a source-NAT rule (idempotent by description).

        Does NOT touch the outbound-NAT mode: making a rule enforceable is a
        firewall-wide decision that belongs to the caller, which must report
        it. Use :meth:`ensure_enforcing` first when that is intended.

        Returns the API result dict ({"result": "saved", "uuid": ...}).
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
        """Delete a source-NAT rule by description.

        Returns the API result dict, or {"result": "not_found"} if absent.
        """
        existing = self.get_rule_by_description(description)
        if not existing:
            return {"result": "not_found"}

        result = self._raw(f"delRule/{existing.uuid}", action="post")
        if apply:
            self.apply_changes()
        return result

    def delete_rule_by_uuid(self, uuid: str, apply: bool = True) -> dict:
        """Delete a source-NAT rule by UUID."""
        result = self._raw(f"delRule/{uuid}", action="post")
        if apply:
            self.apply_changes()
        return result

    def apply_changes(self) -> dict:
        """Apply pending source-NAT configuration changes (reloads pf)."""
        return self._raw("apply", action="post")
