"""A DNS entry is identified by its name, not by its description (#702).

`dns-manager add` used to find the entry to write with
get_host_by_description(), so --description decided which record was touched:
a description matching nothing added a SECOND A-record for a name that already
existed, and one reused across names made each add overwrite the previous
name's entry. Both printed "No changes made (entry already up to date)".

The default description is "<host>.<domain>", unique by construction, which is
why the defect stayed invisible for every caller that did not pass one.

Run with:
    cd src && python -m unittest test.test_dns_add_identity -v
"""

from __future__ import annotations

import unittest
from unittest.mock import MagicMock

from opnsense_controller.dhcp_manager import DhcpManager


class FakeClient:
    """A dnsmasq host table that answers searchHost/getHost/addHost/setHost."""

    def __init__(self, rows=None):
        self.rows = list(rows or [])
        self.calls: list[tuple[str, list, dict]] = []
        self._next = 100

    def run_module(self, module, check_mode=False, params=None):
        params = params or {}
        command = params.get("command")
        if module != "raw":
            # reconfigure() and friends: accept and record, answer harmlessly.
            self.calls.append((module, [], {}))
            return {"result": {"status": "ok"}}
        data = (params.get("data") or {}).get("host", {})
        self.calls.append((command, params.get("params") or [], data))
        if command == "searchHost":
            return {"result": {"response": {"rows": self.rows}}}
        if command == "getHost":
            uuid = (params.get("params") or [None])[0]
            for r in self.rows:
                if r.get("uuid") == uuid:
                    return {"result": {"response": {"host": r.get("_full", {})}}}
            return {"result": {"response": {"host": {}}}}
        if command == "addHost":
            self._next += 1
            uuid = f"uuid-{self._next}"
            row = dict(data)
            row["uuid"] = uuid
            self.rows.append(row)
            return {"result": {"response": {"result": "saved", "uuid": uuid}}}
        if command == "setHost":
            uuid = (params.get("params") or [None])[0]
            for r in self.rows:
                if r.get("uuid") == uuid:
                    r.update(data)          # setHost MERGES (see _set_cnames)
            return {"result": {"response": {"result": "saved"}}}
        return {"result": {"response": {}}}

    # Convenience for the assertions below.
    def commands(self):
        return [c for c, _p, _d in self.calls]

    def payload_of(self, command):
        for c, _p, d in self.calls:
            if c == command:
                return d
        return None


def manager_with(rows=None):
    """A manager whose client is the fake table (idiom from test_dhcp_manager)."""
    fake = FakeClient(rows)
    m = DhcpManager(config=MagicMock())
    m._client = MagicMock()
    m._client.run_module.side_effect = fake.run_module
    m.client_fake = fake                      # what the assertions read
    return m


ROW_A = {"uuid": "uuid-a", "host": "svc-a", "domain": "example.internal",
         "ip": "10.0.0.50", "descr": "shared"}


class TestIdentityIsTheName(unittest.TestCase):
    def test_two_names_one_description_are_two_entries(self):
        """The issue's own reproduction: svc-a must survive adding svc-b."""
        m = manager_with([ROW_A.copy()])
        r = m.upsert_dns_host("svc-b", "example.internal", "10.0.0.51",
                              description="shared")
        self.assertEqual(r["action"], "created")
        self.assertIn("addHost", m.client_fake.commands())
        self.assertNotIn("setHost", m.client_fake.commands())
        hosts = sorted(row["host"] for row in m.client_fake.rows)
        self.assertEqual(hosts, ["svc-a", "svc-b"])
        svc_a = [row for row in m.client_fake.rows if row["host"] == "svc-a"][0]
        self.assertEqual(svc_a["ip"], "10.0.0.50")

    def test_same_name_new_description_updates_in_place(self):
        """A changed description must not mint a second A-record for the name."""
        m = manager_with([ROW_A.copy()])
        r = m.upsert_dns_host("svc-a", "example.internal", "10.0.0.50",
                              description="a new description")
        self.assertEqual(r["action"], "updated")
        self.assertEqual(r["changes"], ["descr"])
        self.assertIn("setHost", m.client_fake.commands())
        self.assertNotIn("addHost", m.client_fake.commands())
        self.assertEqual(len(m.client_fake.rows), 1)

    def test_nothing_to_do_is_reported_as_such(self):
        m = manager_with([ROW_A.copy()])
        r = m.upsert_dns_host("svc-a", "example.internal", "10.0.0.50")
        self.assertEqual(r["action"], "unchanged")
        self.assertNotIn("setHost", m.client_fake.commands())
        self.assertNotIn("addHost", m.client_fake.commands())

    def test_an_address_correction_updates_that_name(self):
        m = manager_with([ROW_A.copy()])
        r = m.upsert_dns_host("svc-a", "example.internal", "10.0.0.99")
        self.assertEqual(r["action"], "updated")
        self.assertEqual(r["changes"], ["ip"])
        self.assertEqual(m.client_fake.rows[0]["ip"], "10.0.0.99")


