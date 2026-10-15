"""SSL verification: OPNSENSE_SSL_VERIFY=false reaches every CLI's Config, and
an untrusted GUI certificate names the way past it."""

import os
import ssl
import unittest
from unittest.mock import MagicMock, patch

from opnsense_controller.config import Config, probe_opnsense_port


class TestSslVerifyEnv(unittest.TestCase):
    def test_env_false_turns_verification_off(self):
        with patch.dict(os.environ, {"OPNSENSE_SSL_VERIFY": "false"}):
            self.assertFalse(Config(firewall="fw", token="t", secret="s", ssl_verify=True).ssl_verify)

    def test_unset_env_keeps_the_callers_choice(self):
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("OPNSENSE_SSL_VERIFY", None)
            self.assertTrue(Config(firewall="fw", token="t", secret="s").ssl_verify)


class TestUntrustedCertHint(unittest.TestCase):
    def test_cert_error_names_the_flag(self):
        ctx = MagicMock()
        ctx.wrap_socket.side_effect = ssl.SSLCertVerificationError("self-signed certificate")
        conn = MagicMock()
        conn.__enter__ = MagicMock(return_value=MagicMock())
        conn.__exit__ = MagicMock(return_value=False)
        with patch("opnsense_controller.config.ssl.create_default_context", return_value=ctx), \
                patch("opnsense_controller.config.socket.create_connection", return_value=conn):
            with self.assertRaises(ConnectionError) as cm:
                probe_opnsense_port("fw", ports=[443], ssl_verify=True)
        self.assertIn("--no-ssl-verify", str(cm.exception))


if __name__ == "__main__":
    unittest.main()
