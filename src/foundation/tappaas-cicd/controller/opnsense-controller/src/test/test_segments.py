"""Unit tests for the firewall's segment listing (#862).

`opnsense-firewall segments --json` is what network-manager asks before it
authors a zone. These pin the two parsers against the API's row shapes (tags
arrive as strings, an interface may hold no IPv4, a VLAN device may have no
interface assigned) and that read_segments makes exactly the two calls.

Run with:
    cd src && python -m unittest test.test_segments -v
"""
from __future__ import annotations

import unittest

from opnsense_controller.segments import parse_interfaces, parse_vlans, read_segments

VLAN_ROWS = [
    {"uuid": "u1", "vlanif": "vlan0.100", "if": "vtnet0", "tag": "100", "descr": "storage", "pcp": "0"},
    {"uuid": "u2", "vlanif": "vlan0.200", "if": "vtnet0", "tag": "200", "descr": "Zone srv", "pcp": "0"},
    {"uuid": "u3", "vlanif": "vlan0.0", "if": "vtnet0", "tag": "", "descr": "broken"},
]
IFACE_ROWS = [
    {"identifier": "lan", "description": "lan", "device": "vtnet0", "enabled": True,
     "ipv4": [{"ipaddr": "10.0.0.1/24"}], "ipv6": None},
    {"identifier": "opt3", "description": "storage", "device": "vlan0.100", "vlan_tag": "100",
     "enabled": True, "ipv4": [{"ipaddr": "10.1.0.1/24"}]},
    {"identifier": "opt1", "description": "srv", "device": "vlan0.200", "vlan_tag": 200,
     "enabled": True, "ipv4": [{"ipaddr": "10.2.0.1/24"}]},
    {"identifier": "wan", "description": "wan", "device": "vtnet1", "enabled": True,
     "ipv4": [{"ipaddr": "not-an-address"}, {"ipaddr": "192.168.1.20/24"}]},
    {"identifier": "opt9", "description": "parked", "device": "vlan0.300", "vlan_tag": "300",
     "enabled": False, "ipv4": []},
    {"description": "no identifier — skipped"},
]


class FakeClient:
    def __init__(self):
        self.calls = []

    def run_module(self, module, params):
        self.calls.append((params["controller"], params["command"]))
        if params["controller"] == "vlan_settings":
            return {"result": {"response": {"rows": VLAN_ROWS}}}
        return {"result": {"response": {"rows": IFACE_ROWS}}}


class ParseVlansTest(unittest.TestCase):
    def test_tags_are_ints_and_an_empty_tag_is_dropped(self):
        v = parse_vlans(VLAN_ROWS)
        self.assertEqual([x["tag"] for x in v], [100, 200])
        self.assertEqual(v[0], {"tag": 100, "device": "vlan0.100", "parent": "vtnet0", "description": "storage"})


class ParseInterfacesTest(unittest.TestCase):
    def test_label_tag_and_network(self):
        i = {x["identifier"]: x for x in parse_interfaces(IFACE_ROWS)}
        self.assertEqual(sorted(i), ["lan", "opt1", "opt3", "opt9", "wan"])
        self.assertEqual(i["opt3"], {"identifier": "opt3", "description": "storage", "device": "vlan0.100",
                                     "tag": 100, "ipv4": "10.1.0.0/24", "enabled": True})
        self.assertEqual(i["opt1"]["tag"], 200)
        self.assertIsNone(i["lan"]["tag"])
        self.assertEqual(i["lan"]["ipv4"], "10.0.0.0/24")

    def test_first_parsable_address_wins_and_none_is_none(self):
        i = {x["identifier"]: x for x in parse_interfaces(IFACE_ROWS)}
        self.assertEqual(i["wan"]["ipv4"], "192.168.1.0/24")
        self.assertIsNone(i["opt9"]["ipv4"])
        self.assertFalse(i["opt9"]["enabled"])


class ReadSegmentsTest(unittest.TestCase):
    def test_two_calls_and_both_listings(self):
        c = FakeClient()
        seg = read_segments(c)
        self.assertEqual(c.calls, [("vlan_settings", "searchItem"), ("overview", "interfacesInfo")])
        self.assertEqual([v["tag"] for v in seg["vlans"]], [100, 200])
        self.assertEqual(len(seg["interfaces"]), 5)

    def test_an_empty_firewall_is_empty_not_an_error(self):
        class Empty:
            def run_module(self, module, params):
                return {"result": {}}
        self.assertEqual(read_segments(Empty()), {"vlans": [], "interfaces": []})


if __name__ == "__main__":
    unittest.main()
