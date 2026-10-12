"""Unit tests for IPv6 next to IPv4 in published names and access lists (ADR-030 D9).

Run with:
    cd src && python -m unittest test.test_dual_stack -v
"""

from __future__ import annotations

import unittest

from opnsense_controller.dual_stack import (
    AAAA_MARK,
    aaaa_plan,
    derived_v6,
    parse_overview,
    v6_for,
    with_v6,
)

ROWS = [
    {"identifier": "lan", "ipv4": [{"ipaddr": "10.0.0.1/24"}], "ipv6": None},
    {"identifier": "opt1", "ipv4": [{"ipaddr": "10.2.0.1/24"}],
     "ipv6": [{"ipaddr": "2a13:e747:a210:8220:98:34ff:fe69:901a/64"}, {"ipaddr": "fe80::98:34ff:fe69:901a/64"}]},
    {"identifier": "opt7", "ipv4": [{"ipaddr": "10.6.0.1/24"}],
     "ipv6": [{"ipaddr": "2a13:e747:a210:8261:98:34ff:fe69:901a/64"}]},
]
IFACES = parse_overview(ROWS)
DMZ_V6 = "2a13:e747:a210:8261:98:34ff:fe69:901a"


def _a(host, server="10.6.0.1", domain="hrossen.dk", uuid=None):
    return {"uuid": uuid or f"a-{host}", "hostname": host, "domain": domain, "rr": "A",
            "server": server, "description": f"TAPPaaS: {host}"}


def _aaaa(host, server=DMZ_V6, ours=True, uuid=None, domain="hrossen.dk"):
    return {"uuid": uuid or f"q-{host}", "hostname": host, "domain": domain, "rr": "AAAA",
            "server": server, "description": f"TAPPaaS: {host}" + (AAAA_MARK if ours else "")}


class TestInterfaces(unittest.TestCase):
    def test_link_local_is_not_an_address_to_publish(self):
        opt1 = next(i for i in IFACES if i.identifier == "opt1")
        self.assertEqual([str(a.ip) for a in opt1.v6], ["2a13:e747:a210:8220:98:34ff:fe69:901a"])

    def test_the_dmz_gateway_has_an_ipv6_counterpart(self):
        self.assertEqual(v6_for("10.6.0.1", IFACES), DMZ_V6)
        self.assertIsNone(v6_for("10.0.0.1", IFACES))      # mgmt: no IPv6
        self.assertIsNone(v6_for("10.6.0.7", IFACES))      # not the firewall


class TestAccessLists(unittest.TestCase):
    def test_a_zone_network_gets_its_ipv6_network(self):
        self.assertEqual(with_v6(["10.0.0.0/24", "10.2.0.0/24", "100.64.0.0/10"], IFACES),
                         ["10.0.0.0/24", "10.2.0.0/24", "100.64.0.0/10", "2a13:e747:a210:8220::/64"])

    def test_adding_twice_adds_nothing(self):
        once = with_v6(["10.2.0.0/24"], IFACES)
        self.assertEqual(with_v6(once, IFACES), once)

    def test_a_changed_prefix_replaces_the_old_network(self):
        stale = ["10.2.0.0/24", "2a13:e747:a210:9920::/64"]
        self.assertEqual(derived_v6(stale, IFACES), ["10.2.0.0/24", "2a13:e747:a210:8220::/64"])

    def test_ipv6_off_leaves_ipv4_only(self):
        no_v6 = parse_overview([{**r, "ipv6": None} for r in ROWS])
        self.assertEqual(derived_v6(["10.2.0.0/24", "2a13:e747:a210:8220::/64"], no_v6),
                         ["10.2.0.0/24"])


class TestAaaa(unittest.TestCase):
    def test_a_name_at_the_dmz_gateway_gets_an_aaaa(self):
        p = aaaa_plan([_a("forgejo"), _a("*")], IFACES)
        self.assertEqual({(a["hostname"], a["server"]) for a in p.add},
                         {("forgejo", DMZ_V6), ("*", DMZ_V6)})
        self.assertTrue(all(a["description"].endswith(AAAA_MARK) for a in p.add))
        self.assertEqual(p.delete, [])

    def test_converged_needs_nothing(self):
        self.assertFalse(aaaa_plan([_a("forgejo"), _aaaa("forgejo")], IFACES))

    def test_a_name_pointing_elsewhere_gets_none(self):
        self.assertFalse(aaaa_plan([_a("turn", server="10.6.0.12"), _a("x", server="10.0.0.1")], IFACES))

    def test_a_changed_prefix_replaces_the_aaaa(self):
        p = aaaa_plan([_a("forgejo"), _aaaa("forgejo", server="2a13:e747:a210:9961::1")], IFACES)
        self.assertEqual([r["uuid"] for r in p.delete], ["q-forgejo"])
        self.assertEqual([a["server"] for a in p.add], [DMZ_V6])

    def test_ours_without_an_a_goes(self):
        p = aaaa_plan([_aaaa("gone")], IFACES)
        self.assertEqual([r["uuid"] for r in p.delete], ["q-gone"])

    def test_ipv6_off_removes_ours(self):
        no_v6 = parse_overview([{**r, "ipv6": None} for r in ROWS])
        p = aaaa_plan([_a("forgejo"), _aaaa("forgejo")], no_v6)
        self.assertEqual([r["uuid"] for r in p.delete], ["q-forgejo"])
        self.assertEqual(p.add, [])

    def test_a_duplicate_of_ours_goes(self):
        p = aaaa_plan([_a("forgejo"), _aaaa("forgejo", uuid="q1"), _aaaa("forgejo", uuid="q2")], IFACES)
        self.assertEqual([r["uuid"] for r in p.delete], ["q2"])
        self.assertEqual(p.add, [])

    def test_the_operators_aaaa_is_left_alone_and_wins(self):
        p = aaaa_plan([_a("forgejo"), _aaaa("forgejo", server="2001:db8::5", ours=False)], IFACES)
        self.assertFalse(p)

    def test_only_limits_the_plan_to_one_name(self):
        p = aaaa_plan([_a("forgejo"), _a("immich"), _aaaa("gone")], IFACES, only=("Forgejo", "hrossen.dk."))
        self.assertEqual([a["hostname"] for a in p.add], ["forgejo"])
        self.assertEqual(p.delete, [])

    def test_an_aaaa_record_is_not_read_as_an_a(self):
        # An AAAA whose address happens to match nothing must not seed another AAAA.
        self.assertFalse(aaaa_plan([_aaaa("x", server="10.6.0.1", ours=False)], IFACES))


if __name__ == "__main__":
    unittest.main()
