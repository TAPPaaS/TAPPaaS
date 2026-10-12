"""Unit tests for the IPv6 plan (ADR-030).

The plan is pure: site.json, the zones and what the firewall holds in, the
changes out. These pin the ADR's rules — the switch, the WAN modes, the /56
floor, which zones get IPv6 and how, and router advertisements.

Run with:
    cd src && python -m unittest test.test_ipv6_plan -v
"""

from __future__ import annotations

import unittest

from opnsense_controller.ipv6_plan import (
    STATIC_GATEWAY_NAME,
    desired_state,
    plan,
    wan_v6,
    zone_network,
)

ZONES = {
    "_README": {"note": "x"},
    "mgmt":     {"type": "Management", "state": "Manual", "vlantag": 0},
    "rossen":   {"type": "Service", "state": "Active", "vlantag": 200, "ipv6Subnet": 32},
    "home":     {"type": "Client", "state": "Active", "vlantag": 310, "ipv6Subnet": 49},
    "iotCams":  {"type": "IoT", "state": "Active", "vlantag": 430},            # unset: IPv4 only
    "guest":    {"type": "Guest", "state": "Inactive", "vlantag": 510, "ipv6Subnet": 81},
}
IFACES = {"mgmt": "lan", "rossen": "opt1", "home": "opt8", "iotCams": "opt5", "guest": "opt9"}
ZONE_IFACES = {"opt1", "opt8", "opt5", "opt9"}
DELEGATED = "2a13:e747:a210:8200::/56"
STATIC_SITE = {"ipv6": True, "network": {"wan": {"ipv6": {
    "mode": "static", "address": "2a13:e740:2e4:56c0::2/64",
    "gateway": "2a13:e740:2e4:56c0::1", "prefix": "2a13:e747:6648::/48"}}}}


def _v6(iface):
    """A dnsmasq IPv6 range as ipv6-manager writes it."""
    return {"uuid": f"r-{iface}", "interface": iface, "start_addr": "::",
            "constructor": iface, "ra_mode": "ra-names"}


class TestAddressing(unittest.TestCase):
    def test_zone_network_in_a_56(self):
        self.assertEqual(str(zone_network(DELEGATED, 0x31)), "2a13:e747:a210:8231::/64")
        self.assertEqual(str(zone_network(DELEGATED, 0x10)), "2a13:e747:a210:8210::/64")

    def test_zone_network_in_a_48_uses_its_first_56(self):
        self.assertEqual(str(zone_network("2a13:e747:6648::/48", 0x10)), "2a13:e747:6648:10::/64")

    def test_the_wan_defaults_to_dynamic_56(self):
        w = wan_v6({"ipv6": True})
        self.assertEqual((w.mode, w.prefix_length), ("dynamic", 56))


class TestDesired(unittest.TestCase):
    def test_ipv6_off_means_nothing_and_the_wan_untouched(self):
        d = desired_state({"ipv6": False}, ZONES, IFACES, DELEGATED)
        self.assertIsNone(d.wan)
        self.assertEqual(d.zones, {})

    def test_dynamic_tracks_the_wan_with_the_subnet_as_prefix_id(self):
        d = desired_state({"ipv6": True}, ZONES, IFACES, DELEGATED)
        self.assertEqual(set(d.zones), {"opt1", "opt8"})      # not mgmt, not unset, not Inactive
        self.assertEqual(dict(d.zones["opt8"].config),
                         {"ipaddrv6": "track6", "track6-interface": "wan", "track6-prefix-id": "49"})

    def test_static_puts_the_firewall_on_1_of_each_zone(self):
        d = desired_state(STATIC_SITE, ZONES, IFACES, None)
        self.assertEqual(dict(d.zones["opt8"].config),
                         {"ipaddrv6": "2a13:e747:6648:31::1", "subnetv6": "64"})

    def test_a_prefix_smaller_than_56_gives_no_zone_ipv6(self):
        d = desired_state({"ipv6": True}, ZONES, IFACES, "2a13:e747:a210:8200::/60")
        self.assertEqual(d.zones, {})
        self.assertTrue(any("smaller than /56" in p for p in d.problems))

    def test_no_delegated_prefix_yet_gives_no_zone_ipv6(self):
        d = desired_state({"ipv6": True}, ZONES, IFACES, None)
        self.assertEqual(d.zones, {})
        self.assertTrue(d.problems)

    def test_wan_none_gives_no_zone_ipv6(self):
        site = {"ipv6": True, "network": {"wan": {"ipv6": {"mode": "none"}}}}
        self.assertEqual(desired_state(site, ZONES, IFACES, DELEGATED).zones, {})


