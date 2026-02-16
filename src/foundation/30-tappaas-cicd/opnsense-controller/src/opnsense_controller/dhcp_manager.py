"""DHCP management operations for OPNsense Dnsmasq service."""

from dataclasses import dataclass, field
from oxl_opnsense_client import Client

from .config import Config


def _convert_bools_to_int(params):
    """Convert all boolean values in params to 0/1 for OPNsense API.

    OPNsense API expects boolean values as integers (0 or 1), not Python booleans.
    This recursively converts all boolean values in the params structure.

    Args:
        params: Dictionary, list, or other value that may contain boolean values

    Returns:
        Structure with booleans converted to integers
    """
    if isinstance(params, bool):
        return 1 if params else 0
    elif isinstance(params, dict):
        result = {}
        for key, value in params.items():
            result[key] = _convert_bools_to_int(value)
        return result
    elif isinstance(params, list):
        return [_convert_bools_to_int(item) for item in params]
    else:
        return params


@dataclass
class DhcpRange:
    """DHCP range configuration for Dnsmasq."""

    description: str
    start_addr: str
    end_addr: str
    interface: str | None = None  # Interface to serve this range (e.g., 'opt1')
    subnet_mask: str | None = None  # Leave None to auto-calculate
    lease_time: int = 86400  # Default 24 hours in seconds
    domain: str | None = None  # Domain to offer to DHCP clients
    set_tag: str | None = None  # Tag to set for matching requests


@dataclass
class DhcpHost:
    """Static DHCP host reservation for Dnsmasq."""

    description: str
    host: str  # Hostname without domain
    ip: list[str] = field(default_factory=list)  # IP addresses
    hardware_addr: list[str] = field(default_factory=list)  # MAC addresses
    domain: str | None = None  # Domain of the host
    lease_time: int | None = None  # Lease time in seconds
    set_tag: str | None = None  # Tag to set for matching requests
    ignore: bool = False  # Ignore DHCP packets from this host


