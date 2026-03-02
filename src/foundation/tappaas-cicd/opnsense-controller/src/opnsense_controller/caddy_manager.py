"""Caddy reverse proxy management operations for OPNsense."""

from dataclasses import dataclass
from oxl_opnsense_client import Client

from .config import Config


@dataclass
class CaddyDomain:
    """Caddy reverse proxy domain configuration."""

    domain: str
    description: str = ""
    enabled: bool = True


@dataclass
class CaddyHandler:
    """Caddy reverse proxy handler configuration."""

    domain_uuid: str
    upstream_domain: str
    upstream_port: str = "80"
    description: str = ""
    enabled: bool = True


@dataclass
class CaddyDomainInfo:
    """Information about an existing Caddy domain."""

    uuid: str
    domain: str
    description: str
    enabled: bool

    @classmethod
    def from_api_response(cls, data: dict) -> "CaddyDomainInfo":
        """Create from OPNsense API search response row."""
        return cls(
            uuid=data.get("uuid", ""),
            domain=data.get("FromDomain", ""),
            description=data.get("description", ""),
            enabled=data.get("enabled") == "1",
        )


@dataclass
class CaddyHandlerInfo:
    """Information about an existing Caddy handler."""

    uuid: str
    domain_uuid: str
    upstream_domain: str
    upstream_port: str
    description: str
    enabled: bool

    @classmethod
    def from_api_response(cls, data: dict) -> "CaddyHandlerInfo":
        """Create from OPNsense API search response row."""
        return cls(
            uuid=data.get("uuid", ""),
            domain_uuid=data.get("reverse", ""),
            upstream_domain=data.get("ToDomain", ""),
            upstream_port=data.get("ToPort", ""),
            description=data.get("description", ""),
            enabled=data.get("enabled") == "1",
        )


