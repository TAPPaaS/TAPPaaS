"""Unit tests for ipv6-manager's converge (#149).

The firewall's "Allow IPv6" is OPNsense's `disableipv6`, stored negated. These
pin the reading of that switch, that a matching value changes nothing, that
--check-mode writes nothing, and that a change is applied, re-read and followed
by a filter reload, an Unbound restart and a resolver check.

Run with:
    cd src && python -m unittest test.test_ipv6_cli -v
"""

from __future__ import annotations

import unittest
from unittest.mock import MagicMock

from opnsense_controller.ipv6_cli import converge, read_allowed


class FakeFirewall:
    """The interfaces/settings API, over a single disableipv6 value."""

    def __init__(self, disableipv6: str = "0", reconfigure_status: str = "ok"):
        self.disableipv6 = disableipv6
        self.reconfigure_status = reconfigure_status
        self.calls: list[str] = []
        self.client = MagicMock()
        self.client.run_module.side_effect = self._run

    def _run(self, module, params):
        cmd = params["command"]
        self.calls.append(cmd)
        if cmd == "get":
            resp = {"settings": {"disableipv6": self.disableipv6}}
        elif cmd == "set":
            self.disableipv6 = params["data"]["settings"]["disableipv6"]
            resp = {"result": "saved"}
        elif cmd == "reconfigure":
            resp = {"status": self.reconfigure_status}
        else:
            raise AssertionError(cmd)
        return {"result": {"response": resp}}


class TestReadAllowed(unittest.TestCase):
    def test_negated_switch(self):
        self.assertTrue(read_allowed(FakeFirewall("0")))
        self.assertFalse(read_allowed(FakeFirewall("1")))

    def test_missing_field_refuses_to_guess(self):
        fw = FakeFirewall()
        fw.client.run_module.side_effect = lambda m, params: {"result": {"response": {"settings": {}}}}
        with self.assertRaises(RuntimeError):
            read_allowed(fw)


class TestConverge(unittest.TestCase):
    def run_converge(self, fw, allowed, check_mode=False, restart_ok=True, resolver_ok=True,
                     filter_ok=True):
        restart = MagicMock(return_value=restart_ok)
        resolver = MagicMock(return_value=resolver_ok)
        self.reload_filter = MagicMock(return_value=filter_ok)
        ok = converge(fw, allowed, check_mode, restart=restart, resolver_ok=resolver,
                      reload_filter=self.reload_filter)
        return ok, restart, resolver

    def test_matching_value_changes_nothing(self):
        fw = FakeFirewall("1")
        ok, restart, resolver = self.run_converge(fw, allowed=False)
        self.assertTrue(ok)
        self.assertEqual(fw.calls, ["get"])
        restart.assert_not_called()
        resolver.assert_not_called()

    def test_check_mode_writes_nothing(self):
        fw = FakeFirewall("0")
        ok, restart, _ = self.run_converge(fw, allowed=False, check_mode=True)
        self.assertTrue(ok)
        self.assertEqual(fw.disableipv6, "0")
        self.assertNotIn("set", fw.calls)
        restart.assert_not_called()

    def test_disallow_is_applied_and_checked(self):
        fw = FakeFirewall("0")
        ok, restart, resolver = self.run_converge(fw, allowed=False)
        self.assertTrue(ok)
        self.assertEqual(fw.disableipv6, "1")
        self.assertEqual(fw.calls, ["get", "set", "reconfigure", "get"])
        restart.assert_called_once()
        resolver.assert_called_once()
        self.reload_filter.assert_called_once()

    def test_matching_value_reloads_no_filter(self):
        self.run_converge(FakeFirewall("1"), allowed=False)
        self.reload_filter.assert_not_called()

    def test_failed_filter_reload_fails(self):
        ok, restart, _ = self.run_converge(FakeFirewall("0"), allowed=False, filter_ok=False)
        self.assertFalse(ok)
        restart.assert_not_called()

    def test_allow_is_applied(self):
        fw = FakeFirewall("1")
        ok, _, _ = self.run_converge(fw, allowed=True)
        self.assertTrue(ok)
        self.assertEqual(fw.disableipv6, "0")

    def test_resolver_down_after_change_fails(self):
        ok, _, _ = self.run_converge(FakeFirewall("0"), allowed=False, resolver_ok=False)
        self.assertFalse(ok)

    def test_failed_reconfigure_raises(self):
        with self.assertRaises(RuntimeError):
            self.run_converge(FakeFirewall("0", reconfigure_status="failed"), allowed=False)


if __name__ == "__main__":
    unittest.main()