class TestAnUpdateKeepsWhatItWasNotAsked(unittest.TestCase):
    def test_update_sends_only_what_changed(self):
        """setHost merges, so an address fix must not carry descr/hwaddr/cnames."""
        m = manager_with([ROW_A.copy()])
        m.upsert_dns_host("svc-a", "example.internal", "10.0.0.99")
        sent = m.client_fake.payload_of("setHost")
        self.assertEqual(sent.get("ip"), "10.0.0.99")
        self.assertNotIn("descr", sent)
        self.assertNotIn("hwaddr", sent)
        self.assertNotIn("cnames", sent)

    def test_the_default_description_does_not_overwrite_the_operators(self):
        """The CLI defaults description to host.domain; that is not a change."""
        m = manager_with([ROW_A.copy()])
        r = m.upsert_dns_host("svc-a", "example.internal", "10.0.0.50",
                              description=None)
        self.assertEqual(r["action"], "unchanged")
        self.assertEqual(m.client_fake.rows[0]["descr"], "shared")

    def test_no_mac_given_does_not_clear_a_reservation(self):
        row = dict(ROW_A, _full={"hwaddr": {"aa:bb:cc:dd:ee:ff": {"selected": 1}}})
        m = manager_with([row])
        m.upsert_dns_host("svc-a", "example.internal", "10.0.0.99")
        sent = m.client_fake.payload_of("setHost")
        self.assertNotIn("hwaddr", sent)

    def test_a_changed_mac_is_compared_against_getHost(self):
        """searchHost reports no hwaddr (#672), so the check must fetch the entry."""
        row = dict(ROW_A, _full={"hwaddr": {"aa:bb:cc:dd:ee:ff": {"selected": 1}}})
        m = manager_with([row])
        r = m.upsert_dns_host("svc-a", "example.internal", "10.0.0.50",
                              mac="11:22:33:44:55:66")
        self.assertEqual(r["action"], "updated")
        self.assertEqual(r["changes"], ["hwaddr"])
        self.assertIn("getHost", m.client_fake.commands())
        self.assertEqual(m.client_fake.payload_of("setHost").get("hwaddr"),
                         "11:22:33:44:55:66")

    def test_the_same_mac_is_not_a_change(self):
        row = dict(ROW_A, _full={"hwaddr": {"aa:bb:cc:dd:ee:ff": {"selected": 1}}})
        m = manager_with([row])
        r = m.upsert_dns_host("svc-a", "example.internal", "10.0.0.50",
                              mac="aa:bb:cc:dd:ee:ff")
        self.assertEqual(r["action"], "unchanged")


class TestDryRun(unittest.TestCase):
    def test_check_mode_writes_nothing(self):
        m = manager_with([ROW_A.copy()])
        r = m.upsert_dns_host("svc-a", "example.internal", "10.0.0.99",
                              check_mode=True)
        self.assertEqual(r["action"], "would-update")
        self.assertEqual(r["changes"], ["ip"])
        self.assertNotIn("setHost", m.client_fake.commands())

    def test_check_mode_on_a_new_name(self):
        m = manager_with([])
        r = m.upsert_dns_host("svc-new", "example.internal", "10.0.0.60",
                              check_mode=True)
        self.assertEqual(r["action"], "would-create")
        self.assertNotIn("addHost", m.client_fake.commands())


class TestFailuresAreLoud(unittest.TestCase):
    def test_a_refused_save_raises(self):
        m = manager_with([])

        def refuse(module, check_mode=False, params=None):
            command = (params or {}).get("command")
            if command == "searchHost":
                return {"result": {"response": {"rows": []}}}
            return {"result": {"response": {"result": "failed"}}}

        m._client.run_module.side_effect = refuse
        with self.assertRaises(RuntimeError):
            m.upsert_dns_host("svc-x", "example.internal", "10.0.0.70")


if __name__ == "__main__":
    unittest.main()
