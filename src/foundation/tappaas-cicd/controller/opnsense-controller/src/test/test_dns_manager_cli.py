"""Unit tests for the dns-manager CLI check-range command (issue #251).

check_dns_range is a thin wrapper over DhcpManager.ip_in_any_range: it must
return True (shell exit 0) when the IP is clear of every DHCP pool, False
(shell exit 1) when it is inside one, and must never raise — a query failure
is reported as "clear" so it cannot block a module install.

Run with:
    cd src && python -m unittest test.test_dns_manager_cli -v
"""

from __future__ import annotations

import unittest
from unittest.mock import MagicMock

from opnsense_controller.dns_manager_cli import check_dns_range


class TestCheckDnsRange(unittest.TestCase):
    def test_ip_clear_returns_true(self):
        manager = MagicMock()
        manager.ip_in_any_range.return_value = None
        self.assertTrue(check_dns_range(manager, "10.2.20.25"))
        manager.ip_in_any_range.assert_called_once_with("10.2.20.25")

    def test_ip_inside_pool_returns_false(self):
        manager = MagicMock()
        manager.ip_in_any_range.return_value = {
            "description": "srvWork",
            "start_addr": "10.2.20.100",
            "end_addr": "10.2.20.200",
        }
        self.assertFalse(check_dns_range(manager, "10.2.20.150"))

    def test_query_failure_does_not_block(self):
        """If the range query raises, treat the IP as clear (return True)."""
        manager = MagicMock()
        manager.ip_in_any_range.side_effect = RuntimeError("API down")
        self.assertTrue(check_dns_range(manager, "10.2.20.25"))


if __name__ == "__main__":
    unittest.main()


# ── release (#672): only the entry TAPPaaS created for a machine ─────────
#
# Field shapes as a live OPNsense returns them (hrossen, 2026-09-19): searchHost
# rows carry NO MAC (hardware_addr is null even for a reservation); getHost
# returns hwaddr/cnames as multi-selects, "empty" being one selected blank value.

from opnsense_controller.dhcp_manager import DhcpManager  # noqa: E402
from opnsense_controller.dns_manager_cli import release_machine_host  # noqa: E402

_EMPTY = {"": {"value": "", "selected": 1}}


def _sel(*values):
    return {v: {"value": v, "selected": 1} for v in values} if values else dict(_EMPTY)


def _release_manager(rows, full):
    """rows: searchHost-shaped dicts; full: uuid -> getHost-shaped dict."""
    m = MagicMock()
    m.list_hosts.return_value = rows
    m.get_host_full.side_effect = lambda uuid: full[uuid]
    m._selected = DhcpManager._selected
    m.delete_host_by_uuid.return_value = {"changed": True}
    return m


def _row(uuid, host, descr, domain="mgmt.internal"):
    return {"uuid": uuid, "host": host, "domain": domain, "description": descr,
            "ip": "10.0.0.90", "hardware_addr": None}


class TestReleaseMachineHost(unittest.TestCase):
    def test_releases_the_entry_tappaas_created(self):
        m = _release_manager([_row("u1", "dh-test1", "TAPPaaS machine dh-test1")],
                             {"u1": {"hwaddr": _sel(), "cnames": _sel()}})
        self.assertTrue(release_machine_host(m, "dh-test1", "mgmt.internal"))
        m.delete_host_by_uuid.assert_called_once_with("u1")

    def test_keeps_a_dhcp_reservation_even_with_our_description(self):
        # The listing says hardware_addr None; only getHost shows the MAC.
        m = _release_manager([_row("u1", "dh-test1", "TAPPaaS machine dh-test1")],
                             {"u1": {"hwaddr": _sel("de:ad:be:ef:00:01"), "cnames": _sel()}})
        self.assertTrue(release_machine_host(m, "dh-test1", "mgmt.internal"))
        m.delete_host_by_uuid.assert_not_called()

    def test_keeps_an_entry_that_still_carries_an_alias(self):
        m = _release_manager([_row("u1", "dh-test1", "TAPPaaS machine dh-test1")],
                             {"u1": {"hwaddr": _sel(), "cnames": _sel("backup.mgmt.internal")}})
        self.assertTrue(release_machine_host(m, "dh-test1", "mgmt.internal"))
        m.delete_host_by_uuid.assert_not_called()

    def test_never_touches_an_entry_tappaas_did_not_create(self):
        for descr in ("", "TAPPaaS node tappaas3", "PBS Backup Server", "TAPPaaS machine other"):
            m = _release_manager([_row("u1", "dh-test1", descr)],
                                 {"u1": {"hwaddr": _sel(), "cnames": _sel()}})
            self.assertTrue(release_machine_host(m, "dh-test1", "mgmt.internal"))
            m.delete_host_by_uuid.assert_not_called()
            m.get_host_full.assert_not_called()

    def test_only_the_named_host_in_the_named_domain(self):
        m = _release_manager([_row("u1", "dh-test1", "TAPPaaS machine dh-test1", domain="srv.internal")],
                             {"u1": {"hwaddr": _sel(), "cnames": _sel()}})
        self.assertTrue(release_machine_host(m, "dh-test1", "mgmt.internal"))
        m.delete_host_by_uuid.assert_not_called()

    def test_nothing_to_release_is_not_an_error(self):
        m = _release_manager([], {})
        self.assertTrue(release_machine_host(m, "dh-test1", "mgmt.internal"))
        m.delete_host_by_uuid.assert_not_called()

    def test_check_mode_deletes_nothing(self):
        m = _release_manager([_row("u1", "dh-test1", "TAPPaaS machine dh-test1")],
                             {"u1": {"hwaddr": _sel(), "cnames": _sel()}})
        self.assertTrue(release_machine_host(m, "dh-test1", "mgmt.internal", check_mode=True))
        m.delete_host_by_uuid.assert_not_called()

    def test_ambiguous_entries_are_all_left(self):
        m = _release_manager([_row("u1", "dh-test1", "TAPPaaS machine dh-test1"),
                              _row("u2", "dh-test1", "TAPPaaS machine dh-test1")],
                             {"u1": {"hwaddr": _sel(), "cnames": _sel()},
                              "u2": {"hwaddr": _sel(), "cnames": _sel()}})
        self.assertTrue(release_machine_host(m, "dh-test1", "mgmt.internal"))
        m.delete_host_by_uuid.assert_not_called()

    def test_a_failed_delete_is_an_error(self):
        m = _release_manager([_row("u1", "dh-test1", "TAPPaaS machine dh-test1")],
                             {"u1": {"hwaddr": _sel(), "cnames": _sel()}})
        m.delete_host_by_uuid.return_value = {"changed": False, "error": "nope"}
        self.assertFalse(release_machine_host(m, "dh-test1", "mgmt.internal"))
