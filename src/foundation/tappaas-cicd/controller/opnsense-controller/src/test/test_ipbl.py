"""IP blocklists from site.json: URL-table aliases, blocked both ways.

Run with:
    cd src && python -m unittest test.test_ipbl -v
"""

from __future__ import annotations

import contextlib
import io
import unittest
from pathlib import Path
from unittest import mock
from unittest.mock import MagicMock

from opnsense_controller.config import Config
from opnsense_controller.firewall_manager import FirewallRuleInfo
from opnsense_controller.ipbl_plan import (GROUP_ALIAS, SEQUENCE, WAN_RULE, ZONES_RULE, IpblError, alias_name,
                                           desired, filtered_zones, stale_aliases)
from opnsense_controller.rules_manager import RulesManager, ZoneSpec

DROP = "https://www.spamhaus.org/drop/drop.txt"
DROP6 = "https://www.spamhaus.org/drop/dropv6.txt"
ZONES = {
    "_comment": "not a zone",
    "mgmt": {"state": "Manual", "type": "Management", "vlantag": 0, "bridge": "lan"},
    "wan": {"state": "Manual", "type": "WAN"},
    "admin": {"state": "Manual", "type": "Overlay"},
    "home": {"state": "Active", "type": "Client", "vlantag": 410},
    "dmz": {"state": "Mandatory", "type": "DMZ", "vlantag": 600},
    "srv": {"state": "Inactive", "type": "Service", "vlantag": 210},
}


class TestPlan(unittest.TestCase):
    def test_absent_or_empty_blocks_nothing(self):
        self.assertIsNone(desired({}, ZONES))
        self.assertIsNone(desired({"ipBlocklists": []}, ZONES))

    def test_each_url_its_alias_and_the_zones_that_send(self):
        d = desired({"ipBlocklists": [DROP, DROP6, DROP]}, ZONES)
        self.assertEqual(d.urls, [DROP, DROP6])
        self.assertEqual(sorted(d.aliases().values()), [DROP, DROP6])
        # Active, Mandatory and mgmt; never the WAN, an overlay or an inactive zone.
        self.assertEqual(d.zones, ["dmz", "home", "mgmt"])
        self.assertEqual(filtered_zones({}), [])

    def test_the_alias_name_is_stable_and_short(self):
        self.assertEqual(alias_name(DROP), alias_name(DROP))
        self.assertNotEqual(alias_name(DROP), alias_name(DROP6))
        self.assertLessEqual(len(alias_name(DROP)), 32)

    def test_refusals(self):
        with self.assertRaisesRegex(IpblError, "list of URLs"):
            desired({"ipBlocklists": DROP}, ZONES)
        with self.assertRaisesRegex(IpblError, "not an http"):
            desired({"ipBlocklists": ["ftp://example.org/list"]}, ZONES)

    def test_stale(self):
        d = desired({"ipBlocklists": [DROP]}, ZONES)
        old = alias_name(DROP6)
        self.assertEqual(stale_aliases([alias_name(DROP), old, GROUP_ALIAS, "tm_x"], d), [old])
        self.assertEqual(stale_aliases([alias_name(DROP), GROUP_ALIAS], None), [GROUP_ALIAS, alias_name(DROP)])


class FakeFirewall:
    """OPNsense's alias API and filter rules, as ip_blocklists uses them."""

    def __init__(self):
        self.aliases: dict[str, dict] = {}   # name -> item (type, content, updatefreq)
        self.rules: dict[str, FirewallRuleInfo] = {}
        self.client = self
        self.applied = 0

    # client.run_module
    def run_module(self, name, params=None, **_):
        if name == "alias":
            if params.get("state") == "absent":
                self.aliases.pop(params["name"], None)
            else:
                self.aliases[params["name"]] = {"type": params["type"], "content": "\n".join(params["content"]),
                                                "enabled": "1", "updatefreq": ""}
            return {"changed": True}
        cmd = params["command"]
        resp: object = {}
        if cmd == "searchItem":
            resp = {"rows": [{"name": n} for n in self.aliases]}
        elif cmd.startswith("getAliasUUID/"):
            n = cmd.split("/", 1)[1]
            resp = {"uuid": f"u-{n}"} if n in self.aliases else []
        elif cmd.startswith("getItem/"):
            a = self.aliases[cmd.split("/", 1)[1][2:]]
            resp = {"alias": {**a, "type": {a["type"]: {"selected": 1}, "host": {"selected": 0}}}}
        elif cmd == "addItem" or cmd.startswith("setItem/"):
            item = params["data"]["alias"]
            self.aliases[item["name"]] = dict(item)
            resp = {"result": "saved"}
        return {"result": {"response": resp}}

    # fw
    def list_rules(self, pattern=""):
        return [r for d, r in self.rules.items() if pattern.lower() in d.lower()]

    def create_rule(self, rule, apply=True):
        iface = rule.interface if isinstance(rule.interface, list) else [rule.interface]
        self.rules[rule.description] = FirewallRuleInfo(
            uuid="r", description=rule.description, enabled=True, action=rule.action.value,
            interface=",".join(iface), direction="in", protocol="any", source_net=rule.source_net,
            source_port=None, destination_net=rule.destination_net, destination_port=None, log=True,
            sequence=rule.sequence, ip_protocol=rule.ip_protocol.value)

    def delete_rule(self, description, apply=True):
        self.rules.pop(description, None)

    def apply_changes(self):
        self.applied += 1


