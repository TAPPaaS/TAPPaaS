"""Test-network orchestration for OPNsense (issue #225).

A *test network* is a throwaway, isolated network served on a **dedicated
physical NIC** of the firewall VM rather than on the VLAN trunk that carries
the production zones. It exists so an operator can plug a switch/AP into a
spare port and get an isolated, internet-connected sandbox without touching
``zones.json`` or the trunk.

This module wires together the same primitives the production ``zone-manager``
uses — :class:`VlanManager` (interface assignment), :class:`DhcpManager`
(dnsmasq range) and :class:`FirewallManager` (rules) — but drives them from a
single physical device and a self-contained, removable rule set.

Routing policy (issue #225):
    * test  -> internet            : ALLOW (stateful; OPNsense automatic
                                      outbound NAT already covers RFC1918)
    * test  -> any internal RFC1918 : BLOCK (isolation — incl. mgmt)
    * mgmt  -> test                 : ALLOW (return traffic is stateful, so
                                      no reverse rule is needed and test-
                                      initiated traffic to mgmt stays blocked)

Every object created carries the :data:`DESC_PREFIX` description so that
``delete`` can find and remove exactly what ``create`` made, in reverse order.
"""

from __future__ import annotations

import ipaddress

from .config import Config
from .dhcp_manager import DhcpManager, DhcpRange
from .firewall_manager import FirewallManager, FirewallRule, RuleAction
from .log import debug, info, warn
from .vlan_manager import VlanManager

# Identifies every artefact (interface, DHCP range, firewall rule) this module
# owns. Used for idempotent create and clean reverse-order teardown.
DESC_PREFIX = "test-net"

# Internal RFC1918 ranges blocked from the test net so it can reach the
# internet but no production/mgmt network. Mirrors zone_manager.RFC1918_NETWORKS.
RFC1918_NETWORKS = [
    ("10.0.0.0/8", "rfc1918-10"),
    ("172.16.0.0/12", "rfc1918-172"),
    ("192.168.0.0/16", "rfc1918-192"),
]


class TestNetworkError(RuntimeError):
    """Raised when the test network cannot be created or torn down."""


