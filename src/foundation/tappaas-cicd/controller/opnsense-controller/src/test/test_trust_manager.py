"""Unit tests for trust_manager + trust_cli (ADR-043 D7).

No OPNsense connection: the oxl client's raw module router is stubbed with a
small in-memory trust store, so idempotency, in-place replacement and the
refusals are exercised without a firewall.
"""

from __future__ import annotations

import base64
import unittest
from unittest.mock import MagicMock

from opnsense_controller.trust_cli import _first_cert
from opnsense_controller.trust_manager import TrustManager, pem_fingerprint

CA = "-----BEGIN CERTIFICATE-----\nQ0E=\n-----END CERTIFICATE-----\n"
LEAF1 = "-----BEGIN CERTIFICATE-----\nTDE=\n-----END CERTIFICATE-----\n"
LEAF2 = "-----BEGIN CERTIFICATE-----\nTDI=\n-----END CERTIFICATE-----\n"
KEY = "-----BEGIN PRIVATE KEY-----\nSw==\n-----END PRIVATE KEY-----\n"


def _store_manager(caddy_rows=None):
    """A manager over an in-memory trust store; returns (manager, store, calls)."""
    store = {"ca": [], "cert": []}
    caddy = caddy_rows if caddy_rows is not None else []
    calls = []
    n = {"i": 0}

    def run_module(_module, **kwargs):
        p = kwargs["params"]
        if p.get("module") == "caddy":
            return {"result": {"response": {"rows": caddy}}}
        kind, cmd, data, up = p["controller"], p["command"], p.get("data") or {}, p.get("params")
        calls.append((kind, cmd))
        if cmd == "del":
            store[kind] = [r for r in store[kind] if r["uuid"] != up[0]]
            return {"result": {"response": {"result": "deleted"}}}
        if cmd == "search":
            return {"result": {"response": {"rows": [dict(r) for r in store[kind]]}}}
        body = data.get(kind, {})
        if cmd == "add":
            n["i"] += 1
            store[kind].append({"uuid": f"u{n['i']}", "refid": f"r{n['i']}", "descr": body["descr"], "caref": "", "crt": base64.b64encode(body["crt_payload"].encode()).decode()})
            return {"result": {"response": {"result": "saved"}}}
        if cmd == "set":
            for r in store[kind]:
                if r["uuid"] == up[0]:
                    r["crt"] = base64.b64encode(body["crt_payload"].encode()).decode()
            return {"result": {"response": {"result": "saved"}}}
        return {"result": {"response": {}}}

    mgr = TrustManager(config=MagicMock())
    mgr._client = MagicMock()  # noqa: SLF001
    mgr._client.run_module.side_effect = run_module  # noqa: SLF001
    return mgr, store, calls


class TestCa(unittest.TestCase):
    def test_import_then_present(self):
        mgr, store, calls = _store_manager()
        refid, changed = mgr.ca_ensure("TAPPaaS: x CA", CA)
        self.assertTrue(changed)
        self.assertEqual(refid, "r1")
        self.assertEqual(mgr.ca_ensure("TAPPaaS: x CA", CA), ("r1", False))
        self.assertEqual(len(store["ca"]), 1)

    def test_never_replaced_in_place(self):
        mgr, _, _ = _store_manager()
        mgr.ca_ensure("TAPPaaS: x CA", CA)
        with self.assertRaises(RuntimeError):
            mgr.ca_ensure("TAPPaaS: x CA", LEAF1)

    def test_the_key_is_never_sent(self):
        mgr, _, _ = _store_manager()
        mgr.ca_ensure("TAPPaaS: x CA", CA)
        sent = [c.kwargs["params"].get("data") for c in mgr._client.run_module.call_args_list]  # noqa: SLF001
        self.assertFalse(any("prv_payload" in (d or {}).get("ca", {}) for d in sent))


class TestCert(unittest.TestCase):
    def test_renewal_keeps_the_refid(self):
        mgr, store, calls = _store_manager()
        refid, _ = mgr.cert_ensure("TAPPaaS: wildcard mgmt", LEAF1, KEY)
        self.assertEqual(mgr.cert_ensure("TAPPaaS: wildcard mgmt", LEAF1, KEY), (refid, False))
        refid2, changed = mgr.cert_ensure("TAPPaaS: wildcard mgmt", LEAF2, KEY)
        self.assertTrue(changed)
        self.assertEqual(refid2, refid)
        self.assertIn(("cert", "set"), calls)
        self.assertEqual(len(store["cert"]), 1)
        self.assertEqual(pem_fingerprint(base64.b64decode(store["cert"][0]["crt"]).decode()), pem_fingerprint(LEAF2))

    def test_duplicates_are_refused(self):
        mgr, store, _ = _store_manager()
        mgr.cert_ensure("dup", LEAF1, KEY)
        store["cert"].append(dict(store["cert"][0], uuid="u9", refid="r9"))
        with self.assertRaises(RuntimeError):
            mgr.cert_ensure("dup", LEAF2, KEY)


class TestRetire(unittest.TestCase):
    def _seed(self, mgr, store):
        mgr.ca_ensure("TAPPaaS: old CA", CA)
        mgr.cert_ensure("TAPPaaS: old wildcard", LEAF1, KEY)
        store["cert"][0]["caref"] = store["ca"][0]["refid"]
        return store["cert"][0]["refid"]

    def test_unused_goes_with_its_ca(self):
        mgr, store, _ = _store_manager()
        refid = self._seed(mgr, store)
        self.assertEqual(mgr.cert_retire(refid), ["TAPPaaS: old wildcard", "TAPPaaS: old CA"])
        self.assertEqual((store["ca"], store["cert"]), ([], []))

    def test_a_served_certificate_stays(self):
        rows = []
        mgr, store, _ = _store_manager(rows)
        refid = self._seed(mgr, store)
        rows.append({"FromDomain": "network.lab9.example.org", "CustomCertificate": refid})
        with self.assertRaises(RuntimeError):
            mgr.cert_retire(refid)
        self.assertEqual(len(store["cert"]), 1)

    def test_not_tappaas_stays(self):
        mgr, store, _ = _store_manager()
        mgr.cert_ensure("Web GUI TLS certificate", LEAF1, KEY)
        with self.assertRaises(RuntimeError):
            mgr.cert_retire(store["cert"][0]["refid"])

    def test_a_ca_that_still_signs_stays(self):
        mgr, store, _ = _store_manager()
        refid = self._seed(mgr, store)
        mgr.cert_ensure("TAPPaaS: other", LEAF2, KEY)
        store["cert"][1]["caref"] = store["ca"][0]["refid"]
        self.assertEqual(mgr.cert_retire(refid), ["TAPPaaS: old wildcard"])
        self.assertEqual(len(store["ca"]), 1)


class TestCli(unittest.TestCase):
    def test_first_cert_of_a_chain(self):
        self.assertEqual(_first_cert(LEAF1 + CA), LEAF1)


if __name__ == "__main__":
    unittest.main()
