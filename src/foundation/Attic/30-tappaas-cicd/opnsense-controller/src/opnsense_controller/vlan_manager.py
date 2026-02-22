"""VLAN management operations for OPNsense.

Interface assignment requires a custom PHP extension to be installed on OPNsense.
See: https://github.com/opnsense/core/issues/7324#issuecomment-2830694222
Install: https://gist.github.com/szymczag/df152a82e86aff67b984ed3786b027ba
"""

from dataclasses import dataclass
from oxl_opnsense_client import Client

from .config import Config


@dataclass
class Vlan:
    """VLAN configuration."""

    description: str
    tag: int
    interface: str  # Parent interface (e.g., vtnet0)
    priority: int = 0
    device: str | None = None  # VLAN device name (e.g., vlan0.100)


class VlanManager:
    """Manage VLANs on OPNsense firewall."""

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

    def connect(self) -> "VlanManager":
        """Establish connection to OPNsense."""
        self._client = Client(**self._get_client_kwargs())
        return self

    def disconnect(self):
        """Close connection to OPNsense."""
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

    def get_interfaces_info(self) -> dict:
        """Get information about all interfaces.

        Returns a dict with interface details including:
        - device: Physical device name (e.g., vtnet0, vlan0.100)
        - identifier: OPNsense interface name (e.g., lan, wan, opt1)
        - description: Human-readable description
        - enabled: Whether the interface is enabled
        - vlan_tag: VLAN tag if this is a VLAN interface
        """
        result = self.client.run_module(
            "raw",
            params={
                "module": "interfaces",
                "controller": "overview",
                "command": "interfacesInfo",
                "action": "get",
            },
        )
        return result.get("result", {}).get("response", {})

    def get_assigned_vlans(self) -> list[dict]:
        """Get list of VLANs that are assigned to interfaces.

        Returns list of dicts with vlan_tag, device, identifier, description, enabled.
        """
        info = self.get_interfaces_info()
        vlans = []
        for iface in info.get("rows", []):
            if iface.get("vlan_tag"):
                vlans.append({
                    "vlan_tag": iface["vlan_tag"],
                    "device": iface.get("device"),
                    "identifier": iface.get("identifier"),
                    "description": iface.get("description"),
                    "enabled": iface.get("enabled", False),
                })
        return vlans

    def list_vlans(self) -> list[dict]:
        """List all configured VLAN devices (including unassigned ones).

        Returns list of dicts with uuid, device, tag, interface, description, priority.
        """
        result = self.client.run_module(
            "raw",
            params={
                "module": "interfaces",
                "controller": "vlan_settings",
                "command": "searchItem",
                "action": "get",
            },
        )
        rows = result.get("result", {}).get("response", {}).get("rows", [])
        vlans = []
        for row in rows:
            vlans.append({
                "uuid": row.get("uuid"),
                "device": row.get("vlanif"),
                "tag": int(row.get("tag", 0)),
                "interface": row.get("if"),
                "description": row.get("descr"),
                "priority": int(row.get("pcp", 0)),
            })
        return vlans

    def get_vlan_by_tag(self, tag: int) -> dict | None:
        """Get a VLAN by its tag number.

        Args:
            tag: VLAN tag to search for

        Returns:
            VLAN dict if found, None otherwise
        """
        vlans = self.list_vlans()
        for vlan in vlans:
            if vlan["tag"] == tag:
                return vlan
        return None

    def get_vlan_by_description(self, description: str) -> dict | None:
        """Get a VLAN by its description.

        Args:
            description: Description to search for

        Returns:
            VLAN dict if found, None otherwise
        """
        vlans = self.list_vlans()
        for vlan in vlans:
            if vlan["description"] == description:
                return vlan
        return None

    def assign_interface(
        self,
        device: str,
        description: str,
        enable: bool = True,
        ipv4_type: str | None = None,
        ipv4_address: str | None = None,
        ipv4_subnet: int | None = None,
    ) -> dict:
        """Assign a device to a new OPNsense interface and optionally enable it.

        Requires the custom AssignSettingsController PHP extension to be installed.
        See: https://gist.github.com/szymczag/df152a82e86aff67b984ed3786b027ba

        Args:
            device: Device name to assign (e.g., 'vlan0.100')
            description: Interface description
            enable: Whether to enable the interface (default: True)
            ipv4_type: IPv4 configuration type ('static', 'dhcp', or None)
            ipv4_address: IPv4 address (required if ipv4_type is 'static')
            ipv4_subnet: IPv4 subnet mask (required if ipv4_type is 'static')

        Returns:
            Result dictionary with 'ifname' (e.g., 'opt1') on success
        """
        data = {
            "assign": {
                "device": device,
                "description": description,
                "enable": enable,
            }
        }

        if ipv4_type:
            data["assign"]["ipv4Type"] = ipv4_type
            if ipv4_type == "static":
                if ipv4_address:
                    data["assign"]["ipv4Address"] = ipv4_address
                if ipv4_subnet:
                    data["assign"]["ipv4Subnet"] = ipv4_subnet

        result = self.client.run_module(
            "raw",
            params={
                "module": "interfaces",
                "controller": "interface_assign",
                "command": "addItem",
                "action": "post",
                "data": data,
            },
        )
        return result

    def reload_interface(self, identifier: str) -> dict:
        """Reload an interface to apply its configuration (IP address, etc).

        After assigning a VLAN to an interface with a static IP, the IP
        is written to config but not applied until the interface is reloaded.

        Args:
            identifier: Interface identifier (e.g., 'opt1', 'opt5')

        Returns:
            Result dictionary from the API
        """
        result = self.client.run_module(
            "raw",
            params={
                "module": "interfaces",
                "controller": "overview",
                "command": f"reloadInterface/{identifier}",
                "action": "post",
            },
        )
        return result

    def unassign_interface(self, identifier: str) -> dict:
        """Remove an interface assignment.

        Args:
            identifier: Interface identifier (e.g., 'opt1')

        Returns:
            Result dictionary
        """
        result = self.client.run_module(
            "raw",
            params={
                "module": "interfaces",
                "controller": "interface_assign",
                "command": f"delItem/{identifier}",
                "action": "post",  # DELETE method via POST
            },
        )
        return result

    def create_vlan(
        self,
        vlan: Vlan,
        check_mode: bool = False,
        assign: bool = False,
        enable: bool = True,
        interface_name: str | None = None,
        ipv4_type: str | None = None,
        ipv4_address: str | None = None,
        ipv4_subnet: int | None = None,
    ) -> dict:
        """Create a new VLAN device and optionally assign it to an interface.

        Args:
            vlan: VLAN configuration
            check_mode: If True, perform dry-run without making changes
            assign: If True, also assign the VLAN to an interface and enable it
            enable: If True and assign=True, enable the interface (default: True)
            interface_name: Name for the assigned interface (default: use VLAN description)
            ipv4_type: IPv4 configuration type ('static', 'dhcp', or None)
            ipv4_address: IPv4 address (required if ipv4_type is 'static')
            ipv4_subnet: IPv4 subnet mask (required if ipv4_type is 'static')

        Returns:
            Result dictionary from the API
        """
        params = {
            "description": vlan.description,
            "vlan": vlan.tag,
            "interface": vlan.interface,
            "priority": vlan.priority,
        }

        device_name = vlan.device or f"vlan0.{vlan.tag}"
        if vlan.device:
            params["device"] = vlan.device

        result = self.client.run_module(
            "interface_vlan",
            check_mode=check_mode,
            params=params,
        )

        # If assign is requested and not in check mode, assign the interface
        if assign and not check_mode:
            # Use interface_name if provided, otherwise fall back to VLAN description
            iface_desc = interface_name or vlan.description
            assign_result = self.assign_interface(
                device=device_name,
                description=iface_desc,
                enable=enable,
                ipv4_type=ipv4_type,
                ipv4_address=ipv4_address,
                ipv4_subnet=ipv4_subnet,
            )
            result["assign_result"] = assign_result
            response = assign_result.get("result", {}).get("response", {})
            if response.get("result") == "saved":
                ifname = response.get("ifname")
                result["ifname"] = ifname
                # Reload the interface to apply IP configuration
                if ifname:
                    reload_result = self.reload_interface(ifname)
                    result["reload_result"] = reload_result

        return result

    def update_vlan(
        self,
        vlan: Vlan,
        check_mode: bool = False,
    ) -> dict:
        """Update an existing VLAN (matched by description).

        Args:
            vlan: VLAN configuration with updated values
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

    def delete_vlan(
        self,
        description: str,
        check_mode: bool = False,
    ) -> dict:
        """Delete a VLAN by description.

        Args:
            description: Description of the VLAN to delete
            check_mode: If True, perform dry-run without making changes

        Returns:
            Result dictionary from the API
        """
        params = {
            "description": description,
            "state": "absent",
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
        assign: bool = False,
        enable: bool = True,
    ) -> list[dict]:
        """Create multiple VLANs and optionally assign them to interfaces.

        Args:
            vlans: List of VLAN configurations
            check_mode: If True, perform dry-run without making changes
            assign: If True, also assign VLANs to interfaces and enable them
            enable: If True and assign=True, enable the interfaces (default: True)

        Returns:
            List of result dictionaries from the API
        """
        results = []
        for vlan in vlans:
            result = self.create_vlan(vlan, check_mode=check_mode, assign=assign, enable=enable)
            results.append(result)
        return results
