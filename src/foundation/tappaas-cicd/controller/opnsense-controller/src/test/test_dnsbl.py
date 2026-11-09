"""DNS blocklists from site.json (#157).

Run with:
    cd src && python -m unittest test.test_dnsbl -v
"""

from __future__ import annotations

import unittest

import contextlib
import io
from types import SimpleNamespace
from unittest import mock

from opnsense_controller import unbound_cli
from opnsense_controller.dnsbl_plan import (CRON_DESCRIPTION, DESCRIPTION, DnsblError, cron_job, cron_plan,
                                            current_view, desired, is_ours, needs_change)

KNOWN = {"hgz011", "hgz012", "hgz013", "oisd1", "ag"}
ZONES = {
    "home": {"ip": "10.3.10.0/24", "state": "Active"},
    "guest": {"ip": "10.5.10.0/24", "state": "Inactive"},
    "rossen": {"ip": "10.2.0.0/24", "state": "Active"},
}


def v6(cidr):
    return [cidr] + ({"10.3.10.0/24": ["2001:db8:31::/64"]}.get(cidr, []))


def site(**bl):
    return {"dnsBlocklists": bl} if bl else {}


class TestDesired(unittest.TestCase):
    def test_absent_or_empty_means_none(self):
        self.assertIsNone(desired({}, ZONES, KNOWN, v6))
        self.assertIsNone(desired(site(lists=[]), ZONES, KNOWN, v6))

    def test_zones_become_both_families(self):
        d = desired(site(lists=["hgz011", "hgz012"], zones=["home"], allow=["example.org"]), ZONES, KNOWN, v6)
        self.assertEqual(d.lists, ["hgz011", "hgz012"])
        self.assertEqual(d.source_nets, ["10.3.10.0/24", "2001:db8:31::/64"])
        items = d.items()
        # OPNsense: one entry's networks share a family and a prefix length.
        self.assertEqual(sorted(items), [f"{DESCRIPTION} (IPv4 /24)", f"{DESCRIPTION} (IPv6 /64)"])
        v4 = items[f"{DESCRIPTION} (IPv4 /24)"]
        self.assertEqual(v4["source_nets"], "10.3.10.0/24")
        self.assertEqual((v4["nxdomain"], v4["allowlists"], v4["type"]), ("1", "example.org", "hgz011,hgz012"))
        self.assertTrue(all(is_ours(k) for k in items) and not is_ours("my list"))

    def test_no_zones_filters_every_client(self):
        d = desired(site(lists=["hgz012"]), ZONES, KNOWN, v6)
        self.assertEqual(list(d.items()), [DESCRIPTION])
        self.assertEqual(d.items()[DESCRIPTION]["source_nets"], "")

    def test_an_inactive_zone_is_a_warning(self):
        d = desired(site(lists=["hgz012"], zones=["guest"]), ZONES, KNOWN, v6)
        self.assertTrue(any("guest" in w for w in d.warnings))

    def test_an_unknown_code_is_skipped_with_a_warning(self):
        # OPNsense dropped ThreatFox (atf) from its catalogue in 26.7.8 (#923).
        d = desired(site(lists=["atf", "hgz011"]), ZONES, KNOWN, v6)
        self.assertEqual(d.lists, ["hgz011"])
        self.assertTrue(any("skipped atf" in w for w in d.warnings))

    def test_refusals(self):
        # Nothing left to apply: refused, so the entry on the firewall stays.
        with self.assertRaisesRegex(DnsblError, "none of the blocklists nope"):
            desired(site(lists=["nope"]), ZONES, KNOWN, v6)
        with self.assertRaisesRegex(DnsblError, "zone 'nowhere'"):
            desired(site(lists=["hgz012"], zones=["nowhere"]), ZONES, KNOWN, v6)
        with self.assertRaises(DnsblError):
            desired({"dnsBlocklists": ["hgz012"]}, ZONES, KNOWN, v6)


