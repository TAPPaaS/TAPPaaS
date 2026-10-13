"""Overlap analysis of a rule set (#160): shadowed, redundant, conflict.

Run with:
    cd src && python -m unittest test.test_rule_overlap -v
"""

from __future__ import annotations

import unittest
from types import SimpleNamespace

from opnsense_controller.rule_overlap import (
    Addresses,
    Match,
    Rule,
    analyse,
    from_rule_info,
    report,
)

NETS = {
    "opt8": ["10.3.10.0/24", "2001:db8:31::/64"],       # home
    "opt1": ["10.2.0.0/24", "2001:db8:20::/64"],        # rossen
    "tm_app": ["10.2.0.50", "2001:db8:20::50"],
    "tm_db": ["10.2.0.60"],
}


def info(desc, seq, action="pass", src="opt8", dst="tm_app", port="8080", proto="TCP",
         family="inet46", iface="opt8", src_not=False, enabled=True):
    return SimpleNamespace(description=desc, uuid=desc, sequence=seq, action=action,
                           interface=iface, source_net=src, destination_net=dst,
                           destination_port=port, protocol=proto, ip_protocol=family,
                           source_invert=src_not, destination_invert=False,
                           enabled=enabled, quick=True)


def kinds(infos):
    rep = report(infos, NETS.get, lambda d: True)
    return sorted((f.kind, f.rule.description, f.by.description) for f in rep.findings)


class TestGeometry(unittest.TestCase):
    def test_a_network_contains_its_host(self):
        net, host = Addresses.of(["10.2.0.0/24"]), Addresses.of(["10.2.0.50"])
        m = lambda d: Match("opt1", frozenset({4}), frozenset({"tcp"}), Addresses.any(), d, ((80, 80),))
        self.assertTrue(m(net).contains(m(host)))
        self.assertFalse(m(host).contains(m(net)))

    def test_an_inverted_source_does_not_contain_its_own_network(self):
        spoof = Addresses.of(["10.3.10.0/24"]).inverted()
        own = Addresses.of(["10.3.10.0/24"])
        m = lambda s: Match("opt8", frozenset({4}), frozenset({"*"}), s, Addresses.any(), ((0, 65535),))
        self.assertFalse(m(spoof).intersects(m(own)))


class TestFindings(unittest.TestCase):
    def test_a_pass_behind_a_block_is_shadowed(self):
        # The #386 shape: a block on the zone's private networks ahead of a pinhole.
        self.assertEqual(kinds([
            info("Zone home block rossen", 100, action="block", dst="opt1", port="", proto="any"),
            info("tappaas-module:app:ingress:home:8080", 200),
        ]), [("shadowed", "tappaas-module:app:ingress:home:8080", "Zone home block rossen")])

    def test_a_pinhole_ahead_of_the_block_is_the_design(self):
        self.assertEqual(kinds([
            info("tappaas-module:app:ingress:home:8080", 100),
            info("Zone home block rossen", 200, action="block", dst="opt1", port="", proto="any"),
        ]), [])

    def test_a_pinhole_a_later_zone_pass_covers_is_redundant(self):
        # The #256 shape: access-to already passes everything into rossen.
        self.assertEqual(kinds([
            info("tappaas-module:app:ingress:home:8080", 100),
            info("Zone home -> rossen", 300, dst="opt1", port="", proto="any"),
        ]), [("redundant", "tappaas-module:app:ingress:home:8080", "Zone home -> rossen")])

    def test_a_block_between_them_keeps_the_pinhole_needed(self):
        self.assertEqual(kinds([
            info("tappaas-module:app:ingress:home:8080", 100),
            info("Zone home block rossen", 200, action="block", dst="opt1", port="", proto="any"),
            info("Zone home -> rossen", 300, dst="opt1", port="", proto="any"),
        ]), [("shadowed", "Zone home -> rossen", "Zone home block rossen")])

    def test_a_partial_block_ahead_is_a_conflict(self):
        # A block on the host only: the module pass to the whole network is cut in part.
        self.assertEqual(kinds([
            info("Zone home block db", 100, action="block", dst="tm_db", port="", proto="any"),
            info("tappaas-module:app:ingress:home:8080", 200, dst="opt1"),
        ]), [("conflict", "tappaas-module:app:ingress:home:8080", "Zone home block db")])

    def test_different_ports_do_not_overlap(self):
        self.assertEqual(kinds([
            info("Zone home block app ssh", 100, action="block", port="22"),
            info("tappaas-module:app:ingress:home:8080", 200),
        ]), [])

    def test_ipv4_only_block_leaves_the_ipv6_half(self):
        # inet block covers only the IPv4 half of an inet46 pass: a conflict, not a shadow.
        self.assertEqual(kinds([
            info("Zone home block rossen v4", 100, action="block", dst="opt1", port="", proto="any",
                 family="inet"),
            info("tappaas-module:app:ingress:home:8080", 200),
        ]), [("conflict", "tappaas-module:app:ingress:home:8080", "Zone home block rossen v4")])

    def test_icmp_ignores_ports(self):
        self.assertEqual(kinds([
            info("Zone home -> gateway icmp", 100, dst="tm_app", port="", proto="ICMP", family="inet"),
            info("tappaas-module:app:ingress:home:ping", 200, port="", proto="ICMP", family="inet"),
        ]), [("shadowed", "tappaas-module:app:ingress:home:ping", "Zone home -> gateway icmp")])

    def test_other_interfaces_never_interact(self):
        self.assertEqual(kinds([
            info("Zone dmz block rossen", 100, action="block", dst="opt1", port="", proto="any", iface="opt7"),
            info("tappaas-module:app:ingress:home:8080", 200),
        ]), [])

    def test_disabled_rules_and_unknown_names(self):
        rep = report([
            info("Zone home block rossen", 100, action="block", dst="opt1", port="", proto="any",
                 enabled=False),
            info("tappaas-module:x:ingress:home:1", 200, dst="tm_missing"),
            info("tappaas-module:app:ingress:home:8080", 300),
        ], NETS.get, lambda d: True)
        self.assertEqual(rep.findings, [])
        self.assertEqual(rep.unresolved, ["tappaas-module:x:ingress:home:1"])
        self.assertEqual(rep.analysed, 1)


class TestEmptyNames(unittest.TestCase):
    def test_a_rule_on_an_empty_alias_is_not_analysed(self):
        # An empty table matches nothing; it must not read as shadowed by anything.
        nets = dict(NETS, empty=[])
        rep = report([
            info("Zone home -> rossen", 100, dst="opt1", port="", proto="any"),
            info("Zone home block firewall", 200, action="block", dst="empty", port="", proto="any"),
        ], nets.get, lambda d: True)
        self.assertEqual(rep.findings, [])
        self.assertEqual(rep.unresolved, ["Zone home block firewall"])


class TestFromRuleInfo(unittest.TestCase):
    def test_a_rule_on_several_interfaces_is_one_per_interface(self):
        rs = from_rule_info(info("Zone x", 1, iface="opt1,opt8"), NETS.get)
        self.assertEqual([r.match.interface for r in rs], ["opt1", "opt8"])

    def test_a_port_range(self):
        rs = from_rule_info(info("tappaas-module:coturn:ingress:home:49152:50151/UDP", 1,
                                 port="49152-50151", proto="UDP"), NETS.get)
        self.assertEqual(rs[0].match.ports, ((49152, 50151),))


if __name__ == "__main__":
    unittest.main()
