"""The `all` sentinel in access-to (#375): expanded where a zones file is read."""

import json
import tempfile
import unittest
from pathlib import Path

from opnsense_controller import rules_manager, snat_policy
from opnsense_controller.zone_access import expand_access_all
from opnsense_controller.zone_manager import ZoneManager


def _zones(mgmt_access):
    return {
        "_README": {"_comment": "documentation, not a zone"},
        "mgmt": {"state": "Manual", "ip": "10.0.0.0/24", "access-to": mgmt_access},
        "srv": {"state": "Inactive", "ip": "10.1.0.0/24", "vlantag": 100, "access-to": ["internet"]},
        "home": {"state": "Active", "ip": "10.3.0.0/24", "vlantag": 300, "access-to": ["internet"]},
        "iotCams": {"state": "Active", "ip": "10.4.0.0/24", "vlantag": 400, "access-to": [], "isolated": True},
        "gone": {"state": "Disabled", "ip": "10.9.0.0/24", "vlantag": 900, "access-to": []},
        "dmz": {"state": "Mandatory", "ip": "10.6.0.0/24", "vlantag": 600, "access-to": ["internet"]},
        "admin": {"type": "Overlay", "state": "Manual", "ip": "10.255.1.0/24", "access-to": ["mgmt"]},
        "wan": {"type": "WAN", "state": "Manual", "ip": "10.1.0.0/24", "vlantag": 100, "access-to": []},
    }


EVERY_ZONE = ["internet", "srv", "home", "iotCams", "dmz"]


class TestExpand(unittest.TestCase):
    def test_all_is_internet_and_every_other_zone_not_disabled(self):
        out = expand_access_all(_zones(["internet", "all"]))
        self.assertEqual(out["mgmt"]["access-to"], EVERY_ZONE)

    def test_all_alone_includes_internet(self):
        """`["all"]` (the control archetype's seed) and `["internet","all"]` agree."""
        out = expand_access_all(_zones(["all"]))
        self.assertEqual(out["mgmt"]["access-to"], EVERY_ZONE)

    def test_a_disabled_zone_and_the_zone_itself_are_left_out(self):
        got = expand_access_all(_zones(["all"]))["mgmt"]["access-to"]
        self.assertNotIn("gone", got)
        self.assertNotIn("mgmt", got)

    def test_overlays_and_wan_are_not_standard_zones(self):
        got = expand_access_all(_zones(["all"]))["mgmt"]["access-to"]
        self.assertNotIn("admin", got)
        self.assertNotIn("wan", got)

    def test_named_entries_come_first_and_are_not_repeated(self):
        out = expand_access_all(_zones(["home", "all"]))
        self.assertEqual(out["mgmt"]["access-to"], ["home", "internet", "srv", "iotCams", "dmz"])

    def test_a_zone_added_later_is_covered_without_editing_mgmt(self):
        zones = _zones(["internet", "all"])
        zones["work"] = {"state": "Active", "ip": "10.5.0.0/24", "vlantag": 500, "access-to": ["internet"]}
        self.assertIn("work", expand_access_all(zones)["mgmt"]["access-to"])

    def test_other_zones_and_the_input_are_untouched(self):
        zones = _zones(["internet", "all"])
        out = expand_access_all(zones)
        self.assertEqual(out["home"], zones["home"])
        self.assertEqual(out["_README"], zones["_README"])
        self.assertEqual(zones["mgmt"]["access-to"], ["internet", "all"])


class TestLoaders(unittest.TestCase):
    """Every loader sees the same set an explicit list would give."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "zones.json"
        self.path.write_text(json.dumps(_zones(["internet", "all"])))

    def tearDown(self):
        self.tmp.cleanup()

    def test_rules_manager(self):
        self.assertEqual(rules_manager.load_zones(self.path)["mgmt"].access_to, EVERY_ZONE)

    def test_snat_policy(self):
        zones = snat_policy.load_zones(self.path)
        self.assertEqual(zones["mgmt"].access_to, EVERY_ZONE)
        self.assertTrue(snat_policy.reaches(zones["mgmt"], "iotCams"))

    def test_zone_manager(self):
        zm = ZoneManager.__new__(ZoneManager)
        zm.zones_file = self.path
        mgmt = {z.name: z for z in zm.load_zones()}["mgmt"]
        self.assertEqual(mgmt.access_to, EVERY_ZONE)


if __name__ == "__main__":
    unittest.main()