class DhcpManager:
    """Manage DHCP settings on OPNsense Dnsmasq service."""

    def __init__(self, config: Config):
        self.config = config
        self._client: Client | None = None

    def _get_client_kwargs(self) -> dict:
        """Build client connection kwargs from config."""
        kwargs = {
            "firewall": self.config.firewall,
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

    def connect(self) -> "DhcpManager":
        """Establish connection to OPNsense."""
        self._client = Client(**self._get_client_kwargs())
        return self

    def disconnect(self):
        """Close connection to OPNsense."""
        self._client = None

    def __enter__(self) -> "DhcpManager":
        return self.connect()

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.disconnect()

    @property
    def client(self) -> Client:
        """Get the active client, raising if not connected."""
        if not self._client:
            raise RuntimeError("Not connected. Use connect() or context manager.")
        return self._client

    def _run_module_with_bool_conversion(
        self,
        module: str,
        check_mode: bool = False,
        params: dict | None = None,
    ) -> dict:
        """Wrapper around client.run_module that converts all booleans to 0/1.

        The OPNsense API expects boolean values as integers (0 or 1).
        The oxl-opnsense-client library fetches current settings and merges
        with our params, but those current settings have Python booleans that
        need conversion before sending to the API.

        Args:
            module: Module name to run
            check_mode: If True, perform dry-run
            params: Parameters to pass to the module

        Returns:
            Result dictionary from the API
        """
        if params is not None:
            params = _convert_bools_to_int(params)

        return self.client.run_module(
            module,
            check_mode=check_mode,
            params=params or {},
        )

    def test_connection(self) -> bool:
        """Test the connection to OPNsense."""
        return self.client.test()

    def get_range_spec(self) -> dict:
        """Get the specification for the dnsmasq_range module."""
        return self.client.module_specs("dnsmasq_range")

    def get_host_spec(self) -> dict:
        """Get the specification for the dnsmasq_host module."""
        return self.client.module_specs("dnsmasq_host")

    def get_general_spec(self) -> dict:
        """Get the specification for the dnsmasq_general module."""
        return self.client.module_specs("dnsmasq_general")

    def list_ranges(self) -> list[dict]:
        """List all configured DHCP ranges.

        Returns list of dicts with uuid, description, start_addr, end_addr, interface, domain, etc.
        """
        result = self.client.run_module(
            "raw",
            params={
                "module": "dnsmasq",
                "controller": "settings",
                "command": "searchRange",
                "action": "get",
            },
        )
        rows = result.get("result", {}).get("response", {}).get("rows", [])
        ranges = []
        for row in rows:
            ranges.append({
                "uuid": row.get("uuid"),
                "description": row.get("description"),
                "start_addr": row.get("start_addr"),
                "end_addr": row.get("end_addr"),
                "interface": row.get("interface"),
                "domain": row.get("domain"),
                "lease_time": row.get("lease_time"),
                "set_tag": row.get("set_tag"),
            })
        return ranges

    def get_range_by_description(self, description: str) -> dict | None:
        """Get a DHCP range by its description.

        Args:
            description: Description to search for

        Returns:
            DHCP range dict if found, None otherwise
        """
        ranges = self.list_ranges()
        for dhcp_range in ranges:
            if dhcp_range["description"] == description:
                return dhcp_range
        return None

    def list_hosts(self) -> list[dict]:
        """List all configured DHCP host reservations.

        Returns list of dicts with uuid, description, host, ip, hardware_addr, domain, etc.
        """
        result = self.client.run_module(
            "raw",
            params={
                "module": "dnsmasq",
                "controller": "settings",
                "command": "searchHost",
                "action": "get",
            },
        )
        rows = result.get("result", {}).get("response", {}).get("rows", [])
        hosts = []
        for row in rows:
            hosts.append({
                "uuid": row.get("uuid"),
                "description": row.get("descr"),  # API field is 'descr' not 'description'
                "host": row.get("host"),
                "ip": row.get("ip"),
                "hardware_addr": row.get("hardware_addr"),
                "domain": row.get("domain"),
            })
        return hosts

    def get_host_by_description(self, description: str) -> dict | None:
        """Get a DHCP host by its description.

        Args:
            description: Description to search for

        Returns:
            DHCP host dict if found, None otherwise
        """
        hosts = self.list_hosts()
        for host in hosts:
            if host["description"] == description:
                return host
        return None

    # =========================================================================
    # DHCP Range Operations
    # =========================================================================

    def create_range(self, dhcp_range: DhcpRange, check_mode: bool = False) -> dict:
        """Create a new DHCP range.

        Args:
            dhcp_range: DHCP range configuration
            check_mode: If True, perform dry-run without making changes

        Returns:
            Result dictionary from the API
        """
        params = {
            "description": dhcp_range.description,
            "start_addr": dhcp_range.start_addr,
            "end_addr": dhcp_range.end_addr,
            "lease_time": dhcp_range.lease_time,
        }

        if dhcp_range.interface:
            params["interface"] = dhcp_range.interface
        if dhcp_range.subnet_mask:
            params["subnet_mask"] = dhcp_range.subnet_mask
        if dhcp_range.domain:
            params["domain"] = dhcp_range.domain
        if dhcp_range.set_tag:
            params["set_tag"] = dhcp_range.set_tag

        return self.client.run_module(
            "dnsmasq_range",
            check_mode=check_mode,
            params=params,
        )

    def update_range(self, dhcp_range: DhcpRange, check_mode: bool = False) -> dict:
        """Update an existing DHCP range (matched by description).

        Args:
            dhcp_range: DHCP range configuration with updated values
            check_mode: If True, perform dry-run without making changes

        Returns:
            Result dictionary from the API
        """
        # Same as create - the module handles updates by matching description
        return self.create_range(dhcp_range, check_mode=check_mode)

    def delete_range(self, description: str, check_mode: bool = False) -> dict:
        """Delete a DHCP range by description.

        Args:
            description: Description of the DHCP range to delete
            check_mode: If True, perform dry-run without making changes

        Returns:
            Result dictionary from the API
        """
        params = {
            "description": description,
            "state": "absent",
        }

        return self.client.run_module(
            "dnsmasq_range",
            check_mode=check_mode,
            params=params,
        )

    def create_multiple_ranges(
        self,
        ranges: list[DhcpRange],
        check_mode: bool = False,
    ) -> list[dict]:
        """Create multiple DHCP ranges.

        Args:
            ranges: List of DHCP range configurations
            check_mode: If True, perform dry-run without making changes

        Returns:
            List of result dictionaries from the API
        """
        results = []
        for dhcp_range in ranges:
            result = self.create_range(dhcp_range, check_mode=check_mode)
            results.append(result)
        return results

    # =========================================================================
    # DHCP Host (Static Reservation) Operations
    # =========================================================================

    def create_host(self, host: DhcpHost, check_mode: bool = False) -> dict:
        """Create a static DHCP host reservation.

        Args:
            host: DHCP host configuration
            check_mode: If True, perform dry-run without making changes

        Returns:
            Result dictionary from the API
        """
        params = {
            "description": host.description,
            "host": host.host,
        }

        if host.ip:
            params["ip"] = host.ip
        if host.hardware_addr:
            params["hardware_addr"] = host.hardware_addr
        if host.domain:
            params["domain"] = host.domain
        if host.lease_time:
            params["lease_time"] = host.lease_time
        if host.set_tag:
            params["set_tag"] = host.set_tag
        if host.ignore:
            params["ignore"] = host.ignore

        # Convert booleans to 0/1 for OPNsense API compatibility
        params = _convert_bools_to_int(params)

        return self.client.run_module(
            "dnsmasq_host",
            check_mode=check_mode,
            params=params,
        )

    def update_host(self, host: DhcpHost, check_mode: bool = False) -> dict:
        """Update an existing DHCP host reservation (matched by description).

        Args:
            host: DHCP host configuration with updated values
            check_mode: If True, perform dry-run without making changes

        Returns:
            Result dictionary from the API
        """
        return self.create_host(host, check_mode=check_mode)

    def delete_host(self, description: str, check_mode: bool = False, host: str = None, domain: str = None) -> dict:
        """Delete a DHCP host reservation by description.

        Args:
            description: Description of the DHCP host to delete
            check_mode: If True, perform dry-run without making changes
            host: Optional hostname for matching entries without description
            domain: Optional domain for matching entries without description

        Returns:
            Result dictionary from the API
        """
        params = {
            "description": description,
            "state": "absent",
        }

        # If host and domain are provided, include them to help match entries
        if host:
            params["host"] = host
        if domain:
            params["domain"] = domain

        return self.client.run_module(
            "dnsmasq_host",
            check_mode=check_mode,
            params=params,
        )

    def delete_host_by_uuid(self, uuid: str, check_mode: bool = False) -> dict:
        """Delete a DHCP host reservation by UUID using the raw API.

        Args:
            uuid: UUID of the DHCP host to delete
            check_mode: If True, perform dry-run without making changes

        Returns:
            Result dictionary from the API
        """
        if check_mode:
            return {"changed": True, "uuid": uuid, "check_mode": True}

        # Use raw API to delete by UUID
        result = self.client.run_module(
            "raw",
            params={
                "module": "dnsmasq",
                "controller": "settings",
                "command": "delHost",
                "params": [uuid],
                "action": "post",
            },
        )

        # Apply configuration after deletion
        if result.get("result", {}).get("response", {}).get("result") == "deleted":
            self.client.run_module(
                "raw",
                params={
                    "module": "dnsmasq",
                    "controller": "service",
                    "command": "reconfigure",
                    "action": "post",
                },
            )
            return {"changed": True, "uuid": uuid}

        return {"changed": False, "error": result}

    def create_multiple_hosts(
        self,
        hosts: list[DhcpHost],
        check_mode: bool = False,
    ) -> list[dict]:
        """Create multiple static DHCP host reservations.

        Args:
            hosts: List of DHCP host configurations
            check_mode: If True, perform dry-run without making changes

        Returns:
            List of result dictionaries from the API
        """
        results = []
        for host in hosts:
            result = self.create_host(host, check_mode=check_mode)
            results.append(result)
        return results

    # =========================================================================
    # Dnsmasq Service Configuration
    # =========================================================================

    def enable_service(
        self,
        interfaces: list[str] | None = None,
        dhcp_authoritative: bool = True,
        check_mode: bool = False,
    ) -> dict:
        """Enable and configure the Dnsmasq service.

        Args:
            interfaces: List of interface IDs to listen on (None for all)
            dhcp_authoritative: Set to True if this is the only DHCP server
            check_mode: If True, perform dry-run without making changes

        Returns:
            Result dictionary from the API
        """
        if check_mode:
            return {"changed": True, "check_mode": True}

        # Build minimal params - just what we need to change
        params = {
            "enabled": 1,  # Use 0/1 instead of True/False
            "dhcp_authoritative": 1 if dhcp_authoritative else 0,
        }

        if interfaces:
            params["interfaces"] = interfaces  # Pass as list, let the client handle it

        # Use dnsmasq_general module
        return self.client.run_module(
            "dnsmasq_general",
            check_mode=False,
            params=params,
        )

    def set_dnsmasq_interfaces(
        self,
        interfaces: list[str],
        check_mode: bool = False,
    ) -> dict:
        """Set dnsmasq interfaces using direct API call.

        Bypasses the oxl-opnsense-client dnsmasq_general module to avoid
        boolean conversion issues when the library fetches and merges
        current settings.

        Args:
            interfaces: List of interface IDs (e.g. ['lan', 'opt1', 'opt2'])
            check_mode: If True, perform dry-run without making changes

        Returns:
            Result dictionary with status
        """
        if check_mode:
            return {"changed": True, "check_mode": True, "interfaces": interfaces}

        iface_str = ",".join(interfaces)

        # Use raw module to call the dnsmasq settings API directly
        set_result = self.client.run_module(
            "raw",
            params={
                "module": "dnsmasq",
                "controller": "settings",
                "command": "set",
                "action": "post",
                "data": {"dnsmasq": {"interface": iface_str}},
            },
        )

        # Reconfigure the service to apply changes
        reconfigure_result = self.client.run_module(
            "raw",
            params={
                "module": "dnsmasq",
                "controller": "service",
                "command": "reconfigure",
                "action": "post",
            },
        )

        return {
            "changed": True,
            "interfaces": interfaces,
            "set_result": set_result,
            "reconfigure_result": reconfigure_result,
        }

    def disable_service(self, check_mode: bool = False) -> dict:
        """Disable the Dnsmasq service.

        Args:
            check_mode: If True, perform dry-run without making changes

        Returns:
            Result dictionary from the API
        """
        params = {
            "enabled": False,
        }

        # Convert booleans to 0/1 for OPNsense API compatibility
        params = _convert_bools_to_int(params)

        return self.client.run_module(
            "dnsmasq_general",
            check_mode=check_mode,
            params=params,
        )

    def configure_general(
        self,
        enabled: bool = True,
        interfaces: list[str] | None = None,
        dhcp_authoritative: bool = False,
        dhcp_fqdn: bool = False,
        dhcp_domain: str | None = None,
        regdhcp: bool = False,
        regdhcpstatic: bool = False,
        check_mode: bool = False,
    ) -> dict:
        """Configure general Dnsmasq settings.

        Args:
            enabled: Enable/disable the service
            interfaces: List of interface IDs to listen on
            dhcp_authoritative: Set if this is the only DHCP server
            dhcp_fqdn: Register DHCP client FQDNs in DNS
            dhcp_domain: Domain for DHCP hostname registration
            regdhcp: Register DHCP hostnames in DNS
            regdhcpstatic: Register static DHCP mappings in DNS
            check_mode: If True, perform dry-run without making changes

        Returns:
            Result dictionary from the API
        """
        params = {
            "enabled": enabled,
            "dhcp_authoritative": dhcp_authoritative,
            "dhcp_fqdn": dhcp_fqdn,
            "regdhcp": regdhcp,
            "regdhcpstatic": regdhcpstatic,
        }

        if interfaces is not None:
            params["interfaces"] = interfaces
        if dhcp_domain:
            params["dhcp_domain"] = dhcp_domain

        # Convert booleans to 0/1 for OPNsense API compatibility
        params = _convert_bools_to_int(params)

        return self.client.run_module(
            "dnsmasq_general",
            check_mode=check_mode,
            params=params,
        )
