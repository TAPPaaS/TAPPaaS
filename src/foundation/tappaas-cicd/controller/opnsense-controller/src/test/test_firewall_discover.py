"""Unit tests for the firewall's discovery pass (ADR-040 D15).

Run with:
    cd src && python -m unittest test.test_firewall_discover -v
"""
from __future__ import annotations

import unittest

from opnsense_controller.firewall_discover import read_discover, shape_peers, shape_rules

FILTER = {"filter": {"rules": {"rule": {
    "u-b": {"enabled": "1", "sequence": "200", "action": {"pass": {"value": "Pass", "selected": 1}, "block": {"selected": 0}},
            "interface": {"lan": {"selected": 1}}, "description": "second by sequence"},
    "u-a": {"enabled": "0", "sequence": "100", "action": {"block": {"selected": 1}}, "description": "held after it"},
}}}}


class FakeClient:
    def __init__(self, answers):
        self.answers = answers

    def run_module(self, _kind, params):
        key = f"{params['module']}/{params['controller']}/{params['command']}"
        if key not in self.answers:
            raise RuntimeError(f"404 {key}")
        return {"result": {"response": self.answers[key]}}


class TestDiscover(unittest.TestCase):
    def test_rules_keep_the_live_order_and_uuid(self):
        rules = shape_rules(FILTER)
        self.assertEqual([(r["uuid"], r["position"], r["sequence"]) for r in rules], [("u-b", 1, 200), ("u-a", 2, 100)])
        self.assertEqual(rules[0]["action"], "pass")
        self.assertFalse(rules[1]["enabled"])

    def test_an_empty_model_is_no_rules(self):
        self.assertEqual(shape_rules({"filter": {"rules": {"rule": []}}}), [])

    def test_a_peer_takes_its_handshake_by_key(self):
        p = shape_peers([{"name": "mac", "pubkey": "K", "tunneladdress": "10.255.1.2/32"}],
                        [{"type": "peer", "public-key": "K", "latest-handshake-age": "42", "endpoint": "1.2.3.4:5"}])
        self.assertEqual((p[0]["lastHandshake"], p[0]["endpoint"]), ("42", "1.2.3.4:5"))

    def test_a_section_that_fails_is_named_and_the_pass_goes_on(self):
        d = read_discover(FakeClient({
            "firewall/filter/get": FILTER,
            "dnsmasq/leases/search": {"rows": [{"address": "10.0.0.5", "hwaddr": "aa:bb", "hostname": "h"}]},
            "core/firmware/info": {"product_version": "25.7.1", "package": [{"name": "os-caddy", "version": "2", "installed": "1"},
                                                                           {"name": "os-x", "version": "1", "installed": "0"}]},
        }))
        self.assertEqual(len(d["rules"]), 2)
        self.assertEqual(d["leases"][0]["ip"], "10.0.0.5")
        self.assertEqual(d["version"], "25.7.1")
        self.assertEqual([p["name"] for p in d["packages"]], ["os-caddy"])
        self.assertIn("wireguard", [e["section"] for e in d["errors"]])


if __name__ == "__main__":
    unittest.main()
