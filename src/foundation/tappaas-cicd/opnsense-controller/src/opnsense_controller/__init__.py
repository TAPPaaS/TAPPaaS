"""OPNsense Controller for TAPPaaS using oxl-opnsense-client."""

from .caddy_manager import (
    CaddyDomain,
    CaddyDomainInfo,
    CaddyHandler,
    CaddyHandlerInfo,
    CaddyManager,
)
from .config import Config
from .dhcp_manager import DhcpHost, DhcpManager, DhcpRange
from .firewall_manager import (
    FirewallManager,
    FirewallRule,
    FirewallRuleInfo,
    IpProtocol,
    Protocol,
    RuleAction,
    RuleDirection,
)
from .firewall_rules_manager import (
    AliasSpec,
    EgressRule,
    FirewallRulesManager,
    IngressRule,
    ModuleFirewallSpec,
    PortSpec,
    ValidationError,
)
from .vlan_manager import Vlan, VlanManager
from .zone_manager import Zone, ZoneManager

__all__ = [
    "AliasSpec",
    "CaddyDomain",
    "CaddyDomainInfo",
    "CaddyHandler",
    "CaddyHandlerInfo",
    "CaddyManager",
    "Config",
    "DhcpHost",
    "DhcpManager",
    "DhcpRange",
    "EgressRule",
    "FirewallManager",
    "FirewallRule",
    "FirewallRuleInfo",
    "FirewallRulesManager",
    "IngressRule",
    "IpProtocol",
    "ModuleFirewallSpec",
    "PortSpec",
    "Protocol",
    "RuleAction",
    "RuleDirection",
    "ValidationError",
    "Vlan",
    "VlanManager",
    "Zone",
    "ZoneManager",
]
