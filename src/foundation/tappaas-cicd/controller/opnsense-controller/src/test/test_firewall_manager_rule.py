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


class CreateRuleInvertTest(unittest.TestCase):
    """The module's names are source_invert/destination_invert. It refused
    OPNsense's field name `source_not` — the first inverted rule (#159) failed
    on every zone, live on hrossen 2026-10-02."""

    def _params(self, **kw) -> dict:
        fm, client = _manager_with_mock_client()
        fm.create_rule(FirewallRule(description="d", interface="opt1", **kw), apply=False)
        return client.run_module.call_args.kwargs["params"]

    def test_source_invert_uses_the_module_name(self):
        p = self._params(source_net="10.2.0.0/24", source_invert=True)
        self.assertIs(p.get("source_invert"), True)
        self.assertNotIn("source_not", p)

    def test_destination_invert_uses_the_module_name(self):
        p = self._params(destination_net="10.2.0.0/24", destination_invert=True)
        self.assertIs(p.get("destination_invert"), True)
        self.assertNotIn("destination_not", p)

    def test_no_invert_sends_neither(self):
        p = self._params()
        self.assertNotIn("source_invert", p)
        self.assertNotIn("destination_invert", p)


if __name__ == "__main__":
    unittest.main()
