"""OPNsense VLAN Manager - Example project using oxl-opnsense-client."""

from .config import Config
from .vlan_manager import Vlan, VlanManager

__all__ = ["Config", "Vlan", "VlanManager"]
