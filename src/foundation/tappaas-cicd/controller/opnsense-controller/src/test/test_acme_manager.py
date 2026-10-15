"""Unit tests for acme_manager + acme_cli (issue #254).

No OPNsense connection: stubs the oxl Client's raw module router so the
provider-agnostic API path, idempotency and the CLI's pure helpers can be
exercised without a firewall.
"""

from __future__ import annotations

import io
import unittest
from unittest.mock import MagicMock, patch

from opnsense_controller.acme_cli import (
    _parse_fields,
    _read_stdin_fields,
    _resolve_provider,
    PROVIDER_ALIASES,
)
from opnsense_controller.acme_manager import (
    AcmeAccount,
    AcmeAction,
    AcmeCertificate,
    AcmeManager,
    AcmeValidation,
    PluginDisabledError,
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


class TestStdinProviderFields(unittest.TestCase):
    """Credentials arrive on stdin so they stay out of /proc/<pid>/cmdline."""

    @staticmethod
    def _read(text: str) -> list[str]:
        with patch("sys.stdin", io.StringIO(text)):
            return _read_stdin_fields()

    def test_reads_one_field_per_line(self):
        self.assertEqual(
            self._read("dns_cf_token=abc\ndns_cf_account_id=def\n"),
            ["dns_cf_token=abc", "dns_cf_account_id=def"],
        )

    def test_skips_blank_and_comment_lines(self):
        self.assertEqual(
            self._read("# provider creds\n\n  \ndns_cf_token=abc\n"),
            ["dns_cf_token=abc"],
        )

    def test_inline_hash_is_kept(self):
        # '#' is legal inside a secret; treating it as a comment would silently
        # truncate the credential and produce a baffling auth failure.
        self.assertEqual(
            self._read("dns_azuredns_clientsecret=ZVq8Q~w#0r6IO\n"),
            ["dns_azuredns_clientsecret=ZVq8Q~w#0r6IO"],
        )

    def test_empty_stdin_yields_nothing(self):
        self.assertEqual(self._read(""), [])

    def test_round_trips_through_parse_fields(self):
        parsed = _parse_fields(self._read("dns_cf_token=AAA=BBB=\n"))
        self.assertEqual(parsed, {"dns_cf_token": "AAA=BBB="})


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

    def test_default_dns_sleep_matches_wrapper(self):
        # Regression for #328: os-acme-client defaults dns_sleep to 0, firing LE
        # validation before the TXT propagates. Our default must be > 0 — and
        # aligned with acme-setup.sh's 150 (#539/#541), since 45 proved too short
        # for LE multi-perspective validation and cron renewals reuse this value.
        mgr = _make_manager({
            ("Validations", "search"): {"rows": []},
            ("Validations", "add"): {"uuid": "V3"},
        })
        mgr.validation_ensure(AcmeValidation(name="d", dns_service="dns_desec"))
        body = next(c["data"] for c in mgr.client.calls if c["command"] == "add")["validation"]
        self.assertEqual(body["dns_sleep"], "150")

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


class TestCertificateWaitFreshnessGate(unittest.TestCase):
    """A non-200 status only fails the wait when it post-dates the sign (#540)."""

    def _mgr(self, status_code: str, status_last_update: str):
        return _make_manager({
            ("Certificates", "get"): {"certificate": {
                "name": "*.example.org", "statusCode": status_code,
                "certRefId": "", "lastUpdate": "",
                "statusLastUpdate": status_last_update,
                "account": {}, "validationMethod": {},
            }},
        })

    def test_stale_error_is_ignored_and_times_out(self):
        # statusLastUpdate == the pre-sign baseline → previous attempt's residue.
        # acme.sh is still in dns_sleep, so we must not report a failure; the wait
        # should keep polling and ultimately time out rather than false-fail.
        mgr = self._mgr("400", "1000")
        with self.assertRaises(TimeoutError):
            mgr.certificate_wait(
                "anything", timeout=1, poll_interval=0, prior_status_update=1000,
            )

    def test_fresh_error_raises(self):
        # statusLastUpdate newer than the baseline → this run genuinely failed.
        mgr = self._mgr("400", "2000")
        with self.assertRaises(RuntimeError):
            mgr.certificate_wait(
                "anything", timeout=1, poll_interval=0, prior_status_update=1000,
            )

    def test_missing_timestamp_does_not_false_fail(self):
        # An OPNsense build that omits statusLastUpdate parses to 0; with a 0
        # baseline the gate can't date the error, so it times out (recoverable)
        # rather than abandoning a possibly-good issuance.
        mgr = self._mgr("400", "")
        with self.assertRaises(TimeoutError):
            mgr.certificate_wait(
                "anything", timeout=1, poll_interval=0, prior_status_update=0,
            )


class TestCertificateWaitSuccessFreshnessGate(unittest.TestCase):
    """A 200 counts as this run's success only when it post-dates the sign (#548)."""

    def _mgr(self, status_last_update: str):
        return _make_manager({
            ("Certificates", "get"): {"certificate": {
                "name": "*.example.org", "statusCode": "200",
                "certRefId": "REF123", "lastUpdate": "",
                "statusLastUpdate": status_last_update,
                "account": {}, "validationMethod": {},
            }},
        })

    def test_stale_200_is_not_taken_as_this_runs_success(self):
        # statusLastUpdate == the pre-sign baseline → the previous issuance's
        # 200, while this sign is still in dns_sleep. Returning it would report
        # "done" in <1s with a stale cert; the wait must keep polling → timeout.
        mgr = self._mgr("1000")
        with self.assertRaises(TimeoutError):
            mgr.certificate_wait(
                "anything", timeout=1, poll_interval=0, prior_status_update=1000,
            )

    def test_fresh_200_returns_success(self):
        # statusLastUpdate newer than the baseline → this run's issuance.
        mgr = self._mgr("2000")
        info = mgr.certificate_wait(
            "anything", timeout=1, poll_interval=0, prior_status_update=1000,
        )
        self.assertEqual(info.status_code, 200)
        self.assertEqual(info.cert_refid, "REF123")

    def test_gate_disabled_returns_any_200(self):
        # prior_status_update=None (legacy callers) → any 200 returns at once.
        mgr = self._mgr("1000")
        info = mgr.certificate_wait("anything", timeout=1, poll_interval=0)
        self.assertEqual(info.cert_refid, "REF123")


class TestRenewalCron(unittest.TestCase):
    """setup wires the os-acme-client auto-renewal cron via fetchCronIntegration (#547)."""

    def test_ensure_renewal_cron_calls_fetch_integration(self):
        mgr = _make_manager({
            ("Settings", "get"): {"acmeclient": {"settings": {"autoRenewal": "1"}}},
            ("Settings", "fetchCronIntegration"): {"result": "new", "uuid": "CRON1"},
        })
        res = mgr.ensure_renewal_cron()
        self.assertEqual(res.get("result"), "new")
        cmds = [c["command"] for c in mgr.client.calls]
        self.assertIn("fetchCronIntegration", cmds)
        # autoRenewal already 1 → no needless settings/set write.
        self.assertNotIn("set", cmds)

    def test_ensure_renewal_cron_sets_autorenewal_when_off(self):
        mgr = _make_manager({
            ("Settings", "get"): {"acmeclient": {"settings": {"autoRenewal": "0"}}},
            ("Settings", "fetchCronIntegration"): {"result": "new"},
        })
        mgr.ensure_renewal_cron()
        set_call = next((c for c in mgr.client.calls if c["command"] == "set"), None)
        self.assertIsNotNone(set_call)
        self.assertEqual(set_call["data"]["acmeclient"]["settings"]["autoRenewal"], "1")

    def test_ensure_cron_cmd_without_certificates_does_nothing(self):
        from opnsense_controller.acme_cli import cmd_ensure_cron  # noqa: PLC0415
        mgr = MagicMock()
        mgr._api_get.return_value = {"rows": []}  # noqa: SLF001
        with patch("sys.stdout", new_callable=io.StringIO):
            self.assertEqual(cmd_ensure_cron(mgr, MagicMock()), 0)
        mgr.ensure_renewal_cron.assert_not_called()

    def test_ensure_cron_cmd_wires_and_reports(self):
        from opnsense_controller.acme_cli import cmd_ensure_cron  # noqa: PLC0415
        mgr = MagicMock()
        mgr._api_get.return_value = {"rows": [{"uuid": "c1"}]}  # noqa: SLF001
        mgr.ensure_renewal_cron.return_value = {"result": "new"}
        mgr.renewal_cron_uuid.return_value = "CRON1"
        with patch("sys.stdout", new_callable=io.StringIO) as out:
            self.assertEqual(cmd_ensure_cron(mgr, MagicMock()), 0)
        self.assertIn("created", out.getvalue())
        mgr.renewal_cron_uuid.return_value = ""
        with patch("sys.stderr", new_callable=io.StringIO):
            self.assertEqual(cmd_ensure_cron(mgr, MagicMock()), 1)

    def test_renewal_cron_uuid_reads_selected(self):
        mgr = _make_manager({
            ("Settings", "get"): {"acmeclient": {"settings": {"UpdateCron": {
                "": {"value": "None", "selected": 0},
                "CRONUUID": {"value": "AcmeClient renewal", "selected": 1},
            }}}},
        })
        self.assertEqual(mgr.renewal_cron_uuid(), "CRONUUID")

    def test_renewal_cron_uuid_empty_when_only_none(self):
        # The #547 symptom: UpdateCron offers only the "None" option, selected.
        mgr = _make_manager({
            ("Settings", "get"): {"acmeclient": {"settings": {"UpdateCron": {
                "": {"value": "None", "selected": 1},
            }}}},
        })
        self.assertEqual(mgr.renewal_cron_uuid(), "")


class TestCertNotAfter(unittest.TestCase):
    """Expiry comes from the Trust store, not the acme statusCode (#548)."""

    def test_reads_valid_to_for_matching_refid(self):
        mgr = _make_manager({
            ("cert", "search"): {"rows": [
                {"refid": "OTHER", "valid_to": "111"},
                {"refid": "REF123", "valid_to": "1888888888"},
            ]},
        })
        self.assertEqual(mgr.cert_not_after("REF123"), 1888888888)

    def test_unknown_refid_returns_zero(self):
        mgr = _make_manager({("cert", "search"): {"rows": []}})
        self.assertEqual(mgr.cert_not_after("NOPE"), 0)

    def test_empty_refid_short_circuits(self):
        mgr = _make_manager({})
        self.assertEqual(mgr.cert_not_after(""), 0)
        self.assertEqual(mgr.client.calls, [])


class TestCertificateDelete(unittest.TestCase):
    """#790: the request and its Trust certificate go; nothing shared does."""

    ROUTES = {
        ("Certificates", "search"): {"rows": [
            {"uuid": "c-other", "name": "*.other.example"},
            {"uuid": "c-1", "name": "*.tenant1.example"},
        ]},
        ("Certificates", "get"): {"certificate": {"name": "*.tenant1.example", "certRefId": "REF1"}},
        ("cert", "search"): {"rows": [{"uuid": "t-1", "refid": "REF1"}, {"uuid": "t-2", "refid": "REF2"}]},
        ("Certificates", "del"): {"result": "deleted"},
        ("cert", "del"): {"result": "deleted"},
    }

    def _deletes(self, mgr):
        return [(c["controller"], c["url_params"]) for c in mgr.client.calls if c["command"] == "del"]

    def test_deletes_request_then_trust_cert(self):
        mgr = _make_manager(dict(self.ROUTES))
        res = mgr.certificate_delete("*.tenant1.example")
        self.assertEqual(res, {"certificate": "c-1", "trust": "t-1", "refid": "REF1"})
        self.assertEqual(self._deletes(mgr), [("Certificates", ["c-1"]), ("cert", ["t-1"])])

    def test_touches_nothing_shared(self):
        mgr = _make_manager(dict(self.ROUTES))
        mgr.certificate_delete("*.tenant1.example")
        touched = {c["controller"] for c in mgr.client.calls if c["action"] == "post"}
        self.assertNotIn("Accounts", touched)
        self.assertNotIn("Validations", touched)
        self.assertNotIn("Actions", touched)

    def test_dry_run_deletes_nothing(self):
        mgr = _make_manager(dict(self.ROUTES))
        res = mgr.certificate_delete("*.tenant1.example", dry_run=True)
        self.assertEqual(res["certificate"], "c-1")
        self.assertEqual(self._deletes(mgr), [])

    def test_unknown_name_is_a_noop(self):
        mgr = _make_manager(dict(self.ROUTES))
        res = mgr.certificate_delete("*.nobody.example")
        self.assertEqual(res, {"certificate": None, "trust": None, "refid": ""})
        self.assertEqual(self._deletes(mgr), [])

    def test_trust_cert_in_use_is_an_error(self):
        routes = dict(self.ROUTES)
        routes[("cert", "del")] = {"result": "failed", "message": "in use"}
        mgr = _make_manager(routes)
        with self.assertRaises(RuntimeError):
            mgr.certificate_delete("*.tenant1.example")


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


class TestEnsurePluginEnabled(unittest.TestCase):
    """ensure_plugin_enabled self-heals a plugin that shipped disabled (#475)."""

    def test_noop_when_already_enabled(self):
        mgr = _make_manager({
            ("Settings", "get"): {"acmeclient": {"settings": {"enabled": "1"}}},
        })
        self.assertFalse(mgr.ensure_plugin_enabled())
        # No write when already enabled.
        self.assertFalse(any(c["command"] == "set" for c in mgr.client.calls))

    def test_enables_when_disabled(self):
        mgr = _make_manager({
            ("Settings", "set"): {"result": "saved"},
            ("Service", "reconfigure"): {"status": "ok"},
        })
        # get: disabled first (pre-check), enabled after the write (verify).
        mgr.is_plugin_enabled = MagicMock(side_effect=[False, True])  # noqa: SLF001
        self.assertTrue(mgr.ensure_plugin_enabled())
        # Payload must be nested under the model root, not flat.
        set_call = next(c for c in mgr.client.calls if c["command"] == "set")
        self.assertEqual(set_call["data"], {"acmeclient": {"settings": {"enabled": "1"}}})
        # And the change is applied.
        self.assertTrue(any(c["command"] == "reconfigure" for c in mgr.client.calls))

    def test_raises_when_enable_does_not_take(self):
        mgr = _make_manager({
            ("Settings", "set"): {"result": "saved"},
            ("Service", "reconfigure"): {"status": "ok"},
        })
        # Still disabled after the write attempt.
        mgr.is_plugin_enabled = MagicMock(side_effect=[False, False])  # noqa: SLF001
        with self.assertRaises(PluginDisabledError):
            mgr.ensure_plugin_enabled()


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
