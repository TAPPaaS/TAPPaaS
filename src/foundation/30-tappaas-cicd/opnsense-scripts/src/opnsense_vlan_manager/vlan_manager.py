"""VLAN management operations for OPNsense."""

from dataclasses import dataclass
from oxl_opnsense_client import Client

from .config import Config


@dataclass
class Vlan:
    """VLAN configuration."""

    description: str
    tag: int
    interface: str
    priority: int = 0
    device: str | None = None


class VlanManager:
    """Manage VLANs on OPNsense firewall."""

    def __init__(self, config: Config):
        self.config = config
        self._client: Client | None = None

    def _get_client_kwargs(self) -> dict:
        """Build client connection kwargs from config."""
        kwargs = {
            "firewall": self.config.firewall,
            "ssl_verify": self.config.ssl_verify,
            "debug": self.config.debug,
        }

        if self.config.credential_file:
            kwargs["credential_file"] = self.config.credential_file
        elif self.config.token and self.config.secret:
            kwargs["token"] = self.config.token
            kwargs["secret"] = self.config.secret

        if self.config.ssl_ca_file:
            kwargs["ssl_ca_file"] = self.config.ssl_ca_file

        return kwargs

    def connect(self) -> "VlanManager":
        """Establish connection to OPNsense."""
        self._client = Client(**self._get_client_kwargs())
        return self

    def disconnect(self):
        """Close connection to OPNsense."""
        if self._client:
            self._client.close()
            self._client = None

    def __enter__(self) -> "VlanManager":
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

    def list_modules(self) -> list[str]:
        """List all available modules."""
        return self.client.list_modules()

    def get_vlan_spec(self) -> dict:
        """Get the specification for the interface_vlan module."""
        return self.client.module_specs("interface_vlan")

    def create_vlan(self, vlan: Vlan, check_mode: bool = False) -> dict:
        """Create a new VLAN.

        Args:
            vlan: VLAN configuration
            check_mode: If True, perform dry-run without making changes

        Returns:
            Result dictionary from the API
        """
        params = {
            "description": vlan.description,
            "vlan": vlan.tag,
            "interface": vlan.interface,
            "priority": vlan.priority,
        }

        if vlan.device:
            params["device"] = vlan.device

        return self.client.run_module(
            "interface_vlan",
            check_mode=check_mode,
            params=params,
        )

    def update_vlan(
        self,
        vlan: Vlan,
        match_fields: list[str] | None = None,
        check_mode: bool = False,
    ) -> dict:
        """Update an existing VLAN.

        Args:
            vlan: VLAN configuration with updated values
            match_fields: Fields to match on (default: ["description"])
            check_mode: If True, perform dry-run without making changes

        Returns:
            Result dictionary from the API
        """
        if match_fields is None:
            match_fields = ["description"]

        params = {
            "description": vlan.description,
            "vlan": vlan.tag,
            "interface": vlan.interface,
            "priority": vlan.priority,
            "match_fields": match_fields,
        }

        if vlan.device:
            params["device"] = vlan.device

        return self.client.run_module(
            "interface_vlan",
            check_mode=check_mode,
            params=params,
        )

    def delete_vlan(
        self,
        description: str,
        match_fields: list[str] | None = None,
        check_mode: bool = False,
    ) -> dict:
        """Delete a VLAN.

        Args:
            description: Description of the VLAN to delete
            match_fields: Fields to match on (default: ["description"])
            check_mode: If True, perform dry-run without making changes

        Returns:
            Result dictionary from the API
        """
        if match_fields is None:
            match_fields = ["description"]

        params = {
            "description": description,
            "state": "absent",
            "match_fields": match_fields,
        }

        return self.client.run_module(
            "interface_vlan",
            check_mode=check_mode,
            params=params,
        )

    def create_multiple_vlans(
        self,
        vlans: list[Vlan],
        check_mode: bool = False,
    ) -> list[dict]:
        """Create multiple VLANs.

        Args:
            vlans: List of VLAN configurations
            check_mode: If True, perform dry-run without making changes

        Returns:
            List of result dictionaries from the API
        """
        results = []
        for vlan in vlans:
            result = self.create_vlan(vlan, check_mode=check_mode)
            results.append(result)
        return results
