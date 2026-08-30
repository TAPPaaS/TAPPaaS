"""Offline unit tests for the unbound-manager post-write resolver guard (#516).

A host-override write can return changed=True while the write itself killed
Unbound (redirect-zone collision → unbound-checkconf fails, resolver stops).
These tests cover the guard that catches that at the write instead of silently
returning 0. No OPNsense API, no real DNS — check_unbound_dns is mocked.
"""

import unittest
from unittest.mock import patch

from opnsense_controller import unbound_cli


class TestResolverProbeIp(unittest.TestCase):
    def test_ip_literal_passes_through(self):
        self.assertEqual(unbound_cli._resolver_probe_ip("10.6.0.1"), "10.6.0.1")

    def test_hostname_falls_back_to_mgmt_ip(self):
        # Probing a hostname would need the very resolver we are testing.
        self.assertEqual(
            unbound_cli._resolver_probe_ip("firewall.mgmt.internal"), "10.0.0.1")


class TestVerifyResolverAfterWrite(unittest.TestCase):
    def test_healthy_resolver_returns_true(self):
        with patch.object(unbound_cli, "check_unbound_dns", return_value=True) as m:
            self.assertTrue(
                unbound_cli._verify_resolver_after_write("10.0.0.1", "some write"))
            m.assert_called_once()

    def test_dead_resolver_returns_false_and_reports_validator_output(self):
        import io
        import contextlib
        buf = io.StringIO()
        checkconf = (False, "local-data in redirect zone must reside at top of zone")
        with patch.object(unbound_cli, "check_unbound_dns", return_value=False), \
             patch.object(unbound_cli, "unbound_checkconf", return_value=checkconf) as m:
            with contextlib.redirect_stderr(buf):
                ok = unbound_cli._verify_resolver_after_write(
                    "firewall.mgmt.internal", "host override a.b -> 10.6.0.1")
        self.assertFalse(ok)
        err = buf.getvalue()
        # Validator ran against the IP-literal probe target (not the unresolvable
        # hostname), and its deterministic fatal line is surfaced to the operator.
        m.assert_called_once_with("10.0.0.1")
        self.assertIn("stopped", err)
        self.assertIn("10.0.0.1:53", err)
        self.assertIn("unbound-checkconf", err)
        self.assertIn("redirect zone must reside at top of zone", err)


if __name__ == "__main__":
    unittest.main()
