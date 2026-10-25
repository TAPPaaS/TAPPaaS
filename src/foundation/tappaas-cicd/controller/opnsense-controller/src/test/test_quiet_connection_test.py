"""The OPNsense client's connection test prints OK; a controller run must not.

oxl_opnsense_client's Client.test() prints "OK" or "UNREACHABLE" to stdout, and
every manager calls it first, so each caddy-manager / opnsense-firewall call
began with a bare "OK" line in the output of the scripts that use them.
"""

from __future__ import annotations

import contextlib
import io
import os
import unittest
from unittest.mock import patch

from opnsense_controller.log import quiet


class _PrintingClient:
    def __init__(self, reachable: bool) -> None:
        self.reachable = reachable

    def test(self) -> bool:
        print("OK" if self.reachable else "UNREACHABLE")
        return self.reachable


class QuietTest(unittest.TestCase):
    def run_quiet(self, fn):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            result = quiet(fn)
        return result, out.getvalue()

    def test_result_is_kept_and_nothing_printed(self):
        for reachable in (True, False):
            with patch.dict(os.environ, {"TAPPAAS_DEBUG": "0"}):
                result, printed = self.run_quiet(_PrintingClient(reachable).test)
            self.assertIs(result, reachable)
            self.assertEqual(printed, "")

    def test_what_it_said_is_there_for_debug(self):
        with patch.dict(os.environ, {"TAPPAAS_DEBUG": "1"}):
            _, printed = self.run_quiet(_PrintingClient(False).test)
        self.assertIn("[Debug]", printed)
        self.assertIn("UNREACHABLE", printed)

    def test_every_manager_uses_it(self):
        here = os.path.join(os.path.dirname(__file__), "..", "opnsense_controller")
        for name in sorted(os.listdir(here)):
            if not name.endswith(".py"):
                continue
            with open(os.path.join(here, name), encoding="utf8") as f:
                text = f.read()
            self.assertNotIn("return self.client.test()", text,
                             f"{name} calls the client's test() bare: use quiet(self.client.test)")


if __name__ == "__main__":
    unittest.main()
