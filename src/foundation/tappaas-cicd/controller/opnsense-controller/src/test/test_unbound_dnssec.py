"""unbound-manager dnssec brings Unbound's validation to site.json (#263).

Run with:
    cd src && python -m unittest test.test_unbound_dnssec -v
"""

from __future__ import annotations

import contextlib
import io
import unittest
from types import SimpleNamespace
from unittest import mock

from opnsense_controller import unbound_cli


class FakeUnbound:
    def __init__(self, value):
        self.value, self.calls = value, []

    def api(self, mgr, controller, command, action, data=None, params=None):
        self.calls.append(command)
        if command == "get":
            return {"unbound": {"general": {"dnssec": self.value}}}
        if command == "set":
            self.value = data["unbound"]["general"]["dnssec"]
            return {"result": "saved"}
        return {"status": "ok"}


class TestDnssec(unittest.TestCase):
    def run_it(self, value, want, check_mode=False):
        fake = FakeUnbound(value)
        args = SimpleNamespace(set=want, check_mode=check_mode, firewall="fw")

        @contextlib.contextmanager
        def client(_):
            yield object()
        with mock.patch.object(unbound_cli, "_unbound_api", fake.api), \
                mock.patch.object(unbound_cli, "_client", client), \
                mock.patch.object(unbound_cli, "_verify_resolver_after_write", return_value=True) as ver, \
                contextlib.redirect_stdout(io.StringIO()):
            ok = unbound_cli.dnssec(args)
        return ok, fake, ver

    def test_matching_changes_nothing(self):
        ok, fake, ver = self.run_it("1", True)
        self.assertTrue(ok)
        self.assertEqual(fake.calls, ["get"])
        ver.assert_not_called()

    def test_a_change_is_written_reloaded_and_checked(self):
        ok, fake, ver = self.run_it("0", True)
        self.assertTrue(ok)
        self.assertEqual(fake.value, "1")
        self.assertIn("reconfigure", fake.calls)
        ver.assert_called_once()

    def test_check_mode_writes_nothing(self):
        ok, fake, _ = self.run_it("0", True, check_mode=True)
        self.assertTrue(ok)
        self.assertEqual(fake.value, "0")
        self.assertNotIn("set", fake.calls)

    def test_an_odd_value_is_not_guessed(self):
        with self.assertRaises(RuntimeError):
            self.run_it("", True)


if __name__ == "__main__":
    unittest.main()
