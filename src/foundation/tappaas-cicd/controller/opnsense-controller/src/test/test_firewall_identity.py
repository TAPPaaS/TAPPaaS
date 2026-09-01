"""Unit tests for firewall_identity (#536): the one-time visible warning when
the dedicated tappaas-fw firewall key is not provisioned.

No OPNsense connection, no filesystem key required — FIREWALL_KEY and the warn
sink are patched, so both the absent (fallback) and present paths are exercised
hermetically.
"""

from __future__ import annotations

import tempfile
import unittest
from unittest.mock import patch

from opnsense_controller import firewall_identity as fi


class FirewallKeyPresentTest(unittest.TestCase):
    def setUp(self) -> None:
        fi._warned = False  # reset the module-level once-flag between tests

    def test_absent_returns_false_and_warns_once(self) -> None:
        with patch.object(fi, "FIREWALL_KEY", "/nonexistent/tappaas-fw"), \
             patch.object(fi, "warn") as mock_warn:
            self.assertFalse(fi.firewall_key_present())
            self.assertFalse(fi.firewall_key_present())  # repeated calls...
            self.assertFalse(fi.firewall_key_present())  # ...must stay quiet
            mock_warn.assert_called_once()
            self.assertIn("#226", mock_warn.call_args.args[0])

    def test_present_returns_true_and_does_not_warn(self) -> None:
        with tempfile.NamedTemporaryFile() as f:
            with patch.object(fi, "FIREWALL_KEY", f.name), \
                 patch.object(fi, "warn") as mock_warn:
                self.assertTrue(fi.firewall_key_present())
                mock_warn.assert_not_called()


if __name__ == "__main__":
    unittest.main()
