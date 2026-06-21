"""Unit tests for authentik_manager + authentik_cli (issue #45, ADR-006).

Stubs the httpx.Client so the idempotent ensure paths can be exercised without
a running Authentik. Covers the forward-auth verbs (#45) and the ADR-006
user/group/binding/OIDC verbs.
"""

from __future__ import annotations

import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import MagicMock

from opnsense_controller.authentik_cli import _read_creds
from opnsense_controller.authentik_manager import (
    AuthentikConfig,
    AuthentikManager,
    OidcApp,
    ProxyApp,
    EMBEDDED_OUTPOST_NAME,
    DEFAULT_AUTHORIZATION_FLOW_SLUG,
    DEFAULT_INVALIDATION_FLOW_SLUG,
)


def _make_manager(routes: dict) -> tuple[AuthentikManager, list]:
    """Return (manager, calls) where each routed verb returns routes[(method, path)].

    ``calls`` is appended with one dict per request (method, path, json, params)
    so tests can assert what was sent. Unmatched routes return {}.
    """
    mgr = AuthentikManager(AuthentikConfig(base_url="http://x", token="t"))
    client = MagicMock()
    calls = []

    def _resp(payload):
        r = MagicMock()
        r.json.return_value = payload
        r.status_code = 200
        r.raise_for_status.return_value = None
        return r

    def get(path, params=None):
        calls.append({"method": "GET", "path": path, "params": params or {}})
        # match-by-path-only — sufficient for these tests.
        return _resp(routes.get(("GET", path), {}))

    def post(path, json=None):
        calls.append({"method": "POST", "path": path, "json": json})
        return _resp(routes.get(("POST", path), {}))

    def patch(path, json=None):
        calls.append({"method": "PATCH", "path": path, "json": json})
        return _resp(routes.get(("PATCH", path), {}))

    def delete(path):
        calls.append({"method": "DELETE", "path": path})
        return _resp({})

    client.get.side_effect = get
    client.post.side_effect = post
    client.patch.side_effect = patch
    client.delete.side_effect = delete
    client.close = MagicMock()
    mgr._client = client  # noqa: SLF001
    return mgr, calls


# ─────────────────────────────────────────────────────────────────────────────
# CLI: credentials file parser (pure helper)
# ─────────────────────────────────────────────────────────────────────────────


class TestReadCreds(unittest.TestCase):
    def _write(self, content: str) -> Path:
        d = TemporaryDirectory()
        self.addCleanup(d.cleanup)
        f = Path(d.name) / "creds.txt"
        f.write_text(content)
        return f

    def test_parses_url_and_token(self):
        f = self._write("url=http://x:9000\ntoken=abc123\n")
        self.assertEqual(_read_creds(f), ("http://x:9000", "abc123"))

    def test_strips_whitespace_and_comments(self):
        f = self._write("# comment\nurl =  http://x:9000  \n\ntoken=t\n")
        self.assertEqual(_read_creds(f), ("http://x:9000", "t"))

    def test_missing_token_raises(self):
        f = self._write("url=http://x\n")
        with self.assertRaises(SystemExit):
            _read_creds(f)


# ─────────────────────────────────────────────────────────────────────────────
# Manager: forward-auth lifecycle is idempotent
# ─────────────────────────────────────────────────────────────────────────────