class TestPlan(unittest.TestCase):
    def _cur(self, **ifaces):
        cur = {"wan": {"if": "vtnet1", "ipaddrv6": "dhcp6", "dhcp6-ia-pd-len": "8"}}
        for name in ZONE_IFACES:
            cur[name] = {"if": f"vlan0.{name}"}
        cur.update(ifaces)
        return cur

    def test_a_converged_firewall_needs_nothing(self):
        d = desired_state({"ipv6": True}, ZONES, IFACES, DELEGATED)
        cur = self._cur(
            opt1={"if": "vlan0.200", "ipaddrv6": "track6", "track6-interface": "wan", "track6-prefix-id": "32"},
            opt8={"if": "vlan0.310", "ipaddrv6": "track6", "track6-interface": "wan", "track6-prefix-id": "49"})
        ranges = [_v6("opt1"), _v6("opt8"),
                  {"uuid": "v4", "interface": "opt8", "start_addr": "10.3.10.50"}]
        self.assertEqual(plan(d, cur, ZONE_IFACES, [], ranges), [])

    def test_from_nothing_to_dynamic(self):
        d = desired_state({"ipv6": True}, ZONES, IFACES, DELEGATED)
        cur = self._cur(wan={"if": "vtnet1", "ipaddrv6": "dhcp6", "dhcp6-ia-pd-len": "0"})
        kinds = [(a.kind, a.target) for a in plan(d, cur, ZONE_IFACES, [])]
        self.assertIn(("wan", "wan"), kinds)                  # pd-len 0 -> 8
        self.assertIn(("zone-set", "opt1"), kinds)
        self.assertIn(("zone-set", "opt8"), kinds)
        self.assertIn(("names-add", "opt8"), kinds)
        self.assertNotIn(("zone-set", "opt5"), kinds)         # iotCams: ipv6Subnet unset
        wan = next(a for a in plan(d, cur, ZONE_IFACES, []) if a.kind == "wan")
        self.assertEqual(wan.detail["set"], {"dhcp6-ia-pd-len": "8"})

    def test_a_zone_that_lost_its_number_is_cleared_and_stops_advertising(self):
        d = desired_state({"ipv6": True}, ZONES, IFACES, DELEGATED)
        cur = self._cur(opt5={"if": "vlan0.430", "ipaddrv6": "track6", "track6-interface": "wan",
                              "track6-prefix-id": "67"})
        acts = plan(d, cur, ZONE_IFACES, [], [_v6("opt5")])
        kinds = {(a.kind, a.target) for a in acts}
        self.assertIn(("zone-clear", "opt5"), kinds)
        self.assertIn(("names-del", "opt5"), kinds)

    def test_ipv6_off_clears_zones_but_leaves_the_wan(self):
        d = desired_state({"ipv6": False}, ZONES, IFACES, DELEGATED)
        cur = self._cur(opt8={"if": "vlan0.310", "ipaddrv6": "track6", "track6-interface": "wan",
                              "track6-prefix-id": "49"})
        kinds = {(a.kind, a.target) for a in plan(d, cur, ZONE_IFACES, [])}
        self.assertIn(("zone-clear", "opt8"), kinds)
        self.assertNotIn(("wan", "wan"), kinds)

    def test_a_range_without_ra_names_is_corrected(self):
        d = desired_state({"ipv6": True}, ZONES, IFACES, DELEGATED)
        wrong = {**_v6("opt8"), "ra_mode": "slaac"}
        acts = plan(d, self._cur(), ZONE_IFACES, [], [wrong])
        self.assertIn(("names-set", "opt8"), {(a.kind, a.target) for a in acts})

    def test_radvd_entries_on_zone_interfaces_are_removed(self):
        # dnsmasq advertises; a radvd entry on the same interface would conflict.
        d = desired_state({"ipv6": True}, ZONES, IFACES, DELEGATED)
        acts = plan(d, self._cur(), ZONE_IFACES,
                    [{"uuid": "x", "interface": "opt8", "mode": "unmanaged", "enabled": "1"},
                     {"uuid": "y", "interface": "lan", "mode": "unmanaged", "enabled": "1"}],
                    [_v6("opt8")])
        kinds = {(a.kind, a.target) for a in acts}
        self.assertIn(("radvd-del", "opt8"), kinds)
        self.assertNotIn(("radvd-del", "lan"), kinds)     # not a zone interface

    def test_an_ipv4_range_is_never_touched(self):
        d = desired_state({"ipv6": False}, ZONES, IFACES, DELEGATED)
        acts = plan(d, self._cur(), ZONE_IFACES, [],
                    [{"uuid": "v4", "interface": "opt8", "start_addr": "10.3.10.50"}])
        self.assertEqual([a for a in acts if a.kind.startswith("names-")], [])

    def test_static_wan_sets_address_and_gateway(self):
        d = desired_state(STATIC_SITE, ZONES, IFACES, None)
        wan = next(a for a in plan(d, self._cur(), ZONE_IFACES, []) if a.kind == "wan")
        self.assertEqual(wan.detail["set"]["ipaddrv6"], "2a13:e740:2e4:56c0::2")
        self.assertEqual(wan.detail["set"]["subnetv6"], "64")
        self.assertEqual(wan.detail["set"]["gatewayv6"], STATIC_GATEWAY_NAME)
        self.assertEqual(wan.detail["gateway"], "2a13:e740:2e4:56c0::1")

    def test_interfaces_outside_the_zones_are_never_touched(self):
        d = desired_state({"ipv6": False}, ZONES, IFACES, DELEGATED)
        cur = self._cur(lan={"if": "vtnet0", "ipaddrv6": "track6"})
        self.assertNotIn("lan", {a.target for a in plan(d, cur, ZONE_IFACES, [])})


if __name__ == "__main__":
    unittest.main()
