"""Offline unit tests for the pending-registration store (registry.py).

Covers: registration CRUD round-trip in a temp dir, pool-spec parsing,
MAC normalization, answer matching (MAC hit / single-pending fallback /
no match) and one-shot consumption.
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from node_provisioner.registry import (
    Registry,
    normalize_mac,
    parse_pool_spec,
)


class TestNormalizeMac(unittest.TestCase):
    def test_normalizes_case_and_separator(self):
        self.assertEqual(normalize_mac("AA-BB-CC-DD-EE-0F"),
                         "aa:bb:cc:dd:ee:0f")
        self.assertEqual(normalize_mac(" aa:bb:cc:dd:ee:ff "),
                         "aa:bb:cc:dd:ee:ff")

    def test_rejects_garbage(self):
        for bad in ("aa:bb:cc:dd:ee", "nonsense", "aa:bb:cc:dd:ee:gg", ""):
            with self.assertRaises(ValueError):
                normalize_mac(bad)


class TestParsePoolSpec(unittest.TestCase):
    def test_single(self):
        self.assertEqual(
            parse_pool_spec("tanka1=single:nvme0n1"),
            {"name": "tanka1", "layout": "single", "disks": ["nvme0n1"]},
        )

    def test_mirror_multi_disk(self):
        self.assertEqual(
            parse_pool_spec("tankb1=mirror:sdb,sdc"),
            {"name": "tankb1", "layout": "mirror", "disks": ["sdb", "sdc"]},
        )

    def test_rejects_bad_specs(self):
        for bad in (
            "tanka1",                    # no '='
            "tanka1=nvme0n1",            # no layout separator
            "tanka1=fancy:nvme0n1",      # unknown layout
            "tanka1=single:",            # no disks
            "tanka1=single:sda,sdb",     # single takes exactly one disk
            "tanka1=mirror:sda",         # mirror needs two
            "bad name=single:sda",       # invalid pool name
        ):
            with self.assertRaises(ValueError, msg=bad):
                parse_pool_spec(bad)


class RegistryCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.registry = Registry(directory=Path(self._tmp.name) / "provision")


class TestCrudRoundTrip(RegistryCase):
    def test_register_list_load_unregister(self):
        reg = self.registry.register(
            "tappaas3",
            macs=["AA-BB-CC-DD-EE-FF"],
            pool_specs=["tanka1=single:nvme0n1"],
        )
        self.assertTrue(reg.path.is_file())

        # File content is the documented JSON shape.
        data = json.loads(reg.path.read_text())
        self.assertEqual(data["name"], "tappaas3")
        self.assertEqual(data["macs"], ["aa:bb:cc:dd:ee:ff"])
        self.assertEqual(data["pools"], [
            {"name": "tanka1", "layout": "single", "disks": ["nvme0n1"]}])
        self.assertTrue(data["created"])

        listed = self.registry.list_pending()
        self.assertEqual([r.name for r in listed], ["tappaas3"])

        loaded = self.registry.load("tappaas3")
        self.assertEqual(loaded.macs, ["aa:bb:cc:dd:ee:ff"])
        self.assertEqual(loaded.pools[0]["disks"], ["nvme0n1"])

        self.assertTrue(self.registry.unregister("tappaas3"))
        self.assertEqual(self.registry.list_pending(), [])
        self.assertFalse(self.registry.unregister("tappaas3"))

    def test_register_rejects_bad_name(self):
        with self.assertRaises(ValueError):
            self.registry.register("bad name!")

    def test_reregister_replaces(self):
        self.registry.register("tappaas3", macs=["aa:bb:cc:dd:ee:01"])
        self.registry.register("tappaas3", macs=["aa:bb:cc:dd:ee:02"])
        pending = self.registry.list_pending()
        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0].macs, ["aa:bb:cc:dd:ee:02"])


class TestMatching(RegistryCase):
    def test_mac_hit_wins_over_fallback(self):
        self.registry.register("tappaas3", macs=["aa:bb:cc:dd:ee:03"])
        self.registry.register("tappaas4", macs=["aa:bb:cc:dd:ee:04"])
        match = self.registry.match(["AA-BB-CC-DD-EE-04", "11:22:33:44:55:66"])
        self.assertEqual(match.name, "tappaas4")

    def test_single_pending_fallback(self):
        self.registry.register("tappaas3")  # no MAC pinned
        match = self.registry.match(["de:ad:be:ef:00:01"])
        self.assertEqual(match.name, "tappaas3")

    def test_no_match_with_multiple_pending_and_no_mac_hit(self):
        self.registry.register("tappaas3")
        self.registry.register("tappaas4")
        self.assertIsNone(self.registry.match(["de:ad:be:ef:00:01"]))

    def test_no_match_when_nothing_pending(self):
        self.assertIsNone(self.registry.match(["de:ad:be:ef:00:01"]))

    def test_unparsable_posted_macs_are_ignored(self):
        self.registry.register("tappaas3", macs=["aa:bb:cc:dd:ee:03"])
        self.registry.register("tappaas4")
        self.assertIsNone(self.registry.match(["garbage", None, ""]))


class TestOneShotConsumption(RegistryCase):
    def test_consume_renames_and_hides(self):
        reg = self.registry.register("tappaas3")
        self.assertTrue(self.registry.consume("tappaas3"))

        # gone from pending, present as .consumed
        self.assertEqual(self.registry.list_pending(), [])
        self.assertIsNone(self.registry.match(["aa:bb:cc:dd:ee:03"]))
        consumed = reg.path.with_name(reg.path.name + ".consumed")
        self.assertTrue(consumed.is_file())

        # consuming twice is a no-op
        self.assertFalse(self.registry.consume("tappaas3"))


if __name__ == "__main__":
    unittest.main()
