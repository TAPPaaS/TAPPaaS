"""ipv6-manager withdraws a zone's IPv6 route before removing it (ADR-030 D8).

Run with:
    cd src && python -m unittest test.test_ipv6_drain -v
"""

from __future__ import annotations

import unittest
from unittest import mock

from opnsense_controller import ipv6_cli
from opnsense_controller.ipv6_plan import Action


class TestDrain(unittest.TestCase):
    def _run(self, actions):
        calls = []

        def dnsmasq(mgr, controller, command, action, data=None, params=None):
            rl = ((data or {}).get("range") or {}).get("ra_router_lifetime")
            calls.append((command, rl))
            return {"result": "deleted" if command == "delRange" else "saved"}

        def fw(host, script, timeout=120.0):
            calls.append(("config", None))
            return ""

        with mock.patch.object(ipv6_cli, "_dnsmasq", dnsmasq), mock.patch.object(ipv6_cli, "_fw", fw), \
             mock.patch.object(ipv6_cli, "_radvd", lambda *a, **k: {}):
            ipv6_cli.execute(None, "fw", actions, drain_seconds=0)
        return calls

    def test_route_is_withdrawn_before_the_zone_loses_ipv6(self):
        calls = self._run([Action("zone-clear", "opt8", {"device": "vlan0.310"}),
                           Action("names-del", "opt8", {"uuid": "r8"})])
        self.assertEqual(calls[0], ("setRange", "0"))           # router lifetime 0 first
        self.assertEqual(calls[1], ("reconfigure", None))       # sent by the reload
        self.assertLess(calls.index(("setRange", "0")), calls.index(("config", None)))
        self.assertEqual(calls[-2:], [("delRange", None), ("reconfigure", None)])

    def test_nothing_to_remove_drains_nothing(self):
        calls = self._run([Action("names-add", "opt8", {})])
        self.assertNotIn(("setRange", "0"), calls)
        self.assertEqual(calls[0], ("addRange", ""))            # a new range advertises normally


if __name__ == "__main__":
    unittest.main()
