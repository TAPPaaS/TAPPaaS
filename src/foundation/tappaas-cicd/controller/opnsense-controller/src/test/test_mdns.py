"""mDNS across zones (#257): which zones join the repeater, and what changes.

Run with:
    cd src && python -m unittest test.test_mdns -v
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from opnsense_controller.mdns_cli import MDNS_GROUP, MDNS_PORT, RULE_SEQUENCE, declared_zones, load_modules, plan

ZONES = {
    "_README": {},
    "mgmt": {"type": "Management", "state": "Mandatory", "vlantag": 0, "mdns": True},
    "home": {"type": "Client", "state": "Active", "vlantag": 310, "mdns": True},
    "iotCloud": {"type": "IoT", "state": "Active", "vlantag": 410, "mdns": True},
    "srvHome": {"type": "Service", "state": "Active", "vlantag": 210},
    "guest": {"type": "Guest", "state": "Inactive", "vlantag": 510, "mdns": True},
    "netbird": {"type": "Overlay", "state": "Manual", "vlantag": 0},
}


def rule(ifaces, **kw):
    r = {"interfaces": set(ifaces), "sequence": RULE_SEQUENCE, "destination": MDNS_GROUP,
         "port": MDNS_PORT, "protocol": "UDP", "family": "inet"}
    r.update(kw)
    return r


class TestDeclared(unittest.TestCase):
    def test_zones_with_mdns_true_that_can_take_part(self):
        d = declared_zones(ZONES, {})
        self.assertEqual(sorted(d.zones), ["home", "iotCloud"])
        self.assertTrue(any("'mgmt' cannot take part" in w for w in d.warnings))
        self.assertTrue(any("'guest' is not active" in w for w in d.warnings))

    def test_a_module_adds_its_zone0_and_consumers(self):
        d = declared_zones(ZONES, {"hass": {"zone0": "srvHome", "discoveryMdns": ["home"]}})
        self.assertEqual(sorted(d.zones), ["home", "iotCloud", "srvHome"])
        self.assertEqual(d.zones["home"], ["zones.json", "module hass"])

    def test_legacy_true_adds_zone0_only(self):
        d = declared_zones({"srvHome": ZONES["srvHome"]}, {"hass": {"zone0": "srvHome", "discoveryMdns": True}})
        self.assertEqual(list(d.zones), ["srvHome"])

    def test_without_leaves_the_module_out(self):
        mods = {"hass": {"zone0": "srvHome", "discoveryMdns": ["home"]}}
        self.assertNotIn("srvHome", declared_zones(ZONES, mods, without="hass").zones)

    def test_unknown_zone_is_a_warning(self):
        d = declared_zones(ZONES, {"x": {"zone0": "nowhere", "discoveryMdns": []}})
        self.assertEqual(d.warnings, declared_zones(ZONES, {}).warnings)    # [] is "none declared"
        d = declared_zones(ZONES, {"x": {"zone0": "nowhere", "discoveryMdns": ["home"]}})
        self.assertTrue(any("'nowhere' is not in zones.json" in w for w in d.warnings))


class TestLoadModules(unittest.TestCase):
    """#877: the stored config keeps discoveryMdns under network:discovery."""

    def test_the_nested_declaration_counts(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "hue.json").write_text(json.dumps({
                "vmname": "hue", "zone0": "iotCloud",
                "config": {"network:discovery": {"discoveryMdns": ["home", "srvHome"]}}}))
            Path(d, "flat.json").write_text(json.dumps({"zone0": "home", "discoveryMdns": True}))
            Path(d, "none.json").write_text(json.dumps({"zone0": "home", "config": {"cluster:vm": {"cores": 2}}}))
            mods = load_modules(Path(d))
        self.assertEqual(sorted(mods), ["flat", "hue"])
        self.assertEqual(mods["hue"]["discoveryMdns"], ["home", "srvHome"])
        d = declared_zones(ZONES, mods)
        self.assertIn("module hue", d.zones.get("srvHome", []), d.zones)
        self.assertIn("module hue", d.zones.get("iotCloud", []), d.zones)


class TestPlan(unittest.TestCase):
    def test_converged(self):
        p = plan({"opt1", "opt2"}, True, {"opt1", "opt2"}, rule(["opt1", "opt2"]))
        self.assertFalse(p.settings_change)
        self.assertEqual(p.rule_change, "")

    def test_first_time(self):
        p = plan({"opt2", "opt1"}, False, {"lan"}, None)
        self.assertTrue(p.enabled and p.settings_change)
        self.assertEqual(p.interfaces, ["opt1", "opt2"])
        self.assertEqual(p.rule_change, "create")

    def test_a_hand_added_interface_is_removed(self):
        p = plan({"opt1", "opt2"}, True, {"opt1", "opt2", "opt9"}, rule(["opt1", "opt2"]))
        self.assertTrue(p.settings_change)

    def test_rule_follows_the_set(self):
        self.assertEqual(plan({"opt1", "opt2", "opt3"}, True, {"opt1", "opt2", "opt3"},
                              rule(["opt1", "opt2"])).rule_change, "update")
        self.assertEqual(plan({"opt1", "opt2"}, True, {"opt1", "opt2"},
                              rule(["opt1", "opt2"], sequence=100)).rule_change, "update")

    def test_fewer_than_two_switches_off(self):
        p = plan({"opt1"}, True, {"opt1", "opt2"}, rule(["opt1", "opt2"]))
        self.assertFalse(p.enabled)
        self.assertTrue(p.settings_change)
        self.assertEqual(p.rule_change, "delete")
        p = plan(set(), False, {"lan"}, None)
        self.assertFalse(p.settings_change)
        self.assertEqual(p.rule_change, "")


if __name__ == "__main__":
    unittest.main()
