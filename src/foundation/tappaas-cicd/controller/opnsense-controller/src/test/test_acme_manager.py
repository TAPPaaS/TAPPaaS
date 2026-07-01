"""Unit tests for acme_manager + acme_cli (issue #254).

No OPNsense connection: stubs the oxl Client's raw module router so the
provider-agnostic API path, idempotency and the CLI's pure helpers can be
exercised without a firewall.
"""

from __future__ import annotations

import unittest
from unittest.mock import MagicMock

from opnsense_controller.acme_cli import _parse_fields, _resolve_provider, PROVIDER_ALIASES
from opnsense_controller.acme_manager import (
    AcmeAccount,
    AcmeAction,
    AcmeCertificate,
    AcmeManager,
    AcmeValidation,
)


def _make_manager(routes: dict) -> AcmeManager:
    """Return a manager whose oxl client returns `routes[(controller, command)]`.

    Each route value is the dict returned as ``result.response``. Unmatched calls
    fall through to ``{}``.
    """
    mgr = AcmeManager(config=MagicMock())
    mgr._client = MagicMock()  # noqa: SLF001

    calls = []

    def run_module(_module, **kwargs):
        params = kwargs.get("params", {})
        ctrl = params.get("controller")
        cmd = params.get("command")
        calls.append({
            "controller": ctrl, "command": cmd,
            "data": params.get("data"),
            "url_params": params.get("params"),
            "action": params.get("action"),
        })
        return {"result": {"response": routes.get((ctrl, cmd), {})}}

    mgr._client.run_module.side_effect = run_module  # noqa: SLF001
    mgr._client.calls = calls  # noqa: SLF001
    return mgr


# ─────────────────────────────────────────────────────────────────────────────
# CLI pure helpers
# ─────────────────────────────────────────────────────────────────────────────


class TestProviderAlias(unittest.TestCase):
    def test_friendly_aliases_resolve(self):
        for friendly, expected in PROVIDER_ALIASES.items():
            self.assertEqual(_resolve_provider(friendly), expected)

    def test_passes_through_dns_prefix_unchanged(self):
        # An unlisted provider can be invoked with its raw os-acme-client key.
        self.assertEqual(_resolve_provider("dns_truenas"), "dns_truenas")

    def test_unknown_alias_errors(self):
        with self.assertRaises(SystemExit):
            _resolve_provider("madeup")


class TestProviderFields(unittest.TestCase):
    def test_parses_multiple_fields(self):
        out = _parse_fields(["dns_cf_token=abc", "dns_cf_account_id=def"])
        self.assertEqual(out, {"dns_cf_token": "abc", "dns_cf_account_id": "def"})

    def test_value_can_contain_equals(self):
        # token-style values often contain '=' padding; only split on the first '='.
        out = _parse_fields(["dns_cf_token=AAA=BBB="])
        self.assertEqual(out, {"dns_cf_token": "AAA=BBB="})

    def test_malformed_errors(self):
        with self.assertRaises(SystemExit):
            _parse_fields(["just-a-key"])


# ─────────────────────────────────────────────────────────────────────────────
# Manager — provider-agnostic API path
# ─────────────────────────────────────────────────────────────────────────────


class TestAccountEnsureIsIdempotent(unittest.TestCase):
    def test_creates_when_absent_and_registers(self):
        mgr = _make_manager({
            ("Accounts", "search"): {"rows": []},  # no existing
            ("Accounts", "add"): {"uuid": "U1"},
            ("Accounts", "register"): {"response": "OK\n\n"},
        })
        uuid = mgr.account_ensure(AcmeAccount(name="le", email="x@y", ca="letsencrypt"))
        self.assertEqual(uuid, "U1")
        verbs = [(c["controller"], c["command"]) for c in mgr.client.calls]
        self.assertIn(("Accounts", "add"), verbs)
        self.assertIn(("Accounts", "register"), verbs)  # always registers

    def test_updates_when_present_and_re_registers(self):
        mgr = _make_manager({
            ("Accounts", "search"): {"rows": [{"uuid": "U9", "name": "le"}]},
            ("Accounts", "update"): {"result": "saved"},
            ("Accounts", "register"): {"response": "OK\n\n"},
        })
        uuid = mgr.account_ensure(AcmeAccount(name="le", email="x@y", ca="letsencrypt"))
        self.assertEqual(uuid, "U9")
        verbs = [(c["controller"], c["command"]) for c in mgr.client.calls]
        self.assertNotIn(("Accounts", "add"), verbs)
        self.assertIn(("Accounts", "update"), verbs)
        self.assertIn(("Accounts", "register"), verbs)