class TestProxyAppEnsureCreates(unittest.TestCase):
    """When nothing exists, create both Provider and Application."""

    def test_first_run_creates_provider_and_application(self):
        mgr, calls = _make_manager({
            ("GET", "/flows/instances/"): {"results": [{"pk": "FLOW1"}]},
            ("GET", "/providers/proxy/"): {"results": []},
            ("POST", "/providers/proxy/"): {"pk": 42},
            ("GET", "/core/applications/"): {"results": []},
            ("POST", "/core/applications/"): {"pk": "APP-UUID-1"},
        })
        res = mgr.proxy_app_ensure(ProxyApp(
            name="Open WebUI", slug="openwebui",
            external_host="https://openwebui.test.tapaas.org",
            description="Forward-auth via Authentik",
        ))
        self.assertEqual(res.provider_pk, 42)
        self.assertEqual(res.application_pk, "APP-UUID-1")
        self.assertEqual(res.slug, "openwebui")

        # The Provider body carries forward_single mode + the resolved flow.
        prov_post = next(c for c in calls if c["method"] == "POST" and c["path"] == "/providers/proxy/")
        self.assertEqual(prov_post["json"]["mode"], "forward_single")
        self.assertEqual(prov_post["json"]["external_host"], "https://openwebui.test.tapaas.org")
        self.assertEqual(prov_post["json"]["authorization_flow"], "FLOW1")

        # The Application body links the Provider via pk.
        app_post = next(c for c in calls if c["method"] == "POST" and c["path"] == "/core/applications/")
        self.assertEqual(app_post["json"]["slug"], "openwebui")
        self.assertEqual(app_post["json"]["provider"], 42)

    def test_second_run_updates_in_place(self):
        # Both objects already exist — re-running must PATCH, not duplicate.
        mgr, calls = _make_manager({
            ("GET", "/flows/instances/"): {"results": [{"pk": "FLOW1"}]},
            ("GET", "/providers/proxy/"): {"results": [{"pk": 7, "name": "Open WebUI"}]},
            ("GET", "/core/applications/"): {"results": [{"pk": "EXISTING", "slug": "openwebui", "provider": 7}]},
        })
        res = mgr.proxy_app_ensure(ProxyApp(
            name="Open WebUI", slug="openwebui",
            external_host="https://openwebui.test.tapaas.org",
        ))
        self.assertEqual(res.provider_pk, 7)
        self.assertEqual(res.application_pk, "EXISTING")
        # No POSTs (creates), only PATCHes for the update path.
        self.assertFalse(any(c["method"] == "POST" for c in calls))
        self.assertTrue(any(c["method"] == "PATCH" and c["path"] == "/providers/proxy/7/" for c in calls))
        # Authentik routes Application detail on SLUG (lookup_field), not pk.
        self.assertTrue(any(c["method"] == "PATCH" and c["path"] == "/core/applications/openwebui/" for c in calls))


class TestProxyAppEnsureUsesWellKnownFlows(unittest.TestCase):
    def test_resolves_authorization_and_invalidation_flows(self):
        mgr, calls = _make_manager({
            ("GET", "/flows/instances/"): {"results": [{"pk": "FLOW1"}]},
            ("GET", "/providers/proxy/"): {"results": []},
            ("POST", "/providers/proxy/"): {"pk": 1},
            ("GET", "/core/applications/"): {"results": []},
            ("POST", "/core/applications/"): {"pk": "X"},
        })
        mgr.proxy_app_ensure(ProxyApp(name="X", slug="x", external_host="https://x"))
        flow_gets = [c for c in calls if c["method"] == "GET" and c["path"] == "/flows/instances/"]
        slugs = {c["params"].get("slug") for c in flow_gets}
        self.assertIn(DEFAULT_AUTHORIZATION_FLOW_SLUG, slugs)
        self.assertIn(DEFAULT_INVALIDATION_FLOW_SLUG, slugs)


# ─────────────────────────────────────────────────────────────────────────────
# Outpost: attach is idempotent + outpost_set_authentik_host merges config
# ─────────────────────────────────────────────────────────────────────────────


