"""authentik-manager takes an option only by its full name (#644)."""

import contextlib
import io
import unittest
from unittest.mock import MagicMock, patch

from identity_controller import authentik_cli as cli


class TestFullOptionNames(unittest.TestCase):
    def test_prefix_is_refused(self):
        err = io.StringIO()
        with patch.object(cli, "_make_manager", MagicMock()) as mk, contextlib.redirect_stderr(err), \
                self.assertRaises(SystemExit) as cm:
            cli.main(["--no-tls", "test"])
        self.assertEqual(cm.exception.code, 2)
        self.assertIn("--no-tls", err.getvalue())
        mk.assert_not_called()

    def test_full_name_is_accepted(self):
        with patch.object(cli, "_make_manager", MagicMock()) as mk, contextlib.redirect_stdout(io.StringIO()):
            cli.main(["--no-tls-verify", "test"])
        mk.assert_called_once()


if __name__ == "__main__":
    unittest.main()
