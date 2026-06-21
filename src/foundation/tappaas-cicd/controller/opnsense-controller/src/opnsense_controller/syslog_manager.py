"""OPNsense built-in syslog destination management.

Targets the `OPNsense/Syslog` module's `settings` and `service` controllers
(see /usr/local/opnsense/mvc/app/controllers/OPNsense/Syslog/Api/*).
"""

from dataclasses import dataclass, field
from oxl_opnsense_client import Client

from .config import Config


# Allowed transports per OPNsense Syslog.xml model
TRANSPORTS = {"udp4", "tcp4", "udp6", "tcp6", "tls4", "tls6"}

# Allowed severity levels (OPNsense uses "err"/"crit"/"emerg" — not "error" etc.)
LEVELS = {"debug", "info", "notice", "warn", "err", "crit", "alert", "emerg"}


@dataclass
class SyslogDestination:
    """Input shape for addDestination/setDestination.

    Empty strings on multi-select fields (program/level/facility) mean
    "match everything" — OPNsense's API treats them as no filter.
    """

    hostname: str                       # required: target FQDN or IP
    port: int = 514                     # required: target port (default OPNsense pickf)
    transport: str = "tcp4"             # one of TRANSPORTS
    rfc5424: bool = True                # use RFC 5424 format (Promtail wants this)
    enabled: bool = True
    description: str = ""               # idempotency key — pick a stable string
    program: str = ""                   # comma-sep app filter; "" = all
    level: str = ""                     # comma-sep severities; "" = all
    facility: str = ""                  # comma-sep facilities; "" = all
    certificate: str = ""               # cert UUID — only for tls4/tls6


@dataclass
class SyslogDestinationInfo:
    """Information about an existing syslog destination (from search)."""

    uuid: str
    enabled: bool
    transport: str
    hostname: str
    port: str
    rfc5424: bool
    description: str

    @classmethod
    def from_api_response(cls, data: dict) -> "SyslogDestinationInfo":
        """Build from a row in searchDestinations response."""
        # OPNsense returns multi-select option fields as a dict {value: label, selected: true/false};
        # for plain string fields we get the value directly. Be defensive.
        transport = data.get("transport", "")
        if isinstance(transport, dict):
            # selected option — find the one with selected=1
            transport = next(
                (k for k, v in transport.items() if isinstance(v, dict) and v.get("selected")),
                "",
            )
        return cls(
            uuid=data.get("uuid", ""),
            enabled=str(data.get("enabled", "")) == "1",
            transport=str(transport),
            hostname=data.get("hostname", ""),
            port=str(data.get("port", "")),
            rfc5424=str(data.get("rfc5424", "")) == "1",
            description=data.get("description", ""),
        )


class SyslogManager:
    """Manage syslog destinations on OPNsense's built-in syslog."""

    def __init__(self, config: Config):
        self.config = config
        self._client: Client | None = None

    def _get_client_kwargs(self) -> dict:
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

    def connect(self) -> "SyslogManager":
        self._client = Client(**self._get_client_kwargs())
        return self

    def disconnect(self):
        self._client = None

    def __enter__(self) -> "SyslogManager":
        return self.connect()

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.disconnect()

    @property
    def client(self) -> Client:
        if not self._client:
            raise RuntimeError("Not connected. Use connect() or context manager.")
        return self._client

    def test_connection(self) -> bool:
        return self.client.test()

    # ── Raw API helpers ────────────────────────────────────────────────

    def _api_get(self, controller: str, command: str) -> dict:
        result = self.client.run_module(
            "raw",
            params={
                "module": "syslog",
                "controller": controller,
                "command": command,
                "action": "get",
            },
        )
        return result.get("result", {}).get("response", {})

    def _api_post(
        self,
        controller: str,
        command: str,
        data: dict | None = None,
        url_params: list[str] | None = None,
    ) -> dict:
        params: dict = {
            "module": "syslog",
            "controller": controller,
            "command": command,
            "action": "post",
        }
        if data:
            params["data"] = data
        if url_params:
            params["params"] = url_params
        result = self.client.run_module("raw", params=params)
        return result.get("result", {}).get("response", {})

    # ── Destination operations ─────────────────────────────────────────

    def list_destinations(self, search: str = "") -> list[SyslogDestinationInfo]:
        response = self._api_get("settings", "searchDestinations")
        rows = response.get("rows", [])
        items = [SyslogDestinationInfo.from_api_response(row) for row in rows]
        if search:
            needle = search.lower()
            items = [
                d for d in items
                if needle in (d.description or "").lower()
                or needle in (d.hostname or "").lower()
            ]
        return items

    def get_destination_by_description(self, description: str) -> SyslogDestinationInfo | None:
        if not description:
            return None
        for d in self.list_destinations():
            if d.description == description:
                return d
        return None

    @staticmethod
    def _to_payload(dest: SyslogDestination) -> dict:
        return {
            "destination": {
                "enabled": "1" if dest.enabled else "0",
                "transport": dest.transport,
                "program": dest.program,
                "level": dest.level,
                "facility": dest.facility,
                "hostname": dest.hostname,
                "certificate": dest.certificate,
                "port": str(dest.port),
                "rfc5424": "1" if dest.rfc5424 else "0",
                "description": dest.description,
            }
        }

    def add_destination(self, dest: SyslogDestination) -> dict:
        return self._api_post("settings", "addDestination", self._to_payload(dest))

    def update_destination(self, uuid: str, dest: SyslogDestination) -> dict:
        return self._api_post(
            "settings", "setDestination", self._to_payload(dest), url_params=[uuid]
        )

    def delete_destination(self, uuid: str) -> dict:
        return self._api_post("settings", "delDestination", url_params=[uuid])

    # ── Service operations ─────────────────────────────────────────────

    def reconfigure(self) -> dict:
        """Apply pending syslog changes (re-render config + bounce syslogd)."""
        return self._api_post("service", "reconfigure")
