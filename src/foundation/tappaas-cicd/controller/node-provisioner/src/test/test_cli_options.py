"""node-provisioner takes an option only by its full name (#644)."""

import contextlib
import io
import unittest
from unittest.mock import MagicMock, patch

from node_provisioner import cli


class TestFullOptionNames(unittest.TestCase):
    def _run(self, argv):
        register = MagicMock(return_value=True)
        err = io.StringIO()
        with patch.object(cli.sys, "argv", ["node-provisioner", *argv]), \
                patch.object(cli, "cmd_register", register), contextlib.redirect_stderr(err), \
                self.assertRaises(SystemExit) as cm:
            cli.main()
        return cm.exception.code, err.getvalue(), register

    def test_prefix_is_refused(self):
        code, err, register = self._run(["register", "tappaas9", "--boot", "/dev/sda"])
        self.assertEqual(code, 2)
        self.assertIn("--boot", err)
        register.assert_not_called()

    def test_full_name_is_accepted(self):
        code, _, register = self._run(["register", "tappaas9", "--boot-disk", "/dev/sda"])
        self.assertEqual(code, 0)
        register.assert_called_once()


if __name__ == "__main__":
    unittest.main()
