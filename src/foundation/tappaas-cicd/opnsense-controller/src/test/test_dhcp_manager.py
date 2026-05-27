"""Unit tests for DhcpManager DHCP-range binding (issue #179).

Background: the oxl-opnsense-client ``dnsmasq_range`` module does not pass the
``interface`` parameter through to OPNsense, so every range it created was
written unbound (``interface=''``). DhcpManager now creates/deletes ranges via
the raw ``addRange``/``delRange`` API, which binds the interface correctly.

These tests assert — without an OPNsense connection — that the ``interface``
survives all the way into the raw API payload, that creates are idempotent
(existing range deleted first), and that API failures are surfaced rather than
silently swallowed.

Run with:
    cd src && python -m unittest test.test_dhcp_manager -v
"""

from __future__ import annotations

import unittest
from unittest.mock import MagicMock

from opnsense_controller.dhcp_manager import DhcpManager, DhcpRange


# ─────────────────────────────────────────────────────────────────────────────
# Fake client
# ─────────────────────────────────────────────────────────────────────────────


def _searchRange(rows):
    return {"result": {"response": {"rows": rows}}}


def _make_manager(existing_rows=None):
    """Build a DhcpManager wired to a fake client.

    The fake client routes raw `run_module` calls by command:
      - searchRange -> returns `existing_rows`
      - delRange    -> {"result": "deleted"}
      - addRange    -> {"result": "saved", "uuid": "new-uuid"}
      - reconfigure -> {"status": "ok"}
    All calls are recorded on `manager.client.run_module.call_args_list`.
    """
    existing_rows = existing_rows or []

    def run_module(module, **kwargs):
        params = kwargs.get("params", {})
        command = params.get("command")
        if command == "searchRange":
            return _searchRange(existing_rows)
        if command == "delRange":
            return {"result": {"response": {"result": "deleted"}}}
        if command == "addRange":
            return {"result": {"response": {"result": "saved", "uuid": "new-uuid"}}}
        if command == "reconfigure":
            return {"result": {"response": {"status": "ok"}}}
        return {"result": {"response": {}}}

    manager = DhcpManager(config=MagicMock())
    manager._client = MagicMock()
    manager._client.run_module.side_effect = run_module
    return manager


def _calls_for(manager, command):
    """All run_module calls whose params['command'] == command."""
    out = []
    for call in manager.client.run_module.call_args_list:
        params = call.kwargs.get("params", {})
        if params.get("command") == command:
            out.append(params)
    return out


# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────


class TestCreateRangeBinding(unittest.TestCase):
    def test_interface_is_passed_to_raw_addrange(self):
        """The #179 regression: the interface must reach the addRange payload."""
        manager = _make_manager(existing_rows=[])
        result = manager.create_range(
            DhcpRange(
                description="home DHCP",
                start_addr="10.3.10.50",
                end_addr="10.3.10.250",
                interface="opt1",
                domain="home.internal",
            )
        )

        add_calls = _calls_for(manager, "addRange")
        self.assertEqual(len(add_calls), 1)
        range_payload = add_calls[0]["data"]["range"]
        # The whole point of #179: interface present and non-empty.
        self.assertEqual(range_payload["interface"], "opt1")
        self.assertEqual(range_payload["start_addr"], "10.3.10.50")
        self.assertEqual(range_payload["domain"], "home.internal")
        self.assertTrue(result["changed"])
        self.assertEqual(result["interface"], "opt1")

    def test_no_interface_key_when_unbound(self):
        """A range with interface=None must not send an empty interface key."""
        manager = _make_manager(existing_rows=[])
        manager.create_range(
            DhcpRange(
                description="any DHCP",
                start_addr="10.9.0.50",
                end_addr="10.9.0.250",
                interface=None,
            )
        )
        range_payload = _calls_for(manager, "addRange")[0]["data"]["range"]
        self.assertNotIn("interface", range_payload)

    def test_create_is_idempotent_deletes_existing_first(self):
        """An existing range with the same description is deleted before re-add."""
        existing = [{
            "uuid": "old-uuid",
            "description": "home DHCP",
            "start_addr": "10.3.10.50",
            "end_addr": "10.3.10.250",
            "interface": "",  # previously written unbound (the bug)
        }]
        manager = _make_manager(existing_rows=existing)
        manager.create_range(
            DhcpRange(
                description="home DHCP",
                start_addr="10.3.10.50",
                end_addr="10.3.10.250",
                interface="opt1",
            )
        )

        del_calls = _calls_for(manager, "delRange")
        self.assertEqual(len(del_calls), 1)
        self.assertEqual(del_calls[0]["params"], ["old-uuid"])
        # And then it rebinds with the interface set.
        self.assertEqual(
            _calls_for(manager, "addRange")[0]["data"]["range"]["interface"], "opt1"
        )

    def test_addrange_failure_raises(self):
        """A non-'saved' API response must raise, not silently succeed."""
        manager = _make_manager(existing_rows=[])

        def failing(module, **kwargs):
            params = kwargs.get("params", {})
            if params.get("command") == "searchRange":
                return _searchRange([])
            if params.get("command") == "addRange":
                return {"result": {"response": {"result": "failed"}}}
            return {"result": {"response": {}}}

        manager._client.run_module.side_effect = failing
        with self.assertRaises(RuntimeError):
            manager.create_range(
                DhcpRange(
                    description="bad DHCP",
                    start_addr="10.0.0.50",
                    end_addr="10.0.0.250",
                    interface="opt1",
                )
            )

    def test_check_mode_makes_no_api_calls(self):
        manager = _make_manager(existing_rows=[])
        result = manager.create_range(
            DhcpRange(
                description="home DHCP",
                start_addr="10.3.10.50",
                end_addr="10.3.10.250",
                interface="opt1",
            ),
            check_mode=True,
        )
        self.assertTrue(result["check_mode"])
        manager.client.run_module.assert_not_called()