class CaddyManager:
    """Manage Caddy reverse proxy on OPNsense."""

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

    def connect(self) -> "CaddyManager":
        """Establish connection to OPNsense."""
        self._client = Client(**self._get_client_kwargs())
        return self

    def disconnect(self):
        """Close connection to OPNsense."""
        self._client = None

    def __enter__(self) -> "CaddyManager":
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

    def _api_get(self, controller: str, command: str) -> dict:
        """Execute a GET API call against the Caddy module."""
        result = self.client.run_module(
            "raw",
            params={
                "module": "caddy",
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
        """Execute a POST API call against the Caddy module."""
        params: dict = {
            "module": "caddy",
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

    # =========================================================================
    # Domain Operations
    # =========================================================================

    def list_domains(self, search: str = "") -> list[CaddyDomainInfo]:
        """List all Caddy reverse proxy domains.

        Args:
            search: Optional search string to filter results.

        Returns:
            List of CaddyDomainInfo objects.
        """
        response = self._api_get("ReverseProxy", "searchReverseProxy")
        rows = response.get("rows", [])

        domains = [CaddyDomainInfo.from_api_response(row) for row in rows]

        if search:
            search_lower = search.lower()
            domains = [
                d for d in domains
                if search_lower in d.domain.lower() or search_lower in d.description.lower()
            ]

        return domains

    def get_domain_by_name(self, domain_name: str) -> CaddyDomainInfo | None:
        """Find a domain by its FQDN.

        Args:
            domain_name: The domain name (e.g., "app.test.tapaas.org").

        Returns:
            CaddyDomainInfo if found, None otherwise.
        """
        for domain in self.list_domains():
            if domain.domain == domain_name:
                return domain
        return None

    def get_domain_by_description(self, description: str) -> CaddyDomainInfo | None:
        """Find a domain by its description.

        Args:
            description: The description to match exactly.

        Returns:
            CaddyDomainInfo if found, None otherwise.
        """
        for domain in self.list_domains():
            if domain.description == description:
                return domain
        return None

    def add_domain(self, domain: CaddyDomain) -> dict:
        """Add a new reverse proxy domain.

        Args:
            domain: Domain configuration.

        Returns:
            API response dict (contains 'uuid' on success).
        """
        data = {
            "reverse": {
                "enabled": "1" if domain.enabled else "0",
                "FromDomain": domain.domain,
                "description": domain.description,
            }
        }
        return self._api_post("ReverseProxy", "addReverseProxy", data)

    def update_domain(self, uuid: str, domain: CaddyDomain) -> dict:
        """Update an existing reverse proxy domain.

        Args:
            uuid: UUID of the domain to update.
            domain: New domain configuration.

        Returns:
            API response dict.
        """
        data = {
            "reverse": {
                "enabled": "1" if domain.enabled else "0",
                "FromDomain": domain.domain,
                "description": domain.description,
            }
        }
        return self._api_post("ReverseProxy", "setReverseProxy", data, url_params=[uuid])

    def delete_domain(self, uuid: str) -> dict:
        """Delete a reverse proxy domain.

        Args:
            uuid: UUID of the domain to delete.

        Returns:
            API response dict.
        """
        return self._api_post("ReverseProxy", "delReverseProxy", url_params=[uuid])

    # =========================================================================
    # Handler Operations
    # =========================================================================

    def list_handlers(self, search: str = "") -> list[CaddyHandlerInfo]:
        """List all Caddy reverse proxy handlers.

        Args:
            search: Optional search string to filter results.

        Returns:
            List of CaddyHandlerInfo objects.
        """
        response = self._api_get("ReverseProxy", "searchHandle")
        rows = response.get("rows", [])

        handlers = [CaddyHandlerInfo.from_api_response(row) for row in rows]

        if search:
            search_lower = search.lower()
            handlers = [
                h for h in handlers
                if search_lower in h.description.lower()
                or search_lower in h.upstream_domain.lower()
            ]

        return handlers

    def get_handler_by_description(self, description: str) -> CaddyHandlerInfo | None:
        """Find a handler by its description.

        Args:
            description: The description to match exactly.

        Returns:
            CaddyHandlerInfo if found, None otherwise.
        """
        for handler in self.list_handlers():
            if handler.description == description:
                return handler
        return None

    def add_handler(self, handler: CaddyHandler) -> dict:
        """Add a new reverse proxy handler.

        Args:
            handler: Handler configuration.

        Returns:
            API response dict (contains 'uuid' on success).
        """
        data = {
            "handle": {
                "enabled": "1" if handler.enabled else "0",
                "reverse": handler.domain_uuid,
                "HandleType": "handle",
                "HandleDirective": "reverse_proxy",
                "ToDomain": handler.upstream_domain,
                "ToPort": str(handler.upstream_port),
                "description": handler.description,
            }
        }
        return self._api_post("ReverseProxy", "addHandle", data)

    def update_handler(self, uuid: str, handler: CaddyHandler) -> dict:
        """Update an existing reverse proxy handler.

        Args:
            uuid: UUID of the handler to update.
            handler: New handler configuration.

        Returns:
            API response dict.
        """
        data = {
            "handle": {
                "enabled": "1" if handler.enabled else "0",
                "reverse": handler.domain_uuid,
                "HandleType": "handle",
                "HandleDirective": "reverse_proxy",
                "ToDomain": handler.upstream_domain,
                "ToPort": str(handler.upstream_port),
                "description": handler.description,
            }
        }
        return self._api_post("ReverseProxy", "setHandle", data, url_params=[uuid])

    def delete_handler(self, uuid: str) -> dict:
        """Delete a reverse proxy handler.

        Args:
            uuid: UUID of the handler to delete.

        Returns:
            API response dict.
        """
        return self._api_post("ReverseProxy", "delHandle", url_params=[uuid])

    # =========================================================================
    # Service Operations
    # =========================================================================

    def reconfigure(self) -> dict:
        """Reconfigure Caddy (regenerate Caddyfile and reload).

        Returns:
            API response dict.
        """
        return self._api_post("service", "reconfigure")
