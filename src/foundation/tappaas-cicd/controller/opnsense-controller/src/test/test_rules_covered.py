"""Module rules a zone edge already passes are left out, and come back when it goes (#256, #162).

Run with:
    cd src && python -m unittest test.test_rules_covered -v
"""

from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from opnsense_controller.config import Config
from opnsense_controller.rules_manager import RulesManager, ZoneSpec, load_module, stable_hash_index

ZONES = {
    "srv": dict(ip="10.2.10.0/24", vlantag=210, access_to=["internet"], paf=["dmz", "home"]),
    "dmz": dict(ip="10.6.0.0/24", vlantag=610, access_to=["internet"], paf=["internet"]),
    "home": dict(ip="10.3.10.0/24", vlantag=310, access_to=["internet"], paf=[]),
    "iot": dict(ip="10.4.10.0/24", vlantag=410, access_to=["internet"], paf=["srv"]),
}
APP = {
    "vmname": "app", "zone0": "srv", "bridge0": "lan",
    "ports": [{"port": 8080, "protocol": "TCP"}, {"port": 1883, "protocol": "TCP"}],
    "ingress": [
        {"from": "dmz", "ports": [8080], "description": "reverse proxy"},
        {"from": "home", "ports": [8080], "description": "clients"},
    ],
    "egress": [
        {"to": "broker", "ports": [1883], "description": "MQTT"},
    ],
}
BROKER = {"vmname": "broker", "zone0": "iot", "bridge0": "lan",
          "ports": [{"port": 1883, "protocol": "TCP"}]}


def _zones(**access):
    return {n: ZoneSpec(name=n, ip_network=z["ip"], bridge="lan", vlan_tag=z["vlantag"],
                        access_to=list(access.get(n, z["access_to"])),
                        pinhole_allowed_from=list(z["paf"]))
            for n, z in ZONES.items()}


class _Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        (self.dir / "app.json").write_text(json.dumps(APP))
        (self.dir / "broker.json").write_text(json.dumps(BROKER))
        self.map = self.dir / "firewall" / "sequence-map.json"

    def tearDown(self):
        self.tmp.cleanup()

    def mgr(self, **access):
        m = RulesManager(Config(firewall="example.invalid", ssl_verify=False), _zones(**access),
                         modules_dir=self.dir, sequence_map_file=self.map)
        m._vlan_iface_cache = {210: "opt1", 610: "opt7", 310: "opt8", 410: "opt3"}
        return m

    def compile(self, m):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            rules, errors = m._compile(load_module(self.dir, "app"))
        self.assertEqual(errors, [])
        return {r.description for r in rules}


class TestCovered(_Base):
    def test_nothing_covered_writes_every_rule(self):
        m = self.mgr()
        descs = self.compile(m)
        self.assertIn("tappaas-module:app:ingress:dmz:8080", descs)
        self.assertIn("tappaas-module:app:ingress:home:8080", descs)
        self.assertIn("tappaas-module:app:egress:broker:1883", descs)
        self.assertEqual(m._covered, [])

    def test_an_ingress_the_peer_zone_reaches_anyway_is_left_out(self):
        m = self.mgr(home=["internet", "srv"])
        descs = self.compile(m)
        self.assertNotIn("tappaas-module:app:ingress:home:8080", descs)
        self.assertIn("tappaas-module:app:ingress:dmz:8080", descs)        # dmz does not reach srv
        self.assertEqual(m._covered, [{"rule": "tappaas-module:app:ingress:home:8080",
                                       "from": "home", "to": "srv"}])

    def test_an_egress_to_a_module_its_zone_reaches_is_left_out(self):
        m = self.mgr(srv=["internet", "iot"])
        descs = self.compile(m)
        self.assertNotIn("tappaas-module:app:egress:broker:1883", descs)
        self.assertEqual(m._covered[0]["from"], "srv")
        self.assertEqual(m._covered[0]["to"], "iot")

    def test_all_covers_every_zone(self):
        m = self.mgr(home=["internet", "all"])
        self.assertNotIn("tappaas-module:app:ingress:home:8080", self.compile(m))

    def test_internet_is_not_a_zone_edge(self):
        m = self.mgr()
        self.assertFalse(m._zone_edge_covers("dmz", "internet"))
        self.assertFalse(m._zone_edge_covers("srv", "srv"))               # within a zone
        self.assertFalse(m._zone_edge_covers("home", "nowhere"))