def _mgr(fw, check_mode=False):
    zones = {"mgmt": ZoneSpec("mgmt", "10.0.0.0/24", "lan", 0, [], []),
             "home": ZoneSpec("home", "10.3.10.0/24", "lan", 410, [], []),
             "dmz": ZoneSpec("dmz", "10.6.0.0/24", "lan", 600, [], [])}
    m = RulesManager(Config(firewall="example.invalid", ssl_verify=False, token="t", secret="s"), zones,
                     modules_dir=Path("/tmp"), sequence_map_file=None, check_mode=check_mode)
    m._fw = fw
    m._vlan_interface_for_tag = lambda tag: {410: "opt3", 600: "opt6"}.get(tag)
    return m


def run(m, site):
    out = io.StringIO()
    with mock.patch("opnsense_controller.rules_manager._firewall_ssh"), \
            contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
        ok = m.ip_blocklists(site, ZONES)
    return ok, out.getvalue()


class TestApply(unittest.TestCase):
    def test_lists_become_aliases_and_two_block_rules(self):
        fw = FakeFirewall()
        ok, out = run(_mgr(fw), {"ipBlocklists": [DROP]})
        self.assertTrue(ok)
        a = fw.aliases[alias_name(DROP)]
        self.assertEqual((a["type"], a["content"], a["updatefreq"]), ("urltable", DROP, "1"))
        self.assertEqual(fw.aliases[GROUP_ALIAS]["content"], alias_name(DROP))
        wan, zones = fw.rules[WAN_RULE], fw.rules[ZONES_RULE]
        self.assertEqual((wan.interface, wan.source_net, wan.action, wan.sequence, wan.ip_protocol),
                         ("wan", GROUP_ALIAS, "block", SEQUENCE, "inet46"))
        self.assertEqual((zones.interface, zones.destination_net, zones.action), ("lan,opt3,opt6", GROUP_ALIAS, "block"))

    def test_a_second_run_changes_nothing(self):
        fw = FakeFirewall()
        m = _mgr(fw)
        run(m, {"ipBlocklists": [DROP]})
        applied = fw.applied
        ok, out = run(m, {"ipBlocklists": [DROP]})
        self.assertTrue(ok)
        self.assertIn("matches site.json", out)
        self.assertEqual(fw.applied, applied)

    def test_a_removed_url_loses_its_alias(self):
        fw = FakeFirewall()
        m = _mgr(fw)
        run(m, {"ipBlocklists": [DROP, DROP6]})
        run(m, {"ipBlocklists": [DROP]})
        self.assertNotIn(alias_name(DROP6), fw.aliases)
        self.assertEqual(fw.aliases[GROUP_ALIAS]["content"], alias_name(DROP))

    def test_removing_the_field_removes_aliases_and_rules(self):
        fw = FakeFirewall()
        m = _mgr(fw)
        run(m, {"ipBlocklists": [DROP]})
        ok, out = run(m, {})
        self.assertTrue(ok)
        self.assertEqual((fw.aliases, fw.rules), ({}, {}))
        ok, out = run(m, {})
        self.assertIn("no IP blocklists — matches site.json", out)

    def test_check_mode_writes_nothing(self):
        fw = FakeFirewall()
        ok, out = run(_mgr(fw, check_mode=True), {"ipBlocklists": [DROP]})
        self.assertTrue(ok)
        self.assertEqual((fw.aliases, fw.rules), ({}, {}))
        self.assertIn("would add alias", out)
        self.assertIn("would block from the lists on the WAN", out)

    def test_a_zone_without_its_interface_is_left_out(self):
        fw = FakeFirewall()
        m = _mgr(fw)
        m._vlan_interface_for_tag = lambda tag: {600: "opt6"}.get(tag)
        ok, out = run(m, {"ipBlocklists": [DROP]})
        self.assertTrue(ok)
        self.assertIn("zone 'home' left out", out)
        self.assertEqual(fw.rules[ZONES_RULE].interface, "lan,opt6")

    def test_a_bad_url_changes_nothing(self):
        fw = FakeFirewall()
        ok, _ = run(_mgr(fw), {"ipBlocklists": ["not a url"]})
        self.assertFalse(ok)
        self.assertEqual(fw.aliases, {})


if __name__ == "__main__":
    unittest.main()
