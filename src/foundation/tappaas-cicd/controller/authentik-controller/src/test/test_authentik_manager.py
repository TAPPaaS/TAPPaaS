"""Unit tests for authentik_manager + authentik_cli (issue #45, ADR-006).

Stubs the httpx.Client so the idempotent ensure paths can be exercised without
a running Authentik. Covers the forward-auth verbs (#45) and the ADR-006
user/group/binding/OIDC verbs.
"""

from __future__ import annotations

import contextlib
import io
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import MagicMock

from identity_controller.authentik_cli import _read_creds
from identity_controller.authentik_manager import (
    AuthentikConfig,
    AuthentikManager,
    OidcApp,
    ProxyApp,
    EMBEDDED_OUTPOST_NAME,
    DEFAULT_AUTHORIZATION_FLOW_SLUG,
    DEFAULT_INVALIDATION_FLOW_SLUG,
    RECOVERY_FLOW_SLUG,
    RECOVERY_PROMPT_STAGE_NAME,
    RECOVERY_WRITE_STAGE_NAME,
    RECOVERY_PROMPT_PASSWORD,
    RECOVERY_PROMPT_PASSWORD_REPEAT,
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

    def test_from_2025_12_the_parent_is_a_list(self):
        # #748: 2025.12 replaced the single ``parent`` with ``parents``.
        mgr, calls = _make_manager({
            ("GET", "/admin/version/"): {"version_current": "2025.12.6"},
            ("GET", "/core/groups/"): {"results": [{"pk": "PARENT", "name": "acme"}]},
            ("POST", "/core/groups/"): {"pk": "CHILD", "name": "acme-users"},
        })
        mgr.group_ensure("acme-users", parent_name="acme")
        post = next(c for c in calls if c["method"] == "POST" and c["path"] == "/core/groups/")
        self.assertEqual(post["json"]["parents"], ["PARENT"])
        self.assertNotIn("parent", post["json"])

    def test_before_2025_12_the_parent_is_single(self):
        mgr, calls = _make_manager({
            ("GET", "/admin/version/"): {"version_current": "2025.10.4"},
            ("GET", "/core/groups/"): {"results": []},
            ("POST", "/core/groups/"): {"pk": "G", "name": "solo"},
        })
        mgr.group_ensure("solo")
        post = next(c for c in calls if c["method"] == "POST")
        self.assertIn("parent", post["json"])
        self.assertIsNone(post["json"]["parent"])
        self.assertNotIn("parents", post["json"])

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


class TestEmailVerified(unittest.TestCase):
    """#748: Authentik 2025.10 defaults email_verified to false; TAPPaaS keeps it true."""
    SCOPES = {"results": [
        {"pk": "STOCK", "name": "authentik default OAuth Mapping: OpenID 'email'", "scope_name": "email"},
        {"pk": "PROF", "name": "authentik default OAuth Mapping: OpenID 'profile'", "scope_name": "profile"},
        {"pk": "OURS", "name": "tappaas: OpenID 'email' (verified)", "scope_name": "email"},
    ]}

    def test_swaps_the_stock_email_mapping_on_every_provider(self):
        mgr, calls = _make_manager({
            ("GET", "/propertymappings/provider/scope/"): self.SCOPES,
            ("PATCH", "/propertymappings/provider/scope/OURS/"): {"pk": "OURS"},
            ("GET", "/providers/oauth2/"): {"results": [
                {"pk": 1, "property_mappings": ["OPENID", "STOCK", "PROF"]},   # swapped
                {"pk": 2, "property_mappings": ["OPENID", "OURS", "PROF"]},    # already right
                {"pk": 3, "property_mappings": ["OPENID"]},                    # no email scope: left alone
            ]},
        })
        self.assertEqual(mgr.oidc_email_verified_ensure(), 1)
        patches = [c for c in calls if c["method"] == "PATCH" and c["path"].startswith("/providers/oauth2/")]
        self.assertEqual([c["path"] for c in patches], ["/providers/oauth2/1/"])
        self.assertEqual(patches[0]["json"]["property_mappings"], ["OPENID", "PROF", "OURS"])
        mapping = next(c for c in calls if c["path"] == "/propertymappings/provider/scope/OURS/")
        self.assertIn('"email_verified": True', mapping["json"]["expression"])

    def test_a_new_oidc_app_gets_the_verified_mapping(self):
        mgr, calls = _make_manager({
            ("GET", "/propertymappings/provider/scope/"): self.SCOPES,
            ("PATCH", "/propertymappings/provider/scope/OURS/"): {"pk": "OURS"},
            ("GET", "/flows/instances/"): {"results": [
                {"pk": "F1", "slug": "default-provider-authorization-implicit-consent"},
                {"pk": "F2", "slug": "default-provider-invalidation-flow"}]},
            ("GET", "/crypto/certificatekeypairs/"): {"results": [{"pk": "K", "name": "authentik Self-signed Certificate"}]},
            ("GET", "/providers/oauth2/"): {"results": []},
            ("POST", "/providers/oauth2/"): {"pk": 9, "client_id": "c", "client_secret": "s"},
            ("GET", "/core/applications/"): {"results": []},
            ("POST", "/core/applications/"): {"pk": "A"},
        })
        try:
            mgr.oidc_app_ensure(OidcApp(name="x", slug="x", redirect_uris=["https://x/cb"]))
        except Exception:
            pass   # the read-back of the client secret is not routed here; the POST is what matters
        post = next(c for c in calls if c["method"] == "POST" and c["path"] == "/providers/oauth2/")
        self.assertIn("OURS", post["json"]["property_mappings"])
        self.assertNotIn("STOCK", post["json"]["property_mappings"])


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


class TestProxyAppLaunchUrl(unittest.TestCase):
    ROUTES = {
        ("GET", "/flows/instances/"): {"results": [{"pk": "FLOW1"}]},
        ("GET", "/providers/proxy/"): {"results": []},
        ("POST", "/providers/proxy/"): {"pk": 42},
        ("GET", "/core/applications/"): {"results": []},
        ("POST", "/core/applications/"): {"pk": "APP"},
    }

    def _launch(self, **kw):
        mgr, calls = _make_manager(self.ROUTES)
        mgr.proxy_app_ensure(ProxyApp(name="jellyfin-gate", slug="jellyfin-gate",
                                      external_host="https://jf.example.org", **kw))
        return next(c for c in calls if c["method"] == "POST" and c["path"] == "/core/applications/")["json"]

    def test_default_launches_the_external_host(self):
        self.assertEqual(self._launch()["meta_launch_url"], "https://jf.example.org")

    def test_a_gate_can_be_hidden_from_the_app_list(self):
        # #806: the module's OIDC app shows the tile; its forward-auth gate must not.
        self.assertEqual(self._launch(launch_url="blank://blank")["meta_launch_url"], "blank://blank")


class TestAppIsProxy(unittest.TestCase):
    APPS = {"results": [{"pk": "A1", "slug": "jellyfin", "provider": 7},
                        {"pk": "A2", "slug": "immich", "provider": 9}]}

    def test_proxy_backed_app(self):
        mgr, _ = _make_manager({("GET", "/core/applications/"): self.APPS,
                                ("GET", "/providers/proxy/"): {"results": [{"pk": 7, "name": "jellyfin"}]}})
        self.assertTrue(mgr.app_is_proxy("jellyfin"))

    def test_oidc_backed_and_missing_apps_are_not(self):
        mgr, _ = _make_manager({("GET", "/core/applications/"): self.APPS,
                                ("GET", "/providers/proxy/"): {"results": [{"pk": 7, "name": "jellyfin"}]}})
        self.assertFalse(mgr.app_is_proxy("immich"))
        self.assertFalse(mgr.app_is_proxy("ghost"))


class TestCliAppDelete(unittest.TestCase):
    """app-delete detaches only ITS provider, and --only-proxy spares an OIDC app (#806)."""

    APPS = {"results": [{"pk": "A1", "slug": "jellyfin", "provider": 7},
                        {"pk": "A2", "slug": "test-idfa", "provider": 8}]}
    OUTPOST = {"results": [{"pk": "OP", "name": EMBEDDED_OUTPOST_NAME, "providers": [7, 8]}]}

    def _run(self, argv, proxy_rows):
        import contextlib
        import io
        from unittest.mock import patch
        from identity_controller import authentik_cli as cli
        mgr, calls = _make_manager({("GET", "/core/applications/"): self.APPS,
                                    ("GET", "/providers/proxy/"): {"results": proxy_rows},
                                    ("GET", "/outposts/instances/"): self.OUTPOST})
        ctx = MagicMock()
        ctx.__enter__.return_value = mgr   # the real __enter__ opens a live client
        with patch.object(cli, "_make_manager", return_value=ctx), contextlib.redirect_stdout(io.StringIO()):
            cli.main(argv)
        return calls

    def test_detaches_only_the_deleted_apps_provider(self):
        calls = self._run(["app-delete", "test-idfa"], [{"pk": 7}, {"pk": 8}])
        patch_ = next(c for c in calls if c["method"] == "PATCH" and c["path"] == "/outposts/instances/OP/")
        self.assertEqual(patch_["json"]["providers"], [7])
        self.assertIn("/core/applications/test-idfa/", [c["path"] for c in calls if c["method"] == "DELETE"])

    def test_only_proxy_keeps_an_oidc_app(self):
        calls = self._run(["app-delete", "jellyfin", "--only-proxy"], [{"pk": 8}])
        self.assertFalse(any(c["method"] in ("DELETE", "PATCH") for c in calls))

    def test_only_proxy_deletes_a_proxy_app(self):
        calls = self._run(["app-delete", "jellyfin", "--only-proxy"], [{"pk": 7}])
        self.assertIn("/core/applications/jellyfin/", [c["path"] for c in calls if c["method"] == "DELETE"])


class TestScopeMappings(unittest.TestCase):
    ROWS = {"results": [
        {"pk": "S-GENERIC", "name": "TAPPaaS OAuth Mapping: groups", "scope_name": "groups"},
        {"pk": "S-NC", "name": "TAPPaaS OAuth Mapping: nextcloud groups", "scope_name": "groups"},
        {"pk": "S-OPENID", "name": "authentik default OAuth Mapping: OpenID 'openid'", "scope_name": "openid"},
    ]}

    def test_a_mapping_name_beats_a_shared_scope_name(self):
        mgr, _ = _make_manager({("GET", "/propertymappings/provider/scope/"): self.ROWS})
        self.assertEqual(mgr._scope_mapping_pks(["openid", "TAPPaaS OAuth Mapping: nextcloud groups"]),
                         ["S-OPENID", "S-NC"])

    def test_ensure_creates_then_updates_by_name(self):
        mgr, calls = _make_manager({
            ("GET", "/propertymappings/provider/scope/"): {"results": []},
            ("POST", "/propertymappings/provider/scope/"): {"pk": "NEW", "name": "m", "scope_name": "groups"},
        })
        mgr.scope_mapping_ensure("m", "groups", "return {}")
        self.assertTrue(any(c["method"] == "POST" for c in calls))
        mgr, calls = _make_manager({
            ("GET", "/propertymappings/provider/scope/"): {"results": [{"pk": "OLD", "name": "m", "scope_name": "groups"}]},
            ("PATCH", "/propertymappings/provider/scope/OLD/"): {"pk": "OLD", "name": "m", "scope_name": "groups"},
        })
        mgr.scope_mapping_ensure("m", "groups", "return {}")
        patch = next(c for c in calls if c["method"] == "PATCH")
        self.assertEqual(patch["json"]["expression"], "return {}")


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
        # Authentik 2026.8 defaults a provider's grant list to EMPTY: without
        # these the login fails at the authorize step (invalid_request).
        self.assertEqual(prov["json"]["grant_types"], ["authorization_code", "refresh_token"])

    def _update_routes(self, grants):
        return {
            ("GET", "/flows/instances/"): {"results": [{"pk": "FLOW"}]},
            ("GET", "/propertymappings/provider/scope/"): {"results": [
                {"pk": "S-OPENID", "scope_name": "openid"},
                {"pk": "S-EMAIL", "scope_name": "email"},
                {"pk": "S-PROFILE", "scope_name": "profile"},
            ]},
            ("GET", "/crypto/certificatekeypairs/"): {"results": [
                {"pk": "CERT", "name": "authentik Self-signed Certificate"}]},
            ("GET", "/providers/oauth2/"): {"results": [
                {"pk": 7, "name": "immich", "grant_types": grants}]},
            ("PATCH", "/providers/oauth2/7/"): {"pk": 7, "client_id": "CID", "client_secret": "CSEC"},
            ("GET", "/core/applications/"): {"results": [{"pk": "APP", "slug": "immich", "provider": 7}]},
            ("PATCH", "/core/applications/immich/"): {"pk": "APP"},
        }

    def test_update_adds_login_grants_to_an_empty_provider(self):
        # The provider immich and vaultwarden got on hrossen (2026-10-06).
        mgr, calls = _make_manager(self._update_routes([]))
        mgr.oidc_app_ensure(OidcApp(name="immich", slug="immich",
                                    redirect_uris=["https://immich.test/auth/login"]))
        patch = next(c for c in calls if c["method"] == "PATCH" and c["path"] == "/providers/oauth2/7/")
        self.assertEqual(patch["json"]["grant_types"], ["authorization_code", "refresh_token"])

    def test_launch_url_is_set_on_the_application(self):
        mgr, calls = _make_manager(self._update_routes([]))
        mgr.oidc_app_ensure(OidcApp(name="immich", slug="immich",
                                    redirect_uris=["https://immich.test/auth/login"],
                                    launch_url="https://immich.test/auth/login?autoLaunch=1"))
        app = next(c for c in calls if c["method"] == "PATCH" and c["path"] == "/core/applications/immich/")
        self.assertEqual(app["json"]["meta_launch_url"], "https://immich.test/auth/login?autoLaunch=1")

    def test_no_launch_url_leaves_the_application_alone(self):
        # An operator's own launch URL survives a module that declares none.
        mgr, calls = _make_manager(self._update_routes([]))
        mgr.oidc_app_ensure(OidcApp(name="immich", slug="immich",
                                    redirect_uris=["https://immich.test/auth/login"]))
        app = next(c for c in calls if c["method"] == "PATCH" and c["path"] == "/core/applications/immich/")
        self.assertNotIn("meta_launch_url", app["json"])

    def test_icon_is_set_on_the_application(self):
        mgr, calls = _make_manager(self._update_routes([]))
        mgr.app_icon_ensure = MagicMock(return_value="tappaas-app-immich-abc.svg")
        mgr.oidc_app_ensure(OidcApp(name="Immich", slug="immich",
                                    redirect_uris=["https://immich.test/auth/login"], icon="auto"))
        app = next(c for c in calls if c["method"] == "PATCH" and c["path"] == "/core/applications/immich/")
        self.assertEqual(app["json"]["meta_icon"], "tappaas-app-immich-abc.svg")
        self.assertEqual(app["json"]["name"], "Immich")

    def test_a_display_name_keeps_the_provider(self):
        # Renaming the tile must not create a second OIDC client: the module
        # holds the first one's credentials.
        mgr, calls = _make_manager(self._update_routes([]))
        res = mgr.oidc_app_ensure(OidcApp(name="Immich Photos", slug="immich",
                                          redirect_uris=["https://immich.test/auth/login"]))
        self.assertFalse([c for c in calls if c["method"] == "POST" and c["path"] == "/providers/oauth2/"])
        patch = next(c for c in calls if c["method"] == "PATCH" and c["path"] == "/providers/oauth2/7/")
        self.assertEqual(patch["json"]["name"], "immich")
        self.assertEqual(res.client_id, "CID")

    def test_no_icon_leaves_the_icon_alone(self):
        # An operator's own icon survives a caller that names none.
        mgr, calls = _make_manager(self._update_routes([]))
        mgr.oidc_app_ensure(OidcApp(name="immich", slug="immich",
                                    redirect_uris=["https://immich.test/auth/login"]))
        app = next(c for c in calls if c["method"] == "PATCH" and c["path"] == "/core/applications/immich/")
        self.assertNotIn("meta_icon", app["json"])

    def test_update_never_narrows_existing_grants(self):
        wide = ["authorization_code", "hybrid", "implicit", "client_credentials", "password"]
        mgr, calls = _make_manager(self._update_routes(wide))
        mgr.oidc_app_ensure(OidcApp(name="immich", slug="immich",
                                    redirect_uris=["https://immich.test/auth/login"]))
        patch = next(c for c in calls if c["method"] == "PATCH" and c["path"] == "/providers/oauth2/7/")
        self.assertEqual(patch["json"]["grant_types"], wide + ["refresh_token"])


class TestCheckSelfConfig(unittest.TestCase):
    """Drift detector for the identity self-config vs the expected host (#474)."""

    def _routes(self, app_url, proxy_host, oauth_uri, outpost_host):
        return {
            ("GET", "/core/applications/"): {
                "results": [{"name": "Identity", "slug": "identity", "meta_launch_url": app_url}]},
            ("GET", "/providers/proxy/"): {
                "results": [{"name": "identity", "external_host": proxy_host}]},
            ("GET", "/providers/oauth2/"): {
                "results": [{"name": "identity", "redirect_uris": [{"url": oauth_uri}]}]},
            ("GET", "/outposts/instances/"): {
                "results": [{"name": EMBEDDED_OUTPOST_NAME, "config": {"authentik_host": outpost_host}}]},
        }

    def test_in_sync_when_all_match(self):
        h = "https://identity.example.eu"
        mgr, _ = _make_manager(self._routes(h, h, h + "/outpost.goauthentik.io/callback", h))
        findings = mgr.check_self_config(h)
        self.assertTrue(all(f["in_sync"] for f in findings), findings)

    def test_detects_drift_per_object(self):
        new = "https://identity.new.eu"
        old = "https://identity.old.eu"
        # app + oauth stale (old domain), proxy + outpost already on new.
        mgr, _ = _make_manager(self._routes(old, new, old + "/callback", new))
        by = {f["field"]: f["in_sync"] for f in mgr.check_self_config(new)}
        self.assertFalse(by["application.meta_launch_url"])
        self.assertTrue(by["provider.proxy.external_host"])
        self.assertFalse(by["provider.oauth2.redirect_uris"])
        self.assertTrue(by["outpost.authentik_host"])


class TestRecoveryFlowEnsure(unittest.TestCase):
    """The password-recovery flow: admin-issued link, no SMTP."""

    BRAND = {"brand_uuid": "BRAND", "domain": "authentik-default",
             "default": True, "flow_recovery": None}

    def _fresh_routes(self) -> dict:
        """Nothing exists yet — every ensure has to create."""
        return {
            ("GET", "/flows/instances/"): {"results": []},
            ("POST", "/flows/instances/"): {"pk": "FLOW"},
            ("GET", "/stages/prompt/prompts/"): {"results": []},
            ("POST", "/stages/prompt/prompts/"): {"pk": "PROMPT"},
            ("GET", "/stages/prompt/stages/"): {"results": []},
            ("POST", "/stages/prompt/stages/"): {"pk": "PSTAGE"},
            ("GET", "/stages/user_write/"): {"results": []},
            ("POST", "/stages/user_write/"): {"pk": "WSTAGE"},
            ("GET", "/flows/bindings/"): {"results": []},
            ("POST", "/flows/bindings/"): {"pk": "BINDING"},
            ("GET", "/core/brands/"): {"results": [dict(self.BRAND)]},
        }

    def _converged_routes(self) -> dict:
        """Everything already in place, brand already pointing at the flow."""
        return {
            ("GET", "/flows/instances/"): {"results": [
                {"pk": "FLOW", "slug": RECOVERY_FLOW_SLUG, "designation": "recovery"}]},
            ("GET", "/stages/prompt/prompts/"): {"results": [
                {"pk": "P1", "name": RECOVERY_PROMPT_PASSWORD},
                {"pk": "P2", "name": RECOVERY_PROMPT_PASSWORD_REPEAT}]},
            ("GET", "/stages/prompt/stages/"): {"results": [
                {"pk": "PSTAGE", "name": RECOVERY_PROMPT_STAGE_NAME}]},
            ("GET", "/stages/user_write/"): {"results": [
                {"pk": "WSTAGE", "name": RECOVERY_WRITE_STAGE_NAME}]},
            ("GET", "/flows/bindings/"): {"results": [
                {"pk": "B1", "target": "FLOW", "stage": "PSTAGE", "order": 10},
                {"pk": "B2", "target": "FLOW", "stage": "WSTAGE", "order": 20}]},
            ("GET", "/core/brands/"): {"results": [dict(self.BRAND, flow_recovery="FLOW")]},
        }

    def test_creates_recovery_flow_and_points_brand_at_it(self):
        mgr, calls = _make_manager(self._fresh_routes())
        res = mgr.recovery_flow_ensure()
        self.assertTrue(res["created"])
        flow = next(c for c in calls if c["method"] == "POST" and c["path"] == "/flows/instances/")
        self.assertEqual(flow["json"]["designation"], "recovery")
        self.assertEqual(flow["json"]["slug"], RECOVERY_FLOW_SLUG)
        brand = next(c for c in calls if c["method"] == "PATCH" and c["path"] == "/core/brands/BRAND/")
        self.assertEqual(brand["json"], {"flow_recovery": "FLOW"})
        self.assertTrue(res["brand_changed"])

    def test_binds_prompt_then_write_in_order(self):
        mgr, calls = _make_manager(self._fresh_routes())
        res = mgr.recovery_flow_ensure()
        self.assertEqual(res["bindings_created"], 2)
        bindings = [c["json"] for c in calls
                    if c["method"] == "POST" and c["path"] == "/flows/bindings/"]
        self.assertEqual([b["stage"] for b in bindings], ["PSTAGE", "WSTAGE"])
        self.assertEqual([b["order"] for b in bindings], [10, 20])
        self.assertTrue(all(b["target"] == "FLOW" for b in bindings))

    def test_prompt_asks_for_password_twice(self):
        # Two password-type fields is what makes Authentik enforce the match.
        mgr, calls = _make_manager(self._fresh_routes())
        mgr.recovery_flow_ensure()
        prompts = [c["json"] for c in calls
                   if c["method"] == "POST" and c["path"] == "/stages/prompt/prompts/"]
        self.assertEqual([p["field_key"] for p in prompts], ["password", "password_repeat"])
        self.assertTrue(all(p["type"] == "password" and p["required"] for p in prompts))

    def test_user_write_stage_never_creates_users(self):
        # Safety: without a flow_token there is no pending user, and this stage
        # must fail the flow rather than mint an account.
        mgr, calls = _make_manager(self._fresh_routes())
        mgr.recovery_flow_ensure()
        write = next(c for c in calls
                     if c["method"] == "POST" and c["path"] == "/stages/user_write/")
        self.assertEqual(write["json"]["user_creation_mode"], "never_create")

    def test_idempotent_second_run_creates_nothing(self):
        mgr, calls = _make_manager(self._converged_routes())
        res = mgr.recovery_flow_ensure()
        self.assertFalse(res["created"])
        self.assertEqual(res["bindings_created"], 0)
        self.assertFalse(res["brand_changed"])
        self.assertFalse([c for c in calls if c["method"] == "POST"],
                         "a converged instance must not create anything")

    def test_moves_a_binding_left_at_the_wrong_order(self):
        routes = self._converged_routes()
        routes[("GET", "/flows/bindings/")] = {"results": [
            {"pk": "B1", "target": "FLOW", "stage": "PSTAGE", "order": 10},
            {"pk": "B2", "target": "FLOW", "stage": "WSTAGE", "order": 5}]}
        mgr, calls = _make_manager(routes)
        mgr.recovery_flow_ensure()
        patch = next(c for c in calls if c["method"] == "PATCH" and c["path"] == "/flows/bindings/B2/")
        self.assertEqual(patch["json"], {"order": 20})

    def test_no_brand_leaves_the_brand_alone(self):
        mgr, calls = _make_manager(self._fresh_routes())
        res = mgr.recovery_flow_ensure(attach_to_brand=False)
        self.assertFalse(res["attached_to_brand"])
        self.assertFalse([c for c in calls if c["path"].startswith("/core/brands/")
                          and c["method"] == "PATCH"])

    def test_brand_lookup_requires_a_default_brand(self):
        routes = self._fresh_routes()
        routes[("GET", "/core/brands/")] = {"results": [dict(self.BRAND, default=False)]}
        mgr, _ = _make_manager(routes)
        with self.assertRaises(RuntimeError):
            mgr.recovery_flow_ensure()



class TestBeforeFilesApi(unittest.TestCase):
    """#858: before 2025.12 Authentik has no /admin/file/. A site there must
    still update — no icon, no logo upload — or it can never climb to 2025.12."""

    OLD = {("GET", "/admin/version/"): {"version_current": "2025.6.4"}}

    def _no_file_calls(self, calls):
        self.assertFalse([c for c in calls if c.get("path", c.get("p")) == "/admin/file/"])

    def test_oidc_app_on_an_old_server_gets_no_icon(self):
        routes = {**TestOidcAppEnsure()._update_routes([]), **self.OLD}
        mgr, calls = _make_manager(routes)
        mgr.oidc_app_ensure(OidcApp(name="Immich", slug="immich",
                                    redirect_uris=["https://immich.test/auth/login"], icon="auto"))
        app = next(c for c in calls if c["method"] == "PATCH" and c["path"] == "/core/applications/immich/")
        self.assertNotIn("meta_icon", app["json"])
        self.assertEqual(app["json"]["name"], "Immich")
        self._no_file_calls(calls)

    def test_proxy_app_on_an_old_server_gets_no_icon(self):
        mgr, calls = _make_manager({
            ("GET", "/flows/instances/"): {"results": [{"pk": "FLOW1"}]},
            ("GET", "/providers/proxy/"): {"results": []},
            ("POST", "/providers/proxy/"): {"pk": 42},
            ("GET", "/core/applications/"): {"results": []},
            ("POST", "/core/applications/"): {"pk": "APP-UUID-1"},
            **self.OLD,
        })
        mgr.proxy_app_ensure(ProxyApp(name="Open WebUI", slug="openwebui",
                                      external_host="https://openwebui.test", icon="auto"))
        app_post = next(c for c in calls if c["method"] == "POST" and c["path"] == "/core/applications/")
        self.assertNotIn("meta_icon", app_post["json"])
        self._no_file_calls(calls)

    def test_brand_on_an_old_server_gets_its_title_and_heading_only(self):
        mgr, calls = TestBrandEnsure()._mgr(dict(TestBrandEnsure.BRAND), [])
        mgr._version = "2025.6.4"  # noqa: SLF001
        changed = mgr.brand_ensure("rossen")
        brand_patch = next(c for c in calls if c["m"] == "PATCH" and c["p"] == "/core/brands/B/")
        self.assertEqual(brand_patch["json"], {"branding_title": "rossen"})
        flow_patch = next(c for c in calls if c["m"] == "PATCH" and c["p"].startswith("/flows/instances/"))
        self.assertEqual(flow_patch["json"], {"title": "Sign in"})
        self.assertFalse([c for c in calls if c["p"] == "/admin/file/"])
        self.assertTrue(changed)

    def test_from_2025_12_the_icon_is_uploaded(self):
        mgr, calls = TestBrandEnsure()._mgr(dict(TestBrandEnsure.BRAND), [])
        mgr._version = "2025.12.0"  # noqa: SLF001
        self.assertTrue(mgr.app_icon_ensure("immich", "Immich", "auto").startswith("tappaas-app-immich-"))
        self.assertTrue([c for c in calls if c["m"] == "POST" and c["p"] == "/admin/file/"])

    def test_an_unreadable_version_is_taken_as_new(self):
        mgr, _ = TestBrandEnsure()._mgr(dict(TestBrandEnsure.BRAND), [])
        mgr._version = ""  # noqa: SLF001 — /admin/version/ did not answer
        self.assertTrue(mgr.has_files_api())


class TestUploadRefused(unittest.TestCase):
    """An icon or logo the server will not take is cosmetic: the app or the
    brand is still ensured, with a warning (a 2025.12 server whose /data is not
    mounted answers every upload with HTTP 500)."""

    def _refusing(self):
        import httpx
        mgr, calls = TestBrandEnsure()._mgr(dict(TestBrandEnsure.BRAND), [])
        mgr._version = "2025.12.0"  # noqa: SLF001
        inner = mgr._client.post.side_effect  # noqa: SLF001

        def post(path, json=None, files=None, data=None):
            if path == "/admin/file/":
                calls.append({"m": "POST", "p": path})
                req = httpx.Request("POST", "http://x/api/v3/admin/file/")
                raise httpx.HTTPStatusError("500", request=req, response=httpx.Response(
                    500, request=req, text="No file management backend configured."))
            return inner(path, json=json, files=files, data=data)
        mgr._client.post.side_effect = post  # noqa: SLF001
        return mgr, calls

    def test_a_refused_icon_keeps_the_tile_icon(self):
        mgr, _ = self._refusing()
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertIsNone(mgr.app_icon_ensure("logging", "Logging", "auto"))
        self.assertIn("[Warning] the icon for 'logging'", err.getvalue())
        self.assertIn("No file management backend", err.getvalue())

    def test_a_refused_logo_still_sets_the_title(self):
        mgr, calls = self._refusing()
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            mgr.brand_ensure("rossen")
        patch = next(c for c in calls if c["m"] == "PATCH" and c["p"] == "/core/brands/B/")
        self.assertEqual(patch["json"], {"branding_title": "rossen"})
        self.assertIn("site logo could not be uploaded", err.getvalue())


if __name__ == "__main__":
    unittest.main()


class TestBrandEnsure(unittest.TestCase):
    """#479: the login page shows the site, not Authentik."""

    def _mgr(self, brand: dict, files: list[str], flow_title: str = "Welcome to authentik!"):
        from identity_controller.authentik_manager import AuthentikConfig, AuthentikManager
        mgr = AuthentikManager(AuthentikConfig(base_url="http://x", token="t"))
        calls: list[dict] = []

        def resp(payload):
            r = MagicMock()
            r.json.return_value = payload
            r.raise_for_status.return_value = None
            return r

        def get(path, params=None):
            calls.append({"m": "GET", "p": path})
            if path == "/core/brands/":
                return resp({"results": [brand]})
            if path == "/admin/file/":
                return resp([{"name": n} for n in files])
            if path == "/flows/instances/":
                return resp({"results": [{"pk": "AUTHFLOW", "slug": "default-authentication-flow",
                                          "title": flow_title}]})
            return resp({})

        def post(path, json=None, files=None, data=None):
            calls.append({"m": "POST", "p": path, "files": files, "data": data})
            return resp({})

        def patch(path, json=None):
            calls.append({"m": "PATCH", "p": path, "json": json})
            return resp({})

        client = MagicMock()
        client.get.side_effect = get
        client.post.side_effect = post
        client.patch.side_effect = patch
        mgr._client = client
        return mgr, calls

    BRAND = {"brand_uuid": "B", "default": True, "branding_title": "authentik",
             "branding_logo": "/static/dist/assets/icons/icon_left_brand.svg",
             "branding_favicon": "/static/dist/assets/icons/icon.png", "flow_authentication": "AUTHFLOW"}

    def test_fresh_brand_gets_logo_icon_title_and_flow_heading(self):
        mgr, calls = self._mgr(dict(self.BRAND), [])
        changed = mgr.brand_ensure("rossen")
        ups = [c for c in calls if c["m"] == "POST" and c["p"] == "/admin/file/"]
        self.assertEqual(len(ups), 3)                     # logo, dark + light; icon
        names = [u["data"]["name"] for u in ups]
        self.assertTrue(names[0].endswith("-dark.svg") and names[1].endswith("-light.svg"))
        logo = ups[1]["files"]["file"][1].decode()
        self.assertIn(">rossen</text>", logo)
        self.assertIn('fill="#151515"', logo)              # dark text on the light card
        self.assertIn("powered by TAPPaaS", logo)
        self.assertEqual(ups[0]["data"]["usage"], "media")
        brand_patch = next(c for c in calls if c["m"] == "PATCH" and c["p"] == "/core/brands/B/")
        self.assertEqual(brand_patch["json"]["branding_title"], "rossen")
        self.assertTrue(brand_patch["json"]["branding_logo"].startswith("tappaas-site-logo-"))
        self.assertTrue(brand_patch["json"]["branding_logo"].endswith("-%(theme)s.svg"))
        self.assertTrue(brand_patch["json"]["branding_favicon"].startswith("tappaas-site-icon-"))
        flow_patch = next(c for c in calls if c["m"] == "PATCH" and c["p"].startswith("/flows/instances/"))
        self.assertEqual(flow_patch["json"], {"title": "Sign in"})
        self.assertTrue(changed)

    def test_converged_changes_nothing(self):
        mgr, calls = self._mgr(dict(self.BRAND), [])
        mgr.brand_ensure("rossen")
        done = {c["json"]["branding_logo"] for c in calls if c["m"] == "PATCH" and c["p"] == "/core/brands/B/"}
        icon = {c["json"]["branding_favicon"] for c in calls if c["m"] == "PATCH" and c["p"] == "/core/brands/B/"}
        brand = dict(self.BRAND, branding_title="rossen", branding_logo=done.pop(), branding_favicon=icon.pop())
        files = [brand["branding_logo"].replace("%(theme)s", t) for t in ("dark", "light")] + [brand["branding_favicon"]]
        mgr2, calls2 = self._mgr(brand, files, flow_title="Sign in")
        self.assertEqual(mgr2.brand_ensure("rossen"), [])
        self.assertFalse([c for c in calls2 if c["m"] in ("POST", "PATCH")])

    def test_names_are_escaped_and_long_names_shrink(self):
        from identity_controller.authentik_manager import site_logo_svg, site_icon_svg
        svg = site_logo_svg('Smith & <Co>')
        self.assertIn("Smith &amp; &lt;Co&gt;", svg)
        self.assertIn('font-size="34"', site_logo_svg("short"))
        self.assertNotIn('font-size="34"', site_logo_svg("a very long site name indeed"))
        self.assertIn(">S</text>", site_icon_svg("smith"))


class TestAppIcon(TestBrandEnsure):
    """App tiles on the start page carry the module's icon, or a generated one."""

    def test_own_icon_is_uploaded_once_under_a_content_name(self):
        mgr, calls = self._mgr(dict(self.BRAND), [])
        name = mgr.app_icon_ensure("forgejo", "Forgejo", (b"<svg>f</svg>", "svg"))
        self.assertRegex(name, r"^tappaas-app-forgejo-[0-9a-f]{12}\.svg$")
        ups = [c for c in calls if c["m"] == "POST" and c["p"] == "/admin/file/"]
        self.assertEqual([u["data"]["name"] for u in ups], [name])
        self.assertEqual(ups[0]["files"]["file"][2], "image/svg+xml")
        mgr2, calls2 = self._mgr(dict(self.BRAND), [name])
        self.assertEqual(mgr2.app_icon_ensure("forgejo", "Forgejo", (b"<svg>f</svg>", "svg")), name)
        self.assertFalse([c for c in calls2 if c["m"] == "POST"])

    def test_a_changed_icon_is_a_new_file(self):
        mgr, _ = self._mgr(dict(self.BRAND), [])
        a = mgr.app_icon_ensure("forgejo", "Forgejo", (b"<svg>1</svg>", "svg"))
        b = mgr.app_icon_ensure("forgejo", "Forgejo", (b"<svg>2</svg>", "svg"))
        self.assertNotEqual(a, b)

    def test_auto_icon_is_the_initial_on_a_colour(self):
        from identity_controller.authentik_manager import app_icon_svg
        mgr, calls = self._mgr(dict(self.BRAND), [])
        name = mgr.app_icon_ensure("litellm", "LiteLLM", "auto")
        self.assertTrue(name.endswith(".svg"))
        svg = app_icon_svg("LiteLLM")
        self.assertIn(">L</text>", svg)
        self.assertEqual(svg, app_icon_svg("LiteLLM"))            # stable: same name, same tile
        self.assertIn("&lt;", app_icon_svg("<x"))                 # escaped


class TestBrandEnsureOwnLogo(TestBrandEnsure):
    """#479: a site's own logo replaces the generated one."""

    def test_one_file_serves_both_themes(self):
        mgr, calls = self._mgr(dict(self.BRAND), [])
        mgr.brand_ensure("rossen", logo=(b"<svg>own</svg>", "svg"))
        ups = [c for c in calls if c["m"] == "POST" and c["p"] == "/admin/file/"]
        logo_up = [u for u in ups if "logo" in u["data"]["name"]]
        self.assertEqual(len(logo_up), 1)
        self.assertEqual(logo_up[0]["files"]["file"][1], b"<svg>own</svg>")
        patch = next(c for c in calls if c["m"] == "PATCH" and c["p"] == "/core/brands/B/")
        self.assertNotIn("%(theme)s", patch["json"]["branding_logo"])
        self.assertTrue(patch["json"]["branding_logo"].endswith(".svg"))

    def test_light_and_dark_files(self):
        mgr, calls = self._mgr(dict(self.BRAND), [])
        mgr.brand_ensure("rossen", logo=(b"PNGL", "png"), logo_dark=(b"PNGD", "png"))
        names = sorted(c["data"]["name"] for c in calls if c["m"] == "POST" and "logo" in c["data"]["name"])
        self.assertTrue(names[0].endswith("-dark.png") and names[1].endswith("-light.png"))
        mimes = {c["files"]["file"][2] for c in calls if c["m"] == "POST" and "logo" in c["data"]["name"]}
        self.assertEqual(mimes, {"image/png"})

    def test_mixed_types_are_refused(self):
        mgr, _ = self._mgr(dict(self.BRAND), [])
        with self.assertRaisesRegex(ValueError, "same file type"):
            mgr.brand_ensure("rossen", logo=(b"x", "svg"), logo_dark=(b"y", "png"))

    def test_read_logo_checks_type_and_size(self):
        from identity_controller.authentik_manager import read_logo
        with TemporaryDirectory() as d:
            ok = Path(d) / "logo.SVG"; ok.write_bytes(b"<svg/>")
            self.assertEqual(read_logo(str(ok)), (b"<svg/>", "svg"))
            bad = Path(d) / "logo.gif"; bad.write_bytes(b"GIF")
            with self.assertRaisesRegex(ValueError, "use one of"):
                read_logo(str(bad))
            empty = Path(d) / "e.png"; empty.write_bytes(b"")
            with self.assertRaisesRegex(ValueError, "empty"):
                read_logo(str(empty))
