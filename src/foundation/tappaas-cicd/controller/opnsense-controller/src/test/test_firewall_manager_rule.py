"""Unit tests for FirewallManager.create_rule's parameters.

The rule module stores `interface` as a list and diffs against it. Sent as a
string, "opt1" never equalled ["opt1"], so every reconcile rewrote every module
rule and reported applied=1 forever. No OPNsense connection: the client is a mock.
"""

from __future__ import annotations

import unittest
from unittest.mock import MagicMock

from opnsense_controller.firewall_manager import FirewallManager, FirewallRule


def _manager_with_mock_client() -> tuple[FirewallManager, MagicMock]:
    fm = FirewallManager.__new__(FirewallManager)
    client = MagicMock()
    client.run_module.return_value = {"result": {"changed": False}}
    fm._client = client
    return fm, client


class CreateRuleInterfaceTest(unittest.TestCase):
    def _interface_sent(self, interface) -> object:
        fm, client = _manager_with_mock_client()
        fm.create_rule(FirewallRule(description="d", interface=interface), apply=False)
        return client.run_module.call_args.kwargs["params"]["interface"]

    def test_single_interface_is_sent_as_a_list(self):
        self.assertEqual(self._interface_sent("opt1"), ["opt1"])

    def test_interface_list_is_sent_as_a_list(self):
        self.assertEqual(self._interface_sent(["opt1", "opt2"]), ["opt1", "opt2"])


if __name__ == "__main__":
    unittest.main()