class TestValidationCarriesProviderFields(unittest.TestCase):
    def test_cloudflare_field_lands_in_body(self):
        mgr = _make_manager({
            ("Validations", "search"): {"rows": []},
            ("Validations", "add"): {"uuid": "V1"},
        })
        mgr.validation_ensure(AcmeValidation(
            name="cf", dns_service="dns_cf",
            provider_params={"dns_cf_token": "TOKEN"},
        ))
        body = next(c["data"] for c in mgr.client.calls if c["command"] == "add")
        self.assertEqual(body["validation"]["dns_service"], "dns_cf")
        self.assertEqual(body["validation"]["dns_cf_token"], "TOKEN")
        self.assertEqual(body["validation"]["method"], "dns01")

    def test_works_for_any_provider_with_arbitrary_fields(self):
        # Manager is provider-agnostic — accepts any dns_<provider>_<field> pair.
        mgr = _make_manager({
            ("Validations", "search"): {"rows": []},
            ("Validations", "add"): {"uuid": "V2"},
        })
        mgr.validation_ensure(AcmeValidation(
            name="hetzner", dns_service="dns_hetzner",
            provider_params={"dns_hetzner_token": "HT"},
        ))
        body = next(c["data"] for c in mgr.client.calls if c["command"] == "add")
        self.assertEqual(body["validation"]["dns_hetzner_token"], "HT")

    def test_default_dns_sleep_is_nonzero(self):
        # Regression for #328: os-acme-client defaults dns_sleep to 0, firing LE
        # validation before the TXT propagates. Our default must be > 0.
        mgr = _make_manager({
            ("Validations", "search"): {"rows": []},
            ("Validations", "add"): {"uuid": "V3"},
        })
        mgr.validation_ensure(AcmeValidation(name="d", dns_service="dns_desec"))
        body = next(c["data"] for c in mgr.client.calls if c["command"] == "add")["validation"]
        self.assertEqual(body["dns_sleep"], "45")

    def test_dns_sleep_override_lands_in_body(self):
        mgr = _make_manager({
            ("Validations", "search"): {"rows": []},
            ("Validations", "add"): {"uuid": "V4"},
        })
        mgr.validation_ensure(AcmeValidation(
            name="d", dns_service="dns_desec", dns_sleep=90,
        ))
        body = next(c["data"] for c in mgr.client.calls if c["command"] == "add")["validation"]
        self.assertEqual(body["dns_sleep"], "90")


class TestCertificateEnsure(unittest.TestCase):
    def test_creates_with_alt_names_and_restart_action(self):
        mgr = _make_manager({
            ("Certificates", "search"): {"rows": []},
            ("Certificates", "add"): {"uuid": "C1"},
        })
        uuid = mgr.certificate_ensure(AcmeCertificate(
            name="*.example.org",
            account_uuid="A1",
            validation_uuid="V1",
            restart_action_uuid="X1",
            alt_names=["example.org"],
        ))
        self.assertEqual(uuid, "C1")
        body = next(c["data"] for c in mgr.client.calls if c["command"] == "add")["certificate"]
        self.assertEqual(body["name"], "*.example.org")
        self.assertEqual(body["account"], "A1")
        self.assertEqual(body["validationMethod"], "V1")
        self.assertEqual(body["restartActions"], "X1")
        self.assertEqual(body["altNames"], "example.org")


class TestCertificateWaitParsesSelectField(unittest.TestCase):
    def test_status_200_returns_refid(self):
        # The /get endpoint returns selection dicts for account / validationMethod
        # which the manager flattens. Make sure parsing handles both shapes.
        mgr = _make_manager({
            ("Certificates", "get"): {"certificate": {
                "name": "*.example.org",
                "statusCode": "200",
                "certRefId": "REF123",
                "lastUpdate": "1779999999",
                "account": {"A1": {"value": "A1", "selected": 1}, "A2": {"value": "A2", "selected": 0}},
                "validationMethod": {"V1": {"value": "V1", "selected": 1}},
            }},
        })
        info = mgr.certificate_get("anything")
        self.assertEqual(info.status_code, 200)
        self.assertEqual(info.cert_refid, "REF123")
        self.assertEqual(info.account_uuid, "A1")
        self.assertEqual(info.validation_uuid, "V1")

    def test_error_status_raises(self):
        mgr = _make_manager({
            ("Certificates", "get"): {"certificate": {
                "name": "*.example.org", "statusCode": "500",
                "certRefId": "", "lastUpdate": "",
                "account": {}, "validationMethod": {},
            }},
        })
        with self.assertRaises(RuntimeError):
            mgr.certificate_wait("anything", timeout=1, poll_interval=0)


class TestPluginEnabled(unittest.TestCase):
    """settings/get wraps the payload in the model root ("acmeclient")."""

    def test_enabled_when_root_wrapped(self):
        mgr = _make_manager({
            ("Settings", "get"): {"acmeclient": {"settings": {"enabled": "1"}}},
        })
        self.assertTrue(mgr.is_plugin_enabled())

    def test_disabled_when_root_wrapped(self):
        mgr = _make_manager({
            ("Settings", "get"): {"acmeclient": {"settings": {"enabled": "0"}}},
        })
        self.assertFalse(mgr.is_plugin_enabled())

    def test_tolerates_unwrapped_shape(self):
        # Be robust if a future OPNsense build returns the model unwrapped.
        mgr = _make_manager({
            ("Settings", "get"): {"settings": {"enabled": "1"}},
        })
        self.assertTrue(mgr.is_plugin_enabled())


class TestActionEnsure(unittest.TestCase):
    def test_caddy_reload_action_body(self):
        mgr = _make_manager({
            ("Actions", "search"): {"rows": []},
            ("Actions", "add"): {"uuid": "ACT"},
        })
        uuid = mgr.action_ensure(AcmeAction(name="caddy-reload"))
        self.assertEqual(uuid, "ACT")
        body = next(c["data"] for c in mgr.client.calls if c["command"] == "add")["action"]
        self.assertEqual(body["type"], "configd_reload_caddy")
        self.assertEqual(body["name"], "caddy-reload")


if __name__ == "__main__":
    unittest.main()
