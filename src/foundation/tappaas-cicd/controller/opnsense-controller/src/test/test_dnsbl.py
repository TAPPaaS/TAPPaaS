"""DNS blocklists from site.json (#157).

Run with:
    cd src && python -m unittest test.test_dnsbl -v
"""

from __future__ import annotations

import unittest

from opnsense_controller.dnsbl_plan import DESCRIPTION, DnsblError, current_view, desired, is_ours, needs_change

KNOWN = {"atf", "hgz011", "oisd1", "ag"}
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
        d = desired(site(lists=["hgz011", "atf"], zones=["home"], allow=["example.org"]), ZONES, KNOWN, v6)
        self.assertEqual(d.lists, ["atf", "hgz011"])
        self.assertEqual(d.source_nets, ["10.3.10.0/24", "2001:db8:31::/64"])
        items = d.items()
        # OPNsense: one entry's networks share a family and a prefix length.
        self.assertEqual(sorted(items), [f"{DESCRIPTION} (IPv4 /24)", f"{DESCRIPTION} (IPv6 /64)"])
        v4 = items[f"{DESCRIPTION} (IPv4 /24)"]
        self.assertEqual(v4["source_nets"], "10.3.10.0/24")
        self.assertEqual((v4["nxdomain"], v4["allowlists"], v4["type"]), ("1", "example.org", "atf,hgz011"))
        self.assertTrue(all(is_ours(k) for k in items) and not is_ours("my list"))

    def test_no_zones_filters_every_client(self):
        d = desired(site(lists=["atf"]), ZONES, KNOWN, v6)
        self.assertEqual(list(d.items()), [DESCRIPTION])
        self.assertEqual(d.items()[DESCRIPTION]["source_nets"], "")

    def test_an_inactive_zone_is_a_warning(self):
        d = desired(site(lists=["atf"], zones=["guest"]), ZONES, KNOWN, v6)
        self.assertTrue(any("guest" in w for w in d.warnings))

    def test_refusals(self):
        with self.assertRaisesRegex(DnsblError, "unknown blocklist.*nope"):
            desired(site(lists=["nope"]), ZONES, KNOWN, v6)
        with self.assertRaisesRegex(DnsblError, "zone 'nowhere'"):
            desired(site(lists=["atf"], zones=["nowhere"]), ZONES, KNOWN, v6)
        with self.assertRaises(DnsblError):
            desired({"dnsBlocklists": ["atf"]}, ZONES, KNOWN, v6)


class TestCompare(unittest.TestCase):
    def have(self, types=("atf",), nets=("10.3.10.0/24",), allow=(), nx="1", enabled="1"):
        opt = lambda keys, all_=(): {k: {"value": k, "selected": int(k in keys)} for k in set(all_) | set(keys) | {""}}
        return {"enabled": enabled, "type": opt(types, KNOWN), "source_nets": opt(nets),
                "allowlists": opt(allow), "nxdomain": nx}

    def item(self):
        return list(desired(site(lists=["atf"], zones=["rossen"]), ZONES, KNOWN, v6).items().values())[0]

    def test_matching_entry_needs_nothing(self):
        self.assertFalse(needs_change(self.item(), self.have(nets=("10.2.0.0/24",))))

    def test_any_difference_is_a_change(self):
        i = self.item()
        self.assertTrue(needs_change(i, self.have(nets=("10.3.10.0/24",))))
        self.assertTrue(needs_change(i, self.have(types=("atf", "ag"), nets=("10.2.0.0/24",))))
        self.assertTrue(needs_change(i, self.have(nets=("10.2.0.0/24",), nx="0")))
        self.assertTrue(needs_change(i, self.have(nets=("10.2.0.0/24",), enabled="0")))

    def test_empty_selected_key_is_not_a_value(self):
        self.assertEqual(current_view(self.have(nets=()))["source_nets"], [])


if __name__ == "__main__":
    unittest.main()