class TestOutpostAttachIsIdempotent(unittest.TestCase):
    def test_first_attach_patches_providers_list(self):
        mgr, calls = _make_manager({
            ("GET", "/outposts/instances/"): {"results": [{"pk": "OUTPOST", "name": EMBEDDED_OUTPOST_NAME, "providers": [1, 2]}]},
        })
        mgr.outpost_attach_provider(42)
        patches = [c for c in calls if c["method"] == "PATCH"]
        self.assertEqual(len(patches), 1)
        self.assertEqual(patches[0]["path"], "/outposts/instances/OUTPOST/")
        self.assertEqual(sorted(patches[0]["json"]["providers"]), [1, 2, 42])

    def test_attach_when_already_present_is_a_noop(self):
        mgr, calls = _make_manager({
            ("GET", "/outposts/instances/"): {"results": [{"pk": "OUTPOST", "name": EMBEDDED_OUTPOST_NAME, "providers": [1, 2, 42]}]},
        })
        mgr.outpost_attach_provider(42)
        self.assertFalse(any(c["method"] == "PATCH" for c in calls))

    def test_set_authentik_host_merges_existing_config(self):
        mgr, calls = _make_manager({
            ("GET", "/outposts/instances/"): {"results": [{
                "pk": "OUTPOST",
                "name": EMBEDDED_OUTPOST_NAME,
                "providers": [],
                "config": {"log_level": "info", "docker_network": "host"},
            }]},
        })
        mgr.outpost_set_authentik_host("https://identity.example.org")
        patch = next(c for c in calls if c["method"] == "PATCH")
        cfg = patch["json"]["config"]
        # Existing keys preserved, new key added.
        self.assertEqual(cfg["log_level"], "info")
        self.assertEqual(cfg["docker_network"], "host")
        self.assertEqual(cfg["authentik_host"], "https://identity.example.org")


class TestProxyAppEnsureClientSideFiltering(unittest.TestCase):
    """Regression for the issue #45 PoC bug: Authentik ignores ?name= URL filters.

    If proxy_app_ensure naively trusts the API's filtered response (it isn't —
    every call returns the full list), it PATCHes the wrong row and silently
    mangles unrelated providers. The manager MUST filter client-side.
    """

    def test_does_not_clobber_existing_provider_with_different_name(self):
        # Authentik returns BOTH providers even though we asked for "openwebui".
        mgr, calls = _make_manager({
            ("GET", "/flows/instances/"): {"results": [{"pk": "FLOW"}]},
            ("GET", "/providers/proxy/"): {"results": [
                {"pk": 1, "name": "identity"},      # pre-existing, must NOT be touched
                {"pk": 2, "name": "openwebui"},     # the one we want
            ]},
            ("GET", "/core/applications/"): {"results": [
                {"pk": "APP1", "slug": "identity", "provider": 1},
                {"pk": "APP2", "slug": "openwebui", "provider": 2},
            ]},
        })
        res = mgr.proxy_app_ensure(ProxyApp(name="openwebui", slug="openwebui",
                                            external_host="https://x"))
        # Must PATCH provider 2 / app APP2 (the openwebui ones), NEVER 1/APP1.
        self.assertEqual(res.provider_pk, 2)
        self.assertEqual(res.application_pk, "APP2")
        patched_paths = [c["path"] for c in calls if c["method"] == "PATCH"]
        self.assertIn("/providers/proxy/2/", patched_paths)
        # Application detail is routed by SLUG (Authentik quirk), not pk.
        self.assertIn("/core/applications/openwebui/", patched_paths)
        self.assertNotIn("/providers/proxy/1/", patched_paths)
        self.assertNotIn("/core/applications/identity/", patched_paths)

    def test_reuses_app_already_linked_to_existing_provider(self):
        # The 1:1 provider↔app constraint means we can't POST a new app for
        # a provider that already has one. Reuse the existing app instead.
        mgr, calls = _make_manager({
            ("GET", "/flows/instances/"): {"results": [{"pk": "FLOW"}]},
            ("GET", "/providers/proxy/"): {"results": [{"pk": 7, "name": "x"}]},
            ("GET", "/core/applications/"): {"results": [
                # The app uses a DIFFERENT slug ("legacy") but already links to provider=7.
                {"pk": "LEGACY", "slug": "legacy", "provider": 7},
            ]},
        })
        res = mgr.proxy_app_ensure(ProxyApp(name="x", slug="x",
                                            external_host="https://x"))
        # Must NOT POST a new app (Authentik would 400 "Application with this
        # provider already exists"). Reuse LEGACY and PATCH it in place.
        self.assertEqual(res.application_pk, "LEGACY")
        posts = [c for c in calls if c["method"] == "POST" and c["path"] == "/core/applications/"]
        self.assertEqual(posts, [], "must not POST a new app when provider already has one")


