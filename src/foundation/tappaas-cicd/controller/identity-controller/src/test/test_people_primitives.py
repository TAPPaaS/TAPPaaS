"""LIVE, self-cleaning tests for the People PRIMITIVES (S2b-2).

These run against the REAL Authentik on the identity VM (creds from
``~/.authentik-credentials.txt``). They SKIP gracefully — never fail — when
Authentik or the credentials are unreachable.

Safety contract (non-negotiable):
  * EVERY entity created here uses the ``zztest-`` name prefix, so it can never
    collide with a real user/group/role.
  * EVERY created entity is torn down via ``addCleanup`` — even on failure.
  * The tests NEVER create/modify/delete any entity whose name is not
    ``zztest-``-prefixed; assertions that scan all entities filter to the
    prefix before touching anything.
"""

from __future__ import annotations

import os
import unittest
from pathlib import Path

import httpx

from identity_controller import people_primitives as pp
from identity_controller.authentik_cli import DEFAULT_CRED_FILE, _read_creds
from identity_controller.authentik_manager import AuthentikConfig, AuthentikManager


PREFIX = "zztest-"


def _live_manager() -> AuthentikManager | None:
    """Return a connected manager, or None if Authentik/creds are unreachable."""
    path = DEFAULT_CRED_FILE
    if not Path(path).is_file():
        return None
    try:
        url, token = _read_creds(Path(path))
    except SystemExit:
        return None
    mgr = AuthentikManager(AuthentikConfig(base_url=url, token=token, timeout=8.0))
    try:
        mgr.connect()
        if not mgr.test_connection():
            mgr.disconnect()
            return None
    except (httpx.HTTPError, OSError):
        return None
    return mgr


# FAST/DEEP split: these tests mutate the live Authentik, so they run ONLY when
# TAPPAAS_TEST_DEEP=1. The `not _DEEP` short-circuit means fast mode never even
# opens a connection (keeps the default suite fast + non-disruptive).
_DEEP = os.environ.get("TAPPAAS_TEST_DEEP", "0") == "1"


@unittest.skipIf(not _DEEP or _live_manager() is None,
                 "live tests run only with TAPPAAS_TEST_DEEP=1 against a reachable Authentik")
