"""A declared aliasType change is applied in place (#660).

Run with:
    cd src && python -m unittest test.test_alias_retype -v
"""

from __future__ import annotations

import contextlib
import io
import unittest
from pathlib import Path
from unittest.mock import MagicMock

from opnsense_controller.config import Config
from opnsense_controller.rules_manager import RulesManager


class _Client:
    """OPNsense's alias API, as far as the upsert reads and writes it."""

    def __init__(self, stored: dict[str, str], set_result="saved"):
        self.stored = stored                     # name -> type
        self.calls: list[tuple[str, dict]] = []
        self.set_result = set_result

    def run_module(self, name, params=None, **_):
        self.calls.append((name, params))
        if name != "raw":
            return {"changed": True}
        cmd = params["command"]
        if cmd.startswith("getAliasUUID/"):
            n = cmd.split("/", 1)[1]
            resp = {"uuid": f"u-{n}"} if n in self.stored else []
        elif cmd.startswith("getItem/"):
            n = cmd.split("/", 1)[1][2:]
            resp = {"alias": {"type": {t: {"value": t, "selected": int(t == self.stored[n])}
                                       for t in ("host", "network", "port")}}}
        elif cmd.startswith("setItem/"):
            resp = {"result": self.set_result}
        else:
            resp = {}
        return {"result": {"response": resp}}


def _mgr(client):
    m = RulesManager(Config(firewall="example.invalid", ssl_verify=False), {},
                     modules_dir=Path("/tmp"), sequence_map_file=None)
    m._fw = MagicMock()
    m._fw.client = client
    return m


def _upsert(m, *a):
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        m._upsert_alias(*a)


class TestRetype(unittest.TestCase):
    def test_a_changed_type_is_set_in_place(self):
        c = _Client({"tm_cams": "host"})
        _upsert(_mgr(c), "tm_cams", "network", ["10.4.30.0/24"], "cams")
        sets = [p for n, p in c.calls if n == "raw" and p["command"].startswith("setItem/")]
        self.assertEqual(len(sets), 1)
        self.assertEqual(sets[0]["command"], "setItem/u-tm_cams")
        self.assertEqual(sets[0]["data"]["alias"]["type"], "network")
        self.assertEqual(sets[0]["data"]["alias"]["content"], "10.4.30.0/24")
        self.assertFalse([n for n, _ in c.calls if n == "alias"])     # not the refusing module

    def test_the_same_type_uses_the_upsert(self):
        c = _Client({"tm_app": "host"})
        _upsert(_mgr(c), "tm_app", "host", ["app.rossen.internal"], "app")
        self.assertEqual([n for n, _ in c.calls if n == "alias"], ["alias"])
        self.assertFalse([p for n, p in c.calls if n == "raw" and p["command"].startswith("setItem/")])

    def test_a_new_alias_uses_the_upsert(self):
        c = _Client({})
        _upsert(_mgr(c), "tm_new", "host", ["new.rossen.internal"], "new")
        self.assertEqual([n for n, _ in c.calls if n == "alias"], ["alias"])

    def test_a_refused_change_is_an_error_naming_the_alias(self):
        c = _Client({"tm_cams": "host"}, set_result="failed")
        with self.assertRaisesRegex(RuntimeError, "alias tm_cams: changing its type to network"):
            _upsert(_mgr(c), "tm_cams", "network", ["10.4.30.0/24"], "cams")

    def test_an_unreadable_alias_falls_back_to_the_upsert(self):
        m = _mgr(MagicMock())                 # answers nothing usable
        _upsert(m, "tm_x", "host", ["x"], "x")
        names = [c.args[0] for c in m._fw.client.run_module.call_args_list]
        self.assertEqual(names[-1], "alias")


if __name__ == "__main__":
    unittest.main()