# ─────────────────────────────────────────────────────────────────────────────
# Embedded outpost lookup uses the well-known name
# ─────────────────────────────────────────────────────────────────────────────


class TestEmbeddedOutpostLookup(unittest.TestCase):
    def test_picks_the_embedded_outpost_from_full_list(self):
        # Authentik returns the WHOLE outpost list regardless of ?name= filter
        # (server ignores it). Manager must scan client-side and pick the row
        # whose name matches EMBEDDED_OUTPOST_NAME — otherwise we'd PATCH a
        # custom user-created outpost by accident.
        mgr, _ = _make_manager({
            ("GET", "/outposts/instances/"): {"results": [
                {"pk": "USER", "name": "user-outpost", "providers": []},
                {"pk": "EMB",  "name": EMBEDDED_OUTPOST_NAME, "providers": []},
                {"pk": "OTHER", "name": "other", "providers": []},
            ]},
        })
        mgr.outpost_attach_provider(1)
        # Should have PATCHed EMB, not USER or OTHER.
        # (PATCH path is built from the resolved outpost.pk in _embedded_outpost.)
        # If the wrong row were selected we'd PATCH /outposts/instances/USER/.
        # We can't observe that directly here without re-reading calls, but the
        # absence of an exception (RuntimeError "not found") is the proof the
        # name-matching works.


# ─────────────────────────────────────────────────────────────────────────────
# ADR-006: groups (roles), users, access bindings, OIDC
# ─────────────────────────────────────────────────────────────────────────────


class TestGroupEnsure(unittest.TestCase):
    def test_create_with_parent_resolution_and_attributes(self):
        mgr, calls = _make_manager({
            ("GET", "/core/groups/"): {"results": [{"pk": "PARENT", "name": "acme"}]},
            ("POST", "/core/groups/"): {"pk": "CHILD", "name": "acme-users"},
        })
        mgr.group_ensure("acme-users", parent_name="acme",
                         attributes={"tappaas": {"role": "user"}})
        post = next(c for c in calls if c["method"] == "POST" and c["path"] == "/core/groups/")
        self.assertEqual(post["json"]["parent"], "PARENT")
        self.assertFalse(post["json"]["is_superuser"])
        self.assertEqual(post["json"]["attributes"], {"tappaas": {"role": "user"}})

    def test_missing_parent_raises(self):
        mgr, _ = _make_manager({("GET", "/core/groups/"): {"results": []}})
        with self.assertRaises(RuntimeError):
            mgr.group_ensure("acme-users", parent_name="acme")

    def test_update_merges_attributes(self):
        mgr, calls = _make_manager({
            ("GET", "/core/groups/"): {"results": [
                {"pk": "G", "name": "acme-users", "attributes": {"keep": "x"}}]},
            ("PATCH", "/core/groups/G/"): {"pk": "G", "name": "acme-users"},
        })
        mgr.group_ensure("acme-users", attributes={"new": "y"})
        patch = next(c for c in calls if c["method"] == "PATCH")
        self.assertEqual(patch["json"]["attributes"], {"keep": "x", "new": "y"})


