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


def _row(hostname, domain, server="10.6.0.1", rr="A"):
    return {"hostname": hostname, "domain": domain, "server": server, "rr": rr}


class TestRedirectZoneGuard(unittest.TestCase):
    """#649: a '*' override is a redirect zone; nothing may sit anywhere below it."""

    def _args(self, hostname, domain, ip="10.6.0.1"):
        from types import SimpleNamespace
        return SimpleNamespace(hostname=hostname, domain=domain, ip=ip)

    def test_grandparent_wildcard_covers_nested_name(self):
        # The live case: *.example.com, then service.demo.example.com. The old
        # shell guard compared only the immediate parent (demo.example.com).
        rows = [_row("*", "example.com")]
        wc = unbound_cli._covering_wildcard(rows, "service", "demo.example.com")
        self.assertEqual(wc["domain"], "example.com")

    def test_deepest_wildcard_wins(self):
        rows = [_row("*", "example.com"), _row("*", "demo.example.com", "10.6.0.2")]
        wc = unbound_cli._covering_wildcard(rows, "service", "demo.example.com")
        self.assertEqual(wc["domain"], "demo.example.com")

    def test_unrelated_and_lookalike_domains_are_not_covered(self):
        rows = [_row("*", "example.com")]
        self.assertIsNone(unbound_cli._covering_wildcard(rows, "svc", "example.org"))
        # Suffix match must be on a label boundary.
        self.assertIsNone(unbound_cli._covering_wildcard(rows, "svc", "badexample.com"))

    def test_match_is_case_insensitive(self):
        rows = [_row("*", "Example.COM")]
        self.assertIsNotNone(unbound_cli._covering_wildcard(rows, "svc", "demo.example.com"))

    def test_same_ip_under_wildcard_is_skipped_as_success(self):
        rows = [_row("*", "example.com")]
        self.assertTrue(unbound_cli._check_redirect_zone(
            rows, self._args("service", "demo.example.com")))

    def test_different_ip_under_wildcard_is_refused(self):
        import io
        import contextlib
        rows = [_row("*", "example.com")]
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertFalse(unbound_cli._check_redirect_zone(
                rows, self._args("service", "demo.example.com", "10.9.9.9")))

    def test_wildcard_over_existing_nested_records_is_refused(self):
        import io
        import contextlib
        rows = [_row("service", "demo.example.com"), _row("cloud", "example.com"),
                _row("cloud", "example.org")]
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            self.assertFalse(unbound_cli._check_redirect_zone(
                rows, self._args("*", "example.com")))
        err = buf.getvalue()
        self.assertIn("'service' 'demo.example.com'", err)
        self.assertIn("'cloud' 'example.com'", err)
        self.assertNotIn("example.org", err)

    def test_unrelated_writes_pass(self):
        rows = [_row("*", "example.com"), _row("cloud", "example.org")]
        self.assertIsNone(unbound_cli._check_redirect_zone(
            rows, self._args("svc", "example.org")))
        self.assertIsNone(unbound_cli._check_redirect_zone(
            rows, self._args("*", "example.net")))


class TestRollbackOnDeadResolver(unittest.TestCase):
    """#649: a write that stops Unbound is undone, not left for 9 hours."""

    def _add(self, was_up):
        from types import SimpleNamespace
        from unittest.mock import MagicMock
        args = SimpleNamespace(hostname="svc", domain="example.com", ip="10.6.0.1",
                               description=None, check_mode=False,
                               firewall="10.0.0.1")
        mgr = MagicMock()
        mgr.client.run_module.return_value = {"result": {"changed": True}}
        client = MagicMock()
        client.__enter__.return_value = mgr
        with patch.object(unbound_cli, "_client", return_value=client), \
             patch.object(unbound_cli, "_search_overrides", return_value=[]), \
             patch.object(unbound_cli, "_find_a_overrides", return_value=[]), \
             patch.object(unbound_cli, "check_unbound_dns", return_value=was_up), \
             patch.object(unbound_cli, "_verify_resolver_after_write", return_value=False), \
             patch.object(unbound_cli, "_rollback_add") as rb:
            ok = unbound_cli.add_override(args)
        return ok, rb

    def test_write_that_kills_resolver_is_rolled_back(self):
        ok, rb = self._add(was_up=True)
        self.assertFalse(ok)
        rb.assert_called_once()

    def test_resolver_already_down_is_not_blamed_on_this_write(self):
        ok, rb = self._add(was_up=False)
        self.assertFalse(ok)
        rb.assert_not_called()


if __name__ == "__main__":
    unittest.main()
