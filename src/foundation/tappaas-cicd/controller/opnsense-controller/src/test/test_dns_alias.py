"""Unit tests for CNAME aliases on dnsmasq host entries (ADR-012 §2.7, #612).

A name that must follow a Host (the PBS's backup.mgmt.internal follows the node
it runs on) is a CNAME on the Host's own entry. Asserted without OPNsense:
- a move takes the alias OFF the old Host before putting it ON the new one
  (OPNsense refuses a CNAME another entry still holds — found live);
- setting an alias already in place changes nothing;
- a target with no entry, and an alias that is itself a host entry, are refused;
- re-adding a Host through create_host keeps the CNAMEs it carries.

Run with:
    cd src && python -m unittest test.test_dns_alias -v
"""

from __future__ import annotations

import unittest
from unittest.mock import MagicMock

from opnsense_controller.dhcp_manager import DhcpHost, DhcpManager


def _sel(values):
    return {v: {"value": v, "selected": 1} for v in values} or {"": {"value": "", "selected": 1}}


def _make(hosts):
    """hosts: {uuid: {"host":…, "domain":…, "cnames":[…]}} — mutated by setHost."""
    calls = []

    def run_module(module, **kwargs):
        p = kwargs.get("params", {})
        cmd = p.get("command")
        calls.append((module, cmd, p))
        if cmd == "searchHost":
            rows = [{"uuid": u, "host": h["host"], "domain": h["domain"]} for u, h in hosts.items()]
            return {"result": {"response": {"rows": rows}}}
        if cmd == "getHost":
            h = hosts[p["params"][0]]
            return {"result": {"response": {"host": {"host": h["host"], "cnames": _sel(h["cnames"])}}}}
        if cmd == "setHost":
            u = p["params"][0]
            new = [c for c in p["data"]["host"]["cnames"].split(",") if c]
            for other, h in hosts.items():  # OPNsense's uniqueness check
                if other != u and set(new) & set(h["cnames"]):
                    return {"result": {"response": {"result": "failed", "validations": {"host.cnames": "in use"}}}}
            hosts[u]["cnames"] = new
            return {"result": {"response": {"result": "saved"}}}
        if cmd == "reconfigure":
            return {"result": {"response": {"status": "ok"}}}
        return {"result": {"changed": True}}

    m = DhcpManager(config=MagicMock())
    m._client = MagicMock()
    m._client.run_module.side_effect = run_module
    return m, calls


def _hosts():
    return {
        "u1": {"host": "tappaas1", "domain": "mgmt.internal", "cnames": []},
        "u3": {"host": "tappaas3", "domain": "mgmt.internal", "cnames": ["backup.mgmt.internal"]},
    }


class TestCnameAlias(unittest.TestCase):
    def test_move_removes_before_adding(self):
        hosts = _hosts()
        m, calls = _make(hosts)
        r = m.set_cname("backup.mgmt.internal", "tappaas1", "mgmt.internal")
        self.assertTrue(r["changed"])
        self.assertEqual(hosts["u3"]["cnames"], [])
        self.assertEqual(hosts["u1"]["cnames"], ["backup.mgmt.internal"])
        sets = [c[2]["params"][0] for c in calls if c[1] == "setHost"]
        self.assertEqual(sets, ["u3", "u1"], "old Host first, then the new one")

    def test_already_in_place_changes_nothing(self):
        hosts = _hosts()
        m, calls = _make(hosts)
        r = m.set_cname("backup.mgmt.internal", "tappaas3", "mgmt.internal")
        self.assertFalse(r["changed"])
        self.assertFalse([c for c in calls if c[1] in ("setHost", "reconfigure")])

    def test_target_without_entry_refused(self):
        m, _ = _make(_hosts())
        with self.assertRaisesRegex(RuntimeError, "no DNS host entry"):
            m.set_cname("backup.mgmt.internal", "ghost", "mgmt.internal")

    def test_alias_that_is_a_host_entry_refused(self):
        hosts = _hosts()
        hosts["u9"] = {"host": "backup", "domain": "mgmt.internal", "cnames": []}
        m, _ = _make(hosts)
        with self.assertRaisesRegex(RuntimeError, "A record"):
            m.set_cname("backup.mgmt.internal", "tappaas1", "mgmt.internal")

    def test_delete_and_list(self):
        hosts = _hosts()
        m, _ = _make(hosts)
        self.assertEqual([r["alias"] for r in m.list_cnames()], ["backup.mgmt.internal"])
        self.assertTrue(m.delete_cname("backup.mgmt.internal")["changed"])
        self.assertEqual(hosts["u3"]["cnames"], [])
        self.assertFalse(m.delete_cname("backup.mgmt.internal")["changed"])

    def test_readding_a_host_keeps_its_cnames(self):
        m, calls = _make(_hosts())
        m.create_host(DhcpHost(description="TAPPaaS node tappaas3", host="tappaas3",
                               ip=["10.0.0.12"], domain="mgmt.internal"))
        sent = [c[2] for c in calls if c[0] == "dnsmasq_host"][0]
        self.assertEqual(sent.get("cnames"), ["backup.mgmt.internal"])


if __name__ == "__main__":
    unittest.main()