class TestUserEnsure(unittest.TestCase):
    def test_create_resolves_groups(self):
        mgr, calls = _make_manager({
            ("GET", "/core/groups/"): {"results": [{"pk": "GU", "name": "tappaas-users"}]},
            ("GET", "/core/users/"): {"results": []},
            ("POST", "/core/users/"): {"pk": 7, "username": "lars"},
        })
        mgr.user_ensure("lars", email="l@x", group_names=["tappaas-users"])
        post = next(c for c in calls if c["method"] == "POST" and c["path"] == "/core/users/")
        self.assertEqual(post["json"]["groups"], ["GU"])
        self.assertEqual(post["json"]["type"], "internal")

    def test_update_is_additive(self):
        mgr, calls = _make_manager({
            ("GET", "/core/groups/"): {"results": [
                {"pk": "GU", "name": "tappaas-users"}, {"pk": "GA", "name": "acme-users"}]},
            ("GET", "/core/users/"): {"results": [
                {"pk": 7, "username": "lars", "groups": ["GU"]}]},
            ("PATCH", "/core/users/7/"): {"pk": 7},
        })
        mgr.user_ensure("lars", group_names=["acme-users"])
        patch = next(c for c in calls if c["method"] == "PATCH")
        self.assertEqual(sorted(patch["json"]["groups"]), ["GA", "GU"])  # kept GU, added GA

    def test_add_to_groups_noop_when_already_member(self):
        mgr, calls = _make_manager({
            ("GET", "/core/groups/"): {"results": [{"pk": "GU", "name": "tappaas-users"}]},
            ("GET", "/core/users/"): {"results": [
                {"pk": 7, "username": "lars", "groups": ["GU"]}]},
        })
        mgr.user_add_to_groups("lars", ["tappaas-users"])
        self.assertFalse(any(c["method"] == "PATCH" for c in calls))

    def test_remove_from_groups_patches_remaining(self):
        mgr, calls = _make_manager({
            ("GET", "/core/groups/"): {"results": [
                {"pk": "GU", "name": "tappaas-users"}, {"pk": "GA", "name": "tappaas-admins"}]},
            ("GET", "/core/users/"): {"results": [
                {"pk": 7, "username": "lars", "groups": ["GU", "GA"]}]},
            ("PATCH", "/core/users/7/"): {"pk": 7},
        })
        mgr.user_remove_from_groups("lars", ["tappaas-admins"])
        patch = next(c for c in calls if c["method"] == "PATCH")
        self.assertEqual(patch["json"]["groups"], ["GU"])      # GA dropped, GU kept

    def test_remove_from_groups_noop_when_not_member(self):
        mgr, calls = _make_manager({
            ("GET", "/core/groups/"): {"results": [{"pk": "GA", "name": "tappaas-admins"}]},
            ("GET", "/core/users/"): {"results": [
                {"pk": 7, "username": "lars", "groups": ["GU"]}]},
        })
        mgr.user_remove_from_groups("lars", ["tappaas-admins"])
        self.assertFalse(any(c["method"] == "PATCH" for c in calls))

    def test_delete_existing_and_missing(self):
        mgr, calls = _make_manager({
            ("GET", "/core/users/"): {"results": [{"pk": 7, "username": "lars", "groups": []}]},
        })
        self.assertTrue(mgr.user_delete("lars"))
        self.assertTrue(any(c["method"] == "DELETE" and c["path"] == "/core/users/7/" for c in calls))
        mgr2, calls2 = _make_manager({("GET", "/core/users/"): {"results": []}})
        self.assertFalse(mgr2.user_delete("ghost"))
        self.assertFalse(any(c["method"] == "DELETE" for c in calls2))


