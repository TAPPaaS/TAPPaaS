"""user-set-password --password-stdin: the password read once from stdin, never printed."""

import argparse
import contextlib
import io
import unittest
from unittest.mock import MagicMock, patch

from identity_controller import authentik_cli


class TestPasswordStdin(unittest.TestCase):
    def _run(self, stdin, **kw):
        mgr = MagicMock()
        args = argparse.Namespace(username="lars", password="", password_stdin=True, **kw)
        out = io.StringIO()
        with patch.object(authentik_cli.sys, "stdin", io.StringIO(stdin)), contextlib.redirect_stdout(out):
            rc = authentik_cli.cmd_user_set_password(mgr, args)
        return rc, out.getvalue(), mgr

    def test_the_first_line_is_the_password_and_is_not_printed(self):
        rc, out, mgr = self._run("s3cret-enough\nsecond line\n")
        self.assertEqual(rc, 0)
        mgr.user_set_password.assert_called_once_with("lars", "s3cret-enough")
        self.assertNotIn("s3cret-enough", out)
        self.assertNotIn("generated", out)

    def test_an_empty_stdin_is_refused(self):
        rc, _, mgr = self._run("")
        self.assertEqual(rc, 2)
        mgr.user_set_password.assert_not_called()

    def test_without_the_flag_a_password_is_generated_and_printed(self):
        mgr = MagicMock()
        args = argparse.Namespace(username="lars", password="", password_stdin=False)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(authentik_cli.cmd_user_set_password(mgr, args), 0)
        self.assertIn("generated password:", out.getvalue())


if __name__ == "__main__":
    unittest.main()
