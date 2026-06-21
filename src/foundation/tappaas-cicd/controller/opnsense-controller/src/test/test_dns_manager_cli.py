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