class TestDeleteRange(unittest.TestCase):
    def test_delete_by_uuid_via_raw(self):
        existing = [{"uuid": "u-1", "description": "home DHCP"}]
        manager = _make_manager(existing_rows=existing)
        result = manager.delete_range("home DHCP")
        del_calls = _calls_for(manager, "delRange")
        self.assertEqual(len(del_calls), 1)
        self.assertEqual(del_calls[0]["params"], ["u-1"])
        self.assertTrue(result["changed"])

    def test_delete_missing_range_is_noop(self):
        manager = _make_manager(existing_rows=[])
        result = manager.delete_range("ghost DHCP")
        self.assertFalse(result["changed"])
        self.assertEqual(_calls_for(manager, "delRange"), [])


class TestListLeases(unittest.TestCase):
    """list_leases queries the dnsmasq leases controller and maps fields (#235)."""

    def _manager_with_leases(self, rows):
        def run_module(module, **kwargs):
            params = kwargs.get("params", {})
            if params.get("controller") == "leases" and params.get("command") == "search":
                return {"result": {"response": {"rows": rows}}}
            return {"result": {"response": {}}}

        manager = DhcpManager(config=MagicMock())
        manager._client = MagicMock()
        manager._client.run_module.side_effect = run_module
        return manager

    def test_maps_api_fields_to_lease_dict(self):
        rows = [{
            "address": "10.2.10.217", "hostname": "litellm",
            "hwaddr": "02:f4:59:9a:2d:ba", "if_name": "opt11",
            "if_descr": "srv_home", "expire": 1779954626,
        }]
        manager = self._manager_with_leases(rows)
        leases = manager.list_leases()
        self.assertEqual(len(leases), 1)
        self.assertEqual(leases[0], {
            "ip": "10.2.10.217", "hostname": "litellm",
            "mac": "02:f4:59:9a:2d:ba", "zone": "srv_home",
            "interface": "opt11", "expire": 1779954626,
        })

    def test_queries_dnsmasq_leases_controller(self):
        manager = self._manager_with_leases([])
        manager.list_leases()
        params = manager.client.run_module.call_args.kwargs["params"]
        self.assertEqual(params["module"], "dnsmasq")
        self.assertEqual(params["controller"], "leases")
        self.assertEqual(params["command"], "search")

    def test_sorted_by_zone_then_numeric_ip(self):
        rows = [
            {"address": "10.0.0.134", "hostname": "cicd", "hwaddr": "a", "if_descr": "LAN", "if_name": "lan", "expire": 1},
            {"address": "10.2.10.217", "hostname": "litellm", "hwaddr": "b", "if_descr": "srv_home", "if_name": "opt11", "expire": 2},
            {"address": "10.2.10.9", "hostname": "early", "hwaddr": "c", "if_descr": "srv_home", "if_name": "opt11", "expire": 3},
        ]
        leases = self._manager_with_leases(rows).list_leases()
        # LAN before srv_home; within srv_home .9 sorts before .217 numerically.
        self.assertEqual([l["hostname"] for l in leases], ["cicd", "early", "litellm"])

    def test_missing_hostname_becomes_empty(self):
        rows = [{"address": "10.0.0.5", "hwaddr": "x", "if_descr": "LAN", "if_name": "lan", "expire": 0}]
        leases = self._manager_with_leases(rows).list_leases()
        self.assertEqual(leases[0]["hostname"], "")


if __name__ == "__main__":
    unittest.main()