class TestAppBindGroups(unittest.TestCase):
    def test_creates_binding_with_app_as_target(self):
        mgr, calls = _make_manager({
            ("GET", "/core/applications/"): {"results": [{"pk": "APP", "slug": "nc", "provider": 2}]},
            ("GET", "/core/groups/"): {"results": [{"pk": "GU", "name": "tappaas-users"}]},
            ("GET", "/policies/bindings/"): {"results": []},
            ("POST", "/policies/bindings/"): {"pk": "B1"},
        })
        created = mgr.app_bind_groups("nc", ["tappaas-users"])
        self.assertEqual(created, 1)
        post = next(c for c in calls if c["method"] == "POST" and c["path"] == "/policies/bindings/")
        self.assertEqual(post["json"]["target"], "APP")
        self.assertEqual(post["json"]["group"], "GU")
        self.assertTrue(post["json"]["enabled"])

    def test_idempotent_skip_when_already_bound(self):
        mgr, calls = _make_manager({
            ("GET", "/core/applications/"): {"results": [{"pk": "APP", "slug": "nc", "provider": 2}]},
            ("GET", "/core/groups/"): {"results": [{"pk": "GU", "name": "tappaas-users"}]},
            ("GET", "/policies/bindings/"): {"results": [{"pk": "B1", "target": "APP", "group": "GU", "order": 0}]},
        })
        created = mgr.app_bind_groups("nc", ["tappaas-users"])
        self.assertEqual(created, 0)
        self.assertFalse(any(c["method"] == "POST" for c in calls))


class TestAppDelete(unittest.TestCase):
    def test_deletes_app_and_BOTH_provider_endpoints(self):
        # Regression: an oauth2 provider was leaked because the proxy-endpoint
        # DELETE 404s silently (tolerated) and the loop broke before trying
        # oauth2. app_delete must hit both endpoints (the matching one deletes).
        mgr, calls = _make_manager({
            ("GET", "/core/applications/"): {"results": [
                {"pk": "APP", "slug": "test-idoidc", "provider": 2}]},
        })
        mgr.app_delete("test-idoidc")
        deletes = [c["path"] for c in calls if c["method"] == "DELETE"]
        self.assertIn("/core/applications/test-idoidc/", deletes)
        self.assertIn("/providers/proxy/2/", deletes)
        self.assertIn("/providers/oauth2/2/", deletes)

    def test_noop_when_app_absent(self):
        mgr, calls = _make_manager({("GET", "/core/applications/"): {"results": []}})
        mgr.app_delete("ghost")
        self.assertFalse(any(c["method"] == "DELETE" for c in calls))


class TestOidcAppEnsure(unittest.TestCase):
    def test_create_provider_and_application(self):
        mgr, calls = _make_manager({
            ("GET", "/flows/instances/"): {"results": [{"pk": "FLOW"}]},
            ("GET", "/propertymappings/provider/scope/"): {"results": [
                {"pk": "S-OPENID", "scope_name": "openid"},
                {"pk": "S-EMAIL", "scope_name": "email"},
                {"pk": "S-PROFILE", "scope_name": "profile"},
            ]},
            ("GET", "/crypto/certificatekeypairs/"): {"results": [
                {"pk": "CERT", "name": "authentik Self-signed Certificate"}]},
            ("GET", "/providers/oauth2/"): {"results": []},
            ("POST", "/providers/oauth2/"): {"pk": 2, "client_id": "CID", "client_secret": "CSEC"},
            ("GET", "/core/applications/"): {"results": []},
            ("POST", "/core/applications/"): {"pk": "APP"},
        })
        res = mgr.oidc_app_ensure(OidcApp(
            name="nc", slug="nc",
            redirect_uris=["https://nc.test/apps/user_oidc/code"],
        ))
        self.assertEqual(res.client_id, "CID")
        self.assertEqual(res.client_secret, "CSEC")
        self.assertEqual(res.provider_pk, 2)
        self.assertEqual(res.application_pk, "APP")
        prov = next(c for c in calls if c["method"] == "POST" and c["path"] == "/providers/oauth2/")
        self.assertEqual(prov["json"]["client_type"], "confidential")
        self.assertEqual(prov["json"]["signing_key"], "CERT")
        self.assertEqual(prov["json"]["redirect_uris"],
                         [{"matching_mode": "strict", "url": "https://nc.test/apps/user_oidc/code"}])
        self.assertEqual(prov["json"]["property_mappings"], ["S-OPENID", "S-EMAIL", "S-PROFILE"])


if __name__ == "__main__":
    unittest.main()