class TestEgressToInternet(_Base):
    def test_internet_egress_excludes_the_site(self):
        # #817: `to: internet` used to be destination any — every zone too.
        app = dict(APP, egress=APP["egress"] + [
            {"to": "internet", "ports": [443], "description": "updates"}])
        (self.dir / "app.json").write_text(json.dumps(app))
        m = self.mgr()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            rules, _ = m._compile(load_module(self.dir, "app"))
        r = next(r for r in rules if r.description == "tappaas-module:app:egress:internet:443")
        self.assertEqual(r.destination_net, "tappaas_not_internet")
        self.assertTrue(r.destination_invert)
        self.assertTrue(m._to_firewall_rule(r).destination_invert)
        other = next(r for r in rules if r.description == "tappaas-module:app:egress:broker:1883")
        self.assertFalse(other.destination_invert)


class TestSequenceMap(_Base):
    def _write(self, m):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            mod = load_module(self.dir, "app")
            rules, _ = m._compile(mod)
            m._write_sequence_map(mod, rules)
        return json.loads(self.map.read_text())

    def test_the_map_records_slot_time_and_covered_rules(self):
        doc = self._write(self.mgr(home=["internet", "srv"]))
        entry = doc["modules"]["app"]
        self.assertEqual(entry["slot"], stable_hash_index("app"))
        self.assertTrue(doc["generated"])
        self.assertEqual([c["rule"] for c in entry["covered"]], ["tappaas-module:app:ingress:home:8080"])

    def test_a_module_no_longer_deployed_drops_out(self):
        self.map.parent.mkdir(parents=True)
        self.map.write_text(json.dumps({"version": 1, "modules": {"gone": {"slot": 3}}}))
        doc = self._write(self.mgr())
        self.assertNotIn("gone", doc["modules"])

    def test_a_shared_slot_is_reported(self):
        self.map.parent.mkdir(parents=True)
        self.map.write_text(json.dumps({"version": 1, "modules": {
            "broker": {"slot": stable_hash_index("app")}}}))
        err = io.StringIO()
        with contextlib.redirect_stdout(err), contextlib.redirect_stderr(err):
            m = self.mgr()
            mod = load_module(self.dir, "app")
            m._write_sequence_map(mod, m._compile(mod)[0])
        self.assertIn("shared with broker", err.getvalue())
        self.assertIn(stable_hash_index("app"), self.mgr().list_slots()["shared"])

    def test_removing_a_module_forgets_it(self):
        self._write(self.mgr())
        m = self.mgr()
        m._forget_in_sequence_map("app")
        self.assertNotIn("app", json.loads(self.map.read_text())["modules"])


class TestRecheck(_Base):
    def test_a_narrowed_access_to_reconciles_the_module(self):
        TestSequenceMap._write(self, self.mgr(home=["internet", "srv"]))
        m = self.mgr()                                    # home no longer reaches srv
        with mock.patch.object(m, "reconcile") as rec, \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(m.recheck_covered(), ["app"])
        rec.assert_called_once_with("app")

    def test_an_edge_still_there_changes_nothing(self):
        TestSequenceMap._write(self, self.mgr(home=["internet", "srv"]))
        m = self.mgr(home=["internet", "srv"])
        with mock.patch.object(m, "reconcile") as rec:
            self.assertEqual(m.recheck_covered(), [])
        rec.assert_not_called()

    def test_check_mode_reports_without_reconciling(self):
        TestSequenceMap._write(self, self.mgr(home=["internet", "srv"]))
        m = self.mgr()
        m.check_mode = True
        with mock.patch.object(m, "reconcile") as rec, \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(m.recheck_covered(), ["app"])
        rec.assert_not_called()


if __name__ == "__main__":
    unittest.main()