class TestPeoplePrimitivesLive(unittest.TestCase):
    """Exercise the primitives end-to-end against the live Authentik."""

    @classmethod
    def setUpClass(cls):
        cls.mgr = _live_manager()
        assert cls.mgr is not None

    @classmethod
    def tearDownClass(cls):
        if cls.mgr is not None:
            cls.mgr.disconnect()

    # ── helpers ──────────────────────────────────────────────────────────

    def _cleanup_user(self, name: str) -> None:
        assert name.startswith(PREFIX), f"refusing to delete non-test user {name!r}"
        try:
            pp.delete_user(self.mgr, name)
        except httpx.HTTPError:
            pass

    def _cleanup_group(self, name: str) -> None:
        assert name.startswith(PREFIX), f"refusing to delete non-test group {name!r}"
        g = self.mgr.group_get(name)
        if g:
            try:
                self.mgr._delete(f"/core/groups/{g['pk']}/")  # noqa: SLF001
            except httpx.HTTPError:
                pass

    # ── tests ──────────────────────────────────────────────────────────────

    def test_ensure_user_creates_then_noop(self):
        name = f"{PREFIX}user-a"
        self.addCleanup(self._cleanup_user, name)

        u1 = pp.ensure_user(self.mgr, name=name, email="a@zztest.invalid", display="ZZ A")
        self.assertEqual(u1["name"], name)
        self.assertTrue(u1["active"])
        self.assertEqual(u1["email"], "a@zztest.invalid")

        # Second call: still present, no duplicate (user_get returns the one row).
        u2 = pp.ensure_user(self.mgr, name=name, email="a@zztest.invalid", display="ZZ A")
        self.assertEqual(u2["name"], name)
        matches = [u for u in pp.list_users(self.mgr) if u["name"] == name]
        self.assertEqual(len(matches), 1, "ensure-user must not create duplicates")

    def test_ensure_user_inactive_and_disable(self):
        name = f"{PREFIX}user-b"
        self.addCleanup(self._cleanup_user, name)

        u = pp.ensure_user(self.mgr, name=name, email="b@zztest.invalid",
                           display="ZZ B", inactive=True)
        self.assertFalse(u["active"], "ensure-user --inactive must create inactive")

        # ensure-user (active) must flip the flag back on (the one field it owns).
        u = pp.ensure_user(self.mgr, name=name, email="b@zztest.invalid", display="ZZ B")
        self.assertTrue(u["active"])

        # disable-user → inactive, idempotent on a second call.
        u = pp.disable_user(self.mgr, name)
        self.assertFalse(u["active"])
        u = pp.disable_user(self.mgr, name)
        self.assertFalse(u["active"])

    def test_ensure_group_and_membership(self):
        gname = f"{PREFIX}group-c"
        uname = f"{PREFIX}user-c"
        self.addCleanup(self._cleanup_group, gname)
        self.addCleanup(self._cleanup_user, uname)

        g = pp.ensure_group(self.mgr, name=gname, display="ZZ Group C")
        self.assertEqual(g["name"], gname)
        self.assertEqual(g["displayName"], "ZZ Group C")
        # Idempotent.
        g2 = pp.ensure_group(self.mgr, name=gname, display="ZZ Group C")
        self.assertEqual(g2["name"], gname)
        # A role-marked group must NOT appear in list-groups.
        self.assertIn(gname, [x["name"] for x in pp.list_groups(self.mgr)])
        self.assertNotIn(gname, [x["name"] for x in pp.list_roles(self.mgr)])

        pp.ensure_user(self.mgr, name=uname, email="c@zztest.invalid", display="ZZ C")

        # add-member → list-users shows membership.
        pp.add_member(self.mgr, user=uname, group=gname)
        u = pp.get_user(self.mgr, uname)
        self.assertIn(gname, u["groups"])
        self.assertNotIn(gname, u["roles"])
        # Idempotent add.
        pp.add_member(self.mgr, user=uname, group=gname)
        self.assertEqual(pp.get_user(self.mgr, uname)["groups"].count(gname), 1)

        # remove-member → gone.
        pp.remove_member(self.mgr, user=uname, group=gname)
        self.assertNotIn(gname, pp.get_user(self.mgr, uname)["groups"])
        # Idempotent remove.
        pp.remove_member(self.mgr, user=uname, group=gname)

    def test_ensure_role_assign_unassign(self):
        rname = f"{PREFIX}role-d"
        uname = f"{PREFIX}user-d"
        self.addCleanup(self._cleanup_group, rname)
        self.addCleanup(self._cleanup_user, uname)

        r = pp.ensure_role(self.mgr, name=rname, display="ZZ Role D")
        self.assertEqual(r["name"], rname)
        # A role appears in list-roles, NOT in list-groups.
        self.assertIn(rname, [x["name"] for x in pp.list_roles(self.mgr)])
        self.assertNotIn(rname, [x["name"] for x in pp.list_groups(self.mgr)])

        pp.ensure_user(self.mgr, name=uname, email="d@zztest.invalid", display="ZZ D")

        pp.assign_role(self.mgr, user=uname, role=rname)
        u = pp.get_user(self.mgr, uname)
        self.assertIn(rname, u["roles"])
        self.assertNotIn(rname, u["groups"])  # role-marked → not counted as a group
        # Idempotent assign.
        pp.assign_role(self.mgr, user=uname, role=rname)
        self.assertEqual(pp.get_user(self.mgr, uname)["roles"].count(rname), 1)

        pp.unassign_role(self.mgr, user=uname, role=rname)
        self.assertNotIn(rname, pp.get_user(self.mgr, uname)["roles"])
        # Idempotent unassign.
        pp.unassign_role(self.mgr, user=uname, role=rname)

    def test_delete_user_removes_and_is_idempotent(self):
        name = f"{PREFIX}user-e"
        self.addCleanup(self._cleanup_user, name)

        pp.ensure_user(self.mgr, name=name, email="e@zztest.invalid", display="ZZ E")
        self.assertIsNotNone(pp.get_user(self.mgr, name))

        self.assertTrue(pp.delete_user(self.mgr, name))
        self.assertIsNone(pp.get_user(self.mgr, name))
        # Idempotent: second delete is a no-op returning False.
        self.assertFalse(pp.delete_user(self.mgr, name))

    def test_lists_return_arrays(self):
        self.assertIsInstance(pp.list_users(self.mgr), list)
        self.assertIsInstance(pp.list_groups(self.mgr), list)
        self.assertIsInstance(pp.list_roles(self.mgr), list)


if __name__ == "__main__":
    unittest.main()