class TestCompare(unittest.TestCase):
    def have(self, types=("hgz012",), nets=("10.3.10.0/24",), allow=(), nx="1", enabled="1"):
        opt = lambda keys, all_=(): {k: {"value": k, "selected": int(k in keys)} for k in set(all_) | set(keys) | {""}}
        return {"enabled": enabled, "type": opt(types, KNOWN), "source_nets": opt(nets),
                "allowlists": opt(allow), "nxdomain": nx}

    def item(self):
        return list(desired(site(lists=["hgz012"], zones=["rossen"]), ZONES, KNOWN, v6).items().values())[0]

    def test_matching_entry_needs_nothing(self):
        self.assertFalse(needs_change(self.item(), self.have(nets=("10.2.0.0/24",))))

    def test_any_difference_is_a_change(self):
        i = self.item()
        self.assertTrue(needs_change(i, self.have(nets=("10.3.10.0/24",))))
        self.assertTrue(needs_change(i, self.have(types=("hgz012", "ag"), nets=("10.2.0.0/24",))))
        self.assertTrue(needs_change(i, self.have(nets=("10.2.0.0/24",), nx="0")))
        self.assertTrue(needs_change(i, self.have(nets=("10.2.0.0/24",), enabled="0")))

    def test_empty_selected_key_is_not_a_value(self):
        self.assertEqual(current_view(self.have(nets=()))["source_nets"], [])


def job(desc=CRON_DESCRIPTION, uuid="u1", **kw):
    j = {**cron_job(), "uuid": uuid, "description": desc}
    j.update(kw)
    return j


class TestCronPlan(unittest.TestCase):
    def test_wanted_and_absent_is_added(self):
        self.assertEqual(cron_plan([], True), (True, []))

    def test_wanted_and_present_needs_nothing(self):
        self.assertEqual(cron_plan([job()], True), (False, []))

    def test_unwanted_ours_is_removed_and_others_left(self):
        other = job(desc="nightly reboot", uuid="x", command="system reboot")
        self.assertEqual(cron_plan([job(), other], False), (False, ["u1"]))

    def test_an_operators_refresh_job_replaces_ours(self):
        mine = job(desc="my dnsbl refresh", uuid="op", command="Update Unbound DNSBLs", hours="2")
        self.assertEqual(cron_plan([mine], True), (False, []))
        self.assertEqual(cron_plan([mine, job()], True), (False, ["u1"]))

    def test_a_row_as_opnsense_returns_it(self):
        # searchJobs on OPNsense 26.1 (hrossen): the field is `minutes`, and the
        # command comes back as the key with its label beside it.
        row = {"uuid": "99a4", "origin": "cron", "enabled": "1", "minutes": "17", "hours": "4", "days": "*",
               "months": "*", "weekdays": "*", "who": "root", "command": "unbound dnsbl",
               "%command": "Update Unbound DNSBLs", "parameters": "", "description": CRON_DESCRIPTION}
        self.assertEqual(cron_plan([row], True), (False, []))
        self.assertEqual(cron_plan([{**row, "minutes": "0"}], True), (True, ["99a4"]))
        self.assertIn("minutes", cron_job())

    def test_a_disabled_or_rescheduled_job_of_ours_is_replaced(self):
        self.assertEqual(cron_plan([job(enabled="0")], True), (True, ["u1"]))
        self.assertEqual(cron_plan([job(hours="5")], True), (True, ["u1"]))
        self.assertEqual(cron_plan([job(), job(uuid="u2")], True), (False, ["u2"]))


class FakeFirewall:
    """Unbound's DNSBL entries and the cron jobs, as the API serves them."""

    def __init__(self, entries=(), jobs=()):
        self.entries, self.jobs, self.calls = list(entries), list(jobs), []

    def unbound(self, mgr, controller, command, action, data=None, params=None):
        self.calls.append(command)
        if command == "searchDnsbl":
            return {"rows": self.entries}
        if command == "getDnsbl":
            if not params:
                return {"blocklist": {"type": {k: {"selected": 0} for k in KNOWN}}}
            e = next(x for x in self.entries if x["uuid"] == params[0])
            opt = lambda csv: {k: {"value": k, "selected": 1} for k in str(csv or "").split(",") if k}  # noqa: E731
            return {"blocklist": {"enabled": e.get("enabled", "1"), "type": opt(e.get("type")),
                                  "allowlists": opt(e.get("allowlists")), "source_nets": opt(e.get("source_nets")),
                                  "nxdomain": e.get("nxdomain", "")}}
        if command == "setDnsbl":
            e = next(x for x in self.entries if x["uuid"] == params[0])
            e.update(data["blocklist"])
            return {"result": "saved"}
        if command == "addDnsbl":
            self.entries.append({**data["blocklist"], "uuid": f"e{len(self.entries)}"})
            return {"result": "saved"}
        if command == "delDnsbl":
            self.entries = [e for e in self.entries if e["uuid"] != params[0]]
            return {"result": "deleted"}
        return {"status": "ok"}

    def cron(self, mgr, command, action, data=None, params=None):
        self.calls.append(command)
        if command == "searchJobs":
            return {"rows": self.jobs}
        if command == "addJob":
            self.jobs.append({**data["job"], "uuid": f"j{len(self.jobs)}"})
            return {"result": "saved"}
        if command == "delJob":
            self.jobs = [j for j in self.jobs if j["uuid"] != params[0]]
            return {"result": "deleted"}
        return {}


