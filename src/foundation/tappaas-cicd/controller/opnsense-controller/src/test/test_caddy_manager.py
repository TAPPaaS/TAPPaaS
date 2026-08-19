"""Unit tests for caddy_manager — focused on the issue #254 CustomCertificate path.

The TAPPaaS proxy:install/update-service.sh reads ``tappaas.tlsCertRefid`` from
configuration.json and passes it to ``caddy-manager add-domain
--custom-certificate <refid>``, which must land on the OPNsense reverseproxy
entry's ``CustomCertificate`` field so Caddy serves the wildcard cert from
OPNsense Trust instead of fetching its own.
"""

from __future__ import annotations

import unittest
from unittest.mock import MagicMock

from opnsense_controller.caddy_manager import CaddyDomain, CaddyManager


def _make_manager(captured: list) -> CaddyManager:
    mgr = CaddyManager(config=MagicMock())
    mgr._client = MagicMock()  # noqa: SLF001

    def run_module(_module, **kwargs):
        params = kwargs.get("params", {})
        captured.append({
            "controller": params.get("controller"),
            "command": params.get("command"),
            "data": params.get("data"),
            "url_params": params.get("params"),
        })
        return {"result": {"response": {"uuid": "REVUUID"}}}

    mgr._client.run_module.side_effect = run_module  # noqa: SLF001
    return mgr


class TestAddDomainCustomCertificate(unittest.TestCase):
    def test_custom_certificate_lands_on_body(self):
        captured: list = []
        mgr = _make_manager(captured)
        mgr.add_domain(CaddyDomain(
            domain="tenant1.test2.tapaas.org",
            description="PoC",
            custom_certificate="REFID123",
        ))
        body = captured[-1]["data"]
        self.assertEqual(captured[-1]["controller"], "ReverseProxy")
        self.assertEqual(captured[-1]["command"], "addReverseProxy")
        self.assertEqual(body["reverse"]["FromDomain"], "tenant1.test2.tapaas.org")
        self.assertEqual(body["reverse"]["CustomCertificate"], "REFID123")
        # http-01 path: when no refid is set, CustomCertificate is empty so
        # Caddy keeps auto-fetching via its built-in ACME.

    def test_empty_custom_certificate_means_caddy_acme(self):
        captured: list = []
        mgr = _make_manager(captured)
        mgr.add_domain(CaddyDomain(domain="public.example.org"))  # http01 path
        body = captured[-1]["data"]
        self.assertEqual(body["reverse"]["CustomCertificate"], "")

    def test_update_domain_propagates_custom_certificate(self):
        captured: list = []
        mgr = _make_manager(captured)
        mgr.update_domain("U1", CaddyDomain(
            domain="tenant1.test2.tapaas.org",
            custom_certificate="NEWREFID",
        ))
        self.assertEqual(captured[-1]["command"], "setReverseProxy")
        self.assertEqual(captured[-1]["url_params"], ["U1"])
        self.assertEqual(captured[-1]["data"]["reverse"]["CustomCertificate"], "NEWREFID")


class TestAddHandlerForwardAuth(unittest.TestCase):
    """The forward_auth flag must land on the handle body as ForwardAuth (issue #45)."""

    def test_forward_auth_true_lands_on_body(self):
        captured: list = []
        mgr = _make_manager(captured)
        from opnsense_controller.caddy_manager import CaddyHandler  # noqa: PLC0415
        mgr.add_handler(CaddyHandler(
            domain_uuid="DOMAIN-UUID",
            upstream_domain="openwebui.srvWork.internal",
            upstream_port="8080",
            description="TAPPaaS: openwebui",
            forward_auth=True,
        ))
        body = captured[-1]["data"]["handle"]
        self.assertEqual(body["ForwardAuth"], "1")
        self.assertEqual(captured[-1]["command"], "addHandle")

    def test_forward_auth_default_off(self):
        captured: list = []
        mgr = _make_manager(captured)
        from opnsense_controller.caddy_manager import CaddyHandler  # noqa: PLC0415
        mgr.add_handler(CaddyHandler(
            domain_uuid="D",
            upstream_domain="x", upstream_port="80",
            description="Plain handler",
        ))
        self.assertEqual(captured[-1]["data"]["handle"]["ForwardAuth"], "0")


class TestPruneDomainsByDescription(unittest.TestCase):
    """Stale <svc>.<olddomain> cleanup on a domain change (#474)."""

    def _mgr(self, domains, handlers):
        from opnsense_controller.caddy_manager import (  # noqa: PLC0415
            CaddyDomainInfo,
            CaddyHandlerInfo,
        )
        mgr = CaddyManager(config=MagicMock())
        mgr._client = MagicMock()  # noqa: SLF001
        mgr.list_domains = MagicMock(  # noqa: SLF001
            return_value=[CaddyDomainInfo(*d) for d in domains]
        )
        mgr.list_handlers = MagicMock(  # noqa: SLF001
            return_value=[CaddyHandlerInfo(**h) for h in handlers]
        )
        mgr.delete_domain = MagicMock(return_value={"result": "deleted"})  # noqa: SLF001
        mgr.delete_handler = MagicMock(return_value={"result": "deleted"})  # noqa: SLF001
        return mgr

    def _handler(self, uuid, domain_uuid, description):
        return dict(
            uuid=uuid, domain_uuid=domain_uuid, upstream_domain="u",
            upstream_port="80", description=description, enabled=True,
        )

    def test_removes_only_stale_same_description(self):
        mgr = self._mgr(
            domains=[
                ("OLD", "app.old.example", "TAPPaaS: app", True),
                ("NEW", "app.new.example", "TAPPaaS: app", True),
                ("OTH", "other.new.example", "TAPPaaS: other", True),
            ],
            handlers=[
                self._handler("HOLD", "OLD", "TAPPaaS: app"),
                self._handler("HNEW", "NEW", "TAPPaaS: app"),
            ],
        )
        removed = mgr.prune_domains_by_description("TAPPaaS: app", "app.new.example")
        self.assertEqual(removed, ["app.old.example"])
        mgr.delete_domain.assert_called_once_with("OLD")   # not NEW, not OTH
        mgr.delete_handler.assert_called_once_with("HOLD")  # the old domain's handler

    def test_noop_when_only_current_present(self):
        mgr = self._mgr(
            domains=[("NEW", "app.new.example", "TAPPaaS: app", True)],
            handlers=[self._handler("HNEW", "NEW", "TAPPaaS: app")],
        )
        self.assertEqual(
            mgr.prune_domains_by_description("TAPPaaS: app", "app.new.example"), []
        )
        mgr.delete_domain.assert_not_called()
        mgr.delete_handler.assert_not_called()


if __name__ == "__main__":
    unittest.main()