class TestNetworkManager:
    """Create and tear down an isolated test network on a dedicated device."""

    def __init__(
        self,
        config: Config,
        device: str,
        cidr: str = "172.17.3.1/24",
        dhcp_start: str | None = None,
        dhcp_end: str | None = None,
        mgmt_net: str = "10.0.0.0/24",
        mgmt_iface: str = "lan",
        domain: str = "test.internal",
    ):
        """
        Args:
            config: OPNsense API configuration.
            device: Guest network device backing the test net (e.g. ``vtnet2``).
            cidr: Gateway address + prefix for the test net (default
                ``172.17.3.1/24``). The host bits are the OPNsense interface IP.
            dhcp_start / dhcp_end: DHCP pool bounds. Default to ``.50``/``.250``
                of the test network.
            mgmt_net: Management network permitted to initiate to the test net.
            mgmt_iface: OPNsense interface identifier the mgmt net arrives on.
            domain: DHCP domain offered to clients.
        """
        self.config = config
        self.device = device
        self.mgmt_net = mgmt_net
        self.mgmt_iface = mgmt_iface
        self.domain = domain

        iface = ipaddress.ip_interface(cidr)
        self.gateway_ip = str(iface.ip)
        self.prefix_len = iface.network.prefixlen
        self.network = iface.network
        self.network_cidr = str(iface.network)

        # Default pool .50–.250 (issue #225); fall back to quartile bounds on
        # subnets too small to hold those offsets.
        hosts = list(self.network.hosts())
        if len(hosts) >= 250:
            default_start = str(self.network.network_address + 50)
            default_end = str(self.network.network_address + 250)
        else:
            default_start = str(hosts[len(hosts) // 4])
            default_end = str(hosts[-5])
        self.dhcp_start = dhcp_start or default_start
        self.dhcp_end = dhcp_end or default_end

    # ── description helpers ──────────────────────────────────────────
    @property
    def iface_description(self) -> str:
        return f"{DESC_PREFIX}"

    @property
    def dhcp_description(self) -> str:
        return f"{DESC_PREFIX} DHCP"

    # ── interface lookup ─────────────────────────────────────────────
    def _find_assigned_identifier(self) -> str | None:
        """Return the OPNsense identifier (e.g. ``opt2``) for our test device.

        Matches first on the backing device, then on our description, so it
        works both right after assignment and on a later teardown run.
        """
        with VlanManager(self.config) as mgr:
            info_rows = mgr.get_interfaces_info().get("rows", [])
        for row in info_rows:
            if row.get("device") == self.device:
                return row.get("identifier")
        for row in info_rows:
            if row.get("description") == self.iface_description:
                return row.get("identifier")
        return None

    # ── dnsmasq interface set helpers ────────────────────────────────
    def _get_dnsmasq_interfaces(self, dhcp: DhcpManager) -> list[str]:
        """Read the current dnsmasq listen-interface list (CSV) from OPNsense."""
        result = dhcp.client.run_module(
            "raw",
            params={
                "module": "dnsmasq",
                "controller": "settings",
                "command": "get",
                "action": "get",
            },
        )
        response = result.get("result", {}).get("response", {})
        raw = response.get("dnsmasq", {}).get("interface", "")
        # OPNsense returns either a CSV string or a {value: {selected: 1}} map.
        if isinstance(raw, dict):
            return [k for k, v in raw.items() if isinstance(v, dict) and v.get("selected")]
        return [i for i in str(raw).split(",") if i]

    # =================================================================
    # CREATE
    # =================================================================
    def create(self, check_mode: bool = False) -> dict:
        """Assign the interface, enable DHCP and install the firewall rules."""
        result: dict = {"device": self.device, "network": self.network_cidr}

        # 1. Assign the physical device to an OPNsense interface with a static IP.
        info(f"Assigning {self.device} → static {self.gateway_ip}/{self.prefix_len}")
        if check_mode:
            result["interface"] = "<would-assign>"
        else:
            with VlanManager(self.config) as vlan:
                existing = self._find_assigned_identifier()
                if existing:
                    debug(f"  Interface already assigned as {existing}")
                    ifname = existing
                else:
                    assign = vlan.assign_interface(
                        device=self.device,
                        description=self.iface_description,
                        enable=True,
                        ipv4_type="static",
                        ipv4_address=self.gateway_ip,
                        ipv4_subnet=self.prefix_len,
                    )
                    response = assign.get("result", {}).get("response", {})
                    ifname = response.get("ifname")
                    if not ifname:
                        # Fall back to looking it up by device/description.
                        ifname = self._find_assigned_identifier()
                    if not ifname:
                        raise TestNetworkError(
                            f"Interface assignment for {self.device} returned no "
                            f"identifier: {assign}"
                        )
                vlan.reload_interface(ifname)
            result["interface"] = ifname

        ifname = result["interface"]

        # 2. DHCP — add our interface to the dnsmasq listen set and create a range.
        info(f"Configuring DHCP on {ifname}: {self.dhcp_start}–{self.dhcp_end}")
        if not check_mode:
            with DhcpManager(self.config) as dhcp:
                # Do NOT call enable_service(): the dnsmasq_general module
                # re-validates every setting and fails on this firewall (bool
                # coercion + "Unbound is using port 53"). dnsmasq is already
                # enabled on a TAPPaaS firewall (it serves every zone's DHCP);
                # we only add our interface to the listen set and create the
                # range, exactly as zone_manager does.
                interfaces = self._get_dnsmasq_interfaces(dhcp)
                if ifname not in interfaces:
                    dhcp.set_dnsmasq_interfaces(interfaces + [ifname])
                dhcp.create_range(
                    DhcpRange(
                        description=self.dhcp_description,
                        start_addr=self.dhcp_start,
                        end_addr=self.dhcp_end,
                        interface=ifname,
                        domain=self.domain,
                    ),
                    reconfigure=True,
                )

        # 3. Firewall rules.
        info("Installing firewall rules (test→internet, mgmt→test, isolate rest)")
        rules = self._build_rules(ifname)
        result["rules"] = [d for d, *_ in rules]
        if not check_mode:
            with FirewallManager(self.config) as fw:
                for desc, action, interface, src, dst, seq in rules:
                    if fw.get_rule_by_description(desc):
                        debug(f"  rule exists, skipping: {desc}")
                        continue
                    # Build the rule with an explicit sequence. The
                    # create_allow_rule/create_block_rule helpers do NOT accept
                    # a sequence, so using them would leave ordering undefined —
                    # and ordering is load-bearing here (rules are quick=True, so
                    # a 'pass internet' evaluated before the RFC1918 blocks would
                    # let the test net reach mgmt). Mirror zone_manager, which
                    # passes sequence into FirewallRule(...).create_rule().
                    rule = FirewallRule(
                        description=desc,
                        action=action,
                        interface=interface,
                        source_net=src,
                        destination_net=dst,
                        sequence=seq,
                        log=True,
                    )
                    fw.create_rule(rule, apply=False)
                fw.apply_changes()

        result["status"] = "would_create" if check_mode else "created"
        return result

    def _build_rules(self, ifname: str):
        """Return the ordered rule set as (desc, action, iface, src, dst, seq)."""
        net = self.network_cidr
        # Sequence band 6 (40000+) — operator/manual rules, below zone-manager's
        # auto bands so nothing collides with reconciled zone rules.
        base = 41000
        rules = [
            (f"{DESC_PREFIX}: gateway", RuleAction.PASS, ifname, net,
             f"{self.gateway_ip}/32", base),
        ]
        seq = base + 1
        for network, label in RFC1918_NETWORKS:
            rules.append(
                (f"{DESC_PREFIX}: block {label}", RuleAction.BLOCK, ifname, net,
                 network, seq)
            )
            seq += 1
        rules.append(
            (f"{DESC_PREFIX}: internet", RuleAction.PASS, ifname, net, "any", seq)
        )
        seq += 1
        # mgmt → test, installed on the mgmt interface. Return traffic is
        # stateful, so test → mgmt stays blocked by the RFC1918 rule above.
        rules.append(
            (f"{DESC_PREFIX}: mgmt-access", RuleAction.PASS, self.mgmt_iface,
             self.mgmt_net, net, seq)
        )
        return rules

    # =================================================================
    # DELETE  (reverse order of create)
    # =================================================================
    def delete(self, check_mode: bool = False) -> dict:
        """Remove rules, DHCP and the interface assignment, in reverse order."""
        result: dict = {"device": self.device}

        # 1. Firewall rules first (depend on the interface existing).
        info("Removing firewall rules")
        with FirewallManager(self.config) as fw:
            matching = [r for r in fw.list_rules() if r.description.startswith(f"{DESC_PREFIX}:")]
            result["rules_removed"] = [r.description for r in matching]
            if not check_mode:
                for r in matching:
                    fw.delete_rule(r.description, apply=False)
                if matching:
                    fw.apply_changes()

        ifname = self._find_assigned_identifier()
        result["interface"] = ifname

        # 2. DHCP range + drop our interface from the dnsmasq listen set.
        info("Removing DHCP range")
        if not check_mode:
            with DhcpManager(self.config) as dhcp:
                existing = dhcp.get_range_by_description(self.dhcp_description)
                if existing:
                    dhcp.delete_range(self.dhcp_description, reconfigure=False)
                if ifname:
                    interfaces = self._get_dnsmasq_interfaces(dhcp)
                    if ifname in interfaces:
                        dhcp.set_dnsmasq_interfaces(
                            [i for i in interfaces if i != ifname]
                        )

        # 3. Unassign the interface last.
        info("Unassigning interface")
        if not check_mode:
            if ifname:
                with VlanManager(self.config) as vlan:
                    vlan.unassign_interface(ifname)
            else:
                warn("No assigned test-net interface found to unassign")

        result["status"] = "would_delete" if check_mode else "deleted"
        return result

    # =================================================================
    # STATUS
    # =================================================================
    def status(self) -> dict:
        """Report what currently exists for the test network."""
        ifname = self._find_assigned_identifier()
        with DhcpManager(self.config) as dhcp:
            dhcp_range = dhcp.get_range_by_description(self.dhcp_description)
        with FirewallManager(self.config) as fw:
            rules = [r.description for r in fw.list_rules()
                     if r.description.startswith(f"{DESC_PREFIX}:")]
        return {
            "device": self.device,
            "interface": ifname,
            "network": self.network_cidr,
            "dhcp_range": bool(dhcp_range),
            "rules": rules,
        }