class TestDnsblCommand(unittest.TestCase):
    def run_it(self, fw, decl, check_mode=False, settle=0, settled=True):
        args = SimpleNamespace(config_dir="/nowhere", check_mode=check_mode, firewall="fw", settle=settle)
        mgr = SimpleNamespace(client=mock.Mock())

        @contextlib.contextmanager
        def client(_):
            yield mgr
        out = io.StringIO()
        with mock.patch.object(unbound_cli, "_unbound_api", fw.unbound), \
                mock.patch.object(unbound_cli, "_cron_api", fw.cron), \
                mock.patch.object(unbound_cli, "_client", client), \
                mock.patch.object(unbound_cli, "_verify_resolver_after_write", return_value=True), \
                mock.patch.object(unbound_cli, "check_unbound_dns", return_value=settled), \
                mock.patch("time.sleep") as slept, \
                mock.patch("opnsense_controller.dual_stack.read_interfaces", return_value={}), \
                mock.patch("opnsense_controller.ipv6_cli.load_site_and_zones",
                           return_value=(site(**decl), ZONES)), \
                contextlib.redirect_stdout(out):
            ok = unbound_cli.dnsbl(args)
        self.slept = slept
        return ok, out.getvalue()

    def test_a_blocklist_brings_the_daily_refresh(self):
        fw = FakeFirewall()
        ok, out = self.run_it(fw, {"lists": ["hgz011"]})
        self.assertTrue(ok)
        self.assertEqual([j["command"] for j in fw.jobs], ["unbound dnsbl"])
        self.assertIn("refresh the lists daily", out)

    def test_no_blocklists_removes_only_our_refresh(self):
        fw = FakeFirewall(entries=[{"uuid": "e0", "description": DESCRIPTION, "enabled": "1"}],
                          jobs=[job(uuid="j0"), job(desc="backup", uuid="j1", command="system backup")])
        ok, out = self.run_it(fw, {})
        self.assertTrue(ok)
        self.assertEqual(fw.entries, [])
        self.assertEqual([j["uuid"] for j in fw.jobs], ["j1"])

    def test_a_hand_made_entry_keeps_the_refresh(self):
        fw = FakeFirewall(entries=[{"uuid": "h", "description": "my own list", "enabled": "1"}])
        ok, _ = self.run_it(fw, {})
        self.assertTrue(ok)
        self.assertEqual(len(fw.jobs), 1)

    def test_a_resolver_that_dies_later_loses_the_lists(self):
        # A list too big for the firewall: Unbound answers, loads it, and is
        # killed minutes later. The entries go again, the site keeps DNS.
        fw = FakeFirewall()
        ok, _ = self.run_it(fw, {"lists": ["hgz011"]}, settle=300, settled=False)
        self.assertFalse(ok)
        self.slept.assert_called_once_with(300)
        self.assertEqual((fw.entries, fw.jobs), ([], []))

    def test_a_resolver_that_holds_keeps_them(self):
        fw = FakeFirewall()
        ok, _ = self.run_it(fw, {"lists": ["hgz013"]}, settle=300, settled=True)
        self.assertTrue(ok)
        self.assertEqual(len(fw.entries), 1)
        ok, _ = self.run_it(fw, {"lists": ["hgz013"]}, settle=300, settled=True)
        self.slept.assert_not_called()  # nothing changed: no wait

    def test_check_mode_writes_nothing(self):
        fw = FakeFirewall()
        ok, out = self.run_it(fw, {"lists": ["hgz011"]}, check_mode=True)
        self.assertTrue(ok)
        self.assertEqual((fw.entries, fw.jobs), ([], []))
        self.assertIn("would refresh the lists daily", out)


if __name__ == "__main__":
    unittest.main()
