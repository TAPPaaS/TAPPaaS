"""Caddy is reachable on the WAN over IPv6 while the site runs IPv6 (#26 inbound).

Run with:
    cd src && python -m unittest test.test_ipv6_caddy_wan -v
"""

from __future__ import annotations

import contextlib
import io
import ipaddress
import unittest
from types import SimpleNamespace
from unittest import mock

from opnsense_controller import ipv6_cli
from opnsense_controller.dual_stack import IfaceAddr

WAN6 = IfaceAddr("wan", ipaddress.IPv4Interface("80.248.138.190/24"),
                 (ipaddress.IPv6Interface("2001:db8:978c::aba/64"),))
WAN4 = IfaceAddr("wan", ipaddress.IPv4Interface("80.248.138.190/24"), ())


def rule(desc, family):
    return SimpleNamespace(description=desc, interface="wan", ip_protocol=family, source_net="any",
                           destination_net="wanip", destination_port="443", log=True, quick=True,
                           sequence=1)


class FakeFM:
    def __init__(self, family):
        self.rules = {d: rule(d, family) for d in ipv6_cli.CADDY_WAN_RULES}
        self.updated, self.applied = [], 0

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def get_rule_by_description(self, d):
        return self.rules.get(d)

    def update_rule(self, r, apply=True):
        self.updated.append((r.description, r.ip_protocol.value, r.destination_net))

    def apply_changes(self):
        self.applied += 1


class TestCaddyWan(unittest.TestCase):
    def run_it(self, family, allowed, ifaces):
        fm = FakeFM(family)
        out = io.StringIO()
        with mock.patch("opnsense_controller.firewall_manager.FirewallManager", return_value=fm), \
                contextlib.redirect_stdout(out):
            n = ipv6_cli._converge_caddy_wan(None, [ifaces], allowed, check_mode=False)
        return n, fm, out.getvalue()

    def test_ipv6_on_opens_both_rules_and_names_the_aaaa(self):
        n, fm, out = self.run_it("inet", True, WAN6)
        self.assertEqual(n, 2)
        self.assertEqual({u[1] for u in fm.updated}, {"inet46"})
        self.assertEqual({u[2] for u in fm.updated}, {"wanip"})
        self.assertEqual(fm.applied, 1)
        self.assertIn("2001:db8:978c::aba", out)

    def test_converged_changes_nothing(self):
        n, fm, _ = self.run_it("inet46", True, WAN6)
        self.assertEqual((n, fm.updated, fm.applied), (0, [], 0))

    def test_ipv6_off_or_no_wan_address_closes_it(self):
        for allowed, ifaces in ((False, WAN6), (True, WAN4)):
            n, fm, out = self.run_it("inet46", allowed, ifaces)
            self.assertEqual(n, 2)
            self.assertEqual({u[1] for u in fm.updated}, {"inet"})
            self.assertNotIn("public AAAA", out)


if __name__ == "__main__":
    unittest.main()
