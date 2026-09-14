"""Every opnsense-controller CLI takes an option only by its full name (#644).

argparse accepts any unique prefix by default, so ``--desc`` silently meant
``--description`` and an option added later could change what a typo does.
"""

import contextlib
import io
import re
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from opnsense_controller import firewall_cli
from opnsense_controller import rules_manager as rm
from opnsense_controller.cli_globals import StrictArgumentParser

PKG = Path(firewall_cli.__file__).parent
CLI_MODULES = [
    "acme_cli", "caddy_cli", "dhcp_manager_cli", "dns_manager_cli", "firewall_cli",
    "main", "nat_cli", "rules_manager", "snat_cli", "syslog_cli", "test_network_cli",
    "unbound_cli", "wg_cli", "zone_manager",
]


def _exit_code_and_stderr(fn):
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        try:
            fn()
        except SystemExit as e:
            return e.code, err.getvalue()
    return None, err.getvalue()


class TestStrictArgumentParser(unittest.TestCase):
    def _parser(self):
        p = StrictArgumentParser(prog="t")
        p.add_argument("--no-ssl-verify", action="store_true")
        sub = p.add_subparsers(dest="command")
        s = sub.add_parser("add")
        s.add_argument("--description")
        return p

    def test_full_names_and_equals_form(self):
        a = self._parser().parse_args(["--no-ssl-verify", "add", "--description=x"])
        self.assertTrue(a.no_ssl_verify)
        self.assertEqual(a.description, "x")

    def test_prefix_refused_before_the_subcommand(self):
        code, err = _exit_code_and_stderr(lambda: self._parser().parse_args(["--no-ssl", "add"]))
        self.assertEqual(code, 2)
        self.assertIn("--no-ssl", err)

    def test_prefix_refused_in_a_subcommand(self):
        code, err = _exit_code_and_stderr(lambda: self._parser().parse_args(["add", "--desc", "x"]))
        self.assertEqual(code, 2)
        self.assertIn("--desc", err)


class TestEveryCliIsStrict(unittest.TestCase):
    def test_top_level_parser_is_strict(self):
        # Subparsers inherit the top-level class; any other ArgumentParser must
        # be an add_help=False parent, which only lends its options.
        for m in CLI_MODULES:
            src = (PKG / f"{m}.py").read_text()
            with self.subTest(module=m):
                self.assertIn("StrictArgumentParser(", src)
                for call in re.findall(r"argparse\.ArgumentParser\(([^)]*)\)", src):
                    self.assertIn("add_help=False", call)

    def test_rules_manager_refuses_a_prefix(self):
        with patch.object(rm.sys, "argv", ["rules-manager", "reconcile", "--no-ssl", "homeassistant"]), \
                patch.object(rm, "_build_manager", MagicMock()), \
                patch.object(rm, "_dispatch", return_value=0):
            code, err = _exit_code_and_stderr(rm.main)
        self.assertEqual(code, 2)
        self.assertIn("--no-ssl", err)


class TestFirewallLogFlag(unittest.TestCase):
    """--log/--no-log was declared as one option string and only worked by prefix."""

    def _args(self, extra):
        captured = {}

        def fake(args):
            captured["args"] = args
            return 0

        argv = ["opnsense-firewall", "create-rule", "--description", "t", "--interface", "lan", *extra]
        with patch.object(firewall_cli.sys, "argv", argv), patch.object(firewall_cli, "cmd_create_rule", fake):
            firewall_cli.main()
        return captured["args"]

    def test_log_on_by_default(self):
        self.assertTrue(self._args([]).log)

    def test_no_log(self):
        self.assertFalse(self._args(["--no-log"]).log)

    def test_log(self):
        self.assertTrue(self._args(["--log"]).log)


if __name__ == "__main__":
    unittest.main()
