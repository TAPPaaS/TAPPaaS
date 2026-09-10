"""Unit tests for snat_policy — the source-NAT zone gate (ADR-016 D1/D2).

Covers the whole decision without touching OPNsense: what a module may
masquerade is arithmetic over zones.json and the module's own config, and the
answer must not depend on a firewall being reachable.

The refusal cases carry the weight here. #239 stayed broken for weeks because
a request that could not work reported success, so a test that only proved the
happy path would have proved nothing.

Run with:
    cd src && python -m unittest test.test_snat_policy -v
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from opnsense_controller.snat_policy import (
    DESC_PREFIX,
    reaches,
    SnatRequest,
    ZoneSpec,
    apply_gate,
    load_request,
    load_zones,
    rule_description,
    validate_zone_gate,
)


def zone(name, ip, *, vlan=0, access=None, pinhole=None, snat=None) -> ZoneSpec:
    return ZoneSpec(
        name=name,
        ip_network=ip,
        bridge="lan",
        vlan_tag=vlan,
        access_to=list(access or []),
        pinhole_allowed_from=list(pinhole or []),
        snat_allowed_from=list(snat or []),
    )


def zones_fixture(*, snat_allowed=("home",), pinhole_allowed=("home", "srvHome")):
    return {
        "home": zone("home", "10.3.10.0/24", vlan=310),
        "srvHome": zone("srvHome", "10.2.10.0/24", vlan=210),
        "iotCloud": zone(
            "iotCloud",
            "10.4.20.0/24",
            vlan=420,
            pinhole=pinhole_allowed,
            snat=snat_allowed,
        ),
    }


class TestApplyGate(unittest.TestCase):
    """R2/R3: what the zone grants, and what happens when it does not."""

    def test_granted_zone_is_allowed(self):
        req = SnatRequest("alfen", "iotCloud", ["home"], "firmware rejects outside /24")
        result = apply_gate(req, zones_fixture())
        self.assertTrue(result.ok)
        self.assertEqual(result.allowed, ["home"])
        self.assertEqual(result.refused, [])

    def test_absent_gate_refuses_everything(self):
        """R2 — a zone with no snat-allowed-from is not a zone that consents."""
        req = SnatRequest("alfen", "iotCloud", ["home"], "why")
        result = apply_gate(req, zones_fixture(snat_allowed=()))
        self.assertFalse(result.ok)
        self.assertEqual(result.refused, ["home"])
        self.assertEqual(result.allowed, [])

    def test_partial_grant_is_refused_not_trimmed(self):
        """R3 — the whole request fails; a half-applied masquerade is not success.

        This is the #239 shape: srvHome is ungranted, and narrowing the request
        to the granted half would install a rule, report success, and leave the
        charger unreachable from srvHome with nothing saying so.
        """
        req = SnatRequest("alfen", "iotCloud", ["home", "srvHome"], "why")
        result = apply_gate(req, zones_fixture(snat_allowed=("home",)))
        self.assertFalse(result.ok)
        self.assertEqual(result.refused, ["srvHome"])
        self.assertTrue(any("refused, not trimmed" in e for e in result.errors))

    def test_empty_request_is_a_noop_not_an_error(self):
        """A module may carry the dependency before it asks for anything."""
        result = apply_gate(SnatRequest("alfen", "iotCloud", [], ""), zones_fixture())
        self.assertTrue(result.ok)
        self.assertEqual(result.allowed, [])

    def test_reason_is_required_when_requesting(self):
        req = SnatRequest("alfen", "iotCloud", ["home"], "")
        result = apply_gate(req, zones_fixture())
        self.assertFalse(result.ok)
        self.assertTrue(any("snatReason" in e for e in result.errors))

    def test_self_masquerade_refused(self):
        req = SnatRequest("alfen", "iotCloud", ["iotCloud"], "why")
        result = apply_gate(req, zones_fixture(snat_allowed=("iotCloud",)))
        self.assertFalse(result.ok)
        self.assertTrue(any("into itself" in e for e in result.errors))

    def test_unknown_source_zone_is_an_error(self):
        req = SnatRequest("alfen", "iotCloud", ["nosuchzone"], "why")
        result = apply_gate(req, zones_fixture())
        self.assertFalse(result.ok)
        self.assertTrue(any("nosuchzone" in e for e in result.errors))

    def test_unknown_destination_zone_is_an_error(self):
        req = SnatRequest("alfen", "nosuchzone", ["home"], "why")
        result = apply_gate(req, zones_fixture())
        self.assertFalse(result.ok)
        self.assertTrue(any("not a zone" in e for e in result.errors))

    def test_missing_zone0_is_an_error(self):
        result = apply_gate(SnatRequest("alfen", "", ["home"], "why"), zones_fixture())
        self.assertFalse(result.ok)
        self.assertTrue(any("no zone0" in e for e in result.errors))

    def test_zone_without_subnet_is_an_error(self):
        zones = zones_fixture()
        zones["home"] = zone("home", "", vlan=310)
        req = SnatRequest("alfen", "iotCloud", ["home"], "why")
        result = apply_gate(req, zones)
        self.assertFalse(result.ok)
        self.assertTrue(any("no 'ip' subnet" in e for e in result.errors))


class TestValidateZoneGate(unittest.TestCase):
    """R1: snat-allowed-from must be a subset of pinhole-allowed-from."""

    def test_subset_is_clean(self):
        zones = zones_fixture(snat_allowed=("home",), pinhole_allowed=("home", "srvHome"))
        self.assertEqual(validate_zone_gate(zones), [])

    def test_source_with_neither_edge_nor_hole_is_a_violation(self):
        """Was 'snat wider than pinhole'. The pinhole is no longer the whole
        test — the fixture's zones carry no access-to, so this still fails, but
        now for the right reason (#629)."""
        zones = zones_fixture(snat_allowed=("home", "srvHome"), pinhole_allowed=("home",))
        problems = validate_zone_gate(zones)
        self.assertEqual(len(problems), 1)
        self.assertIn("R1", problems[0])
        self.assertIn("srvHome", problems[0])

    def test_gate_naming_unknown_zone_is_a_violation(self):
        zones = zones_fixture(snat_allowed=("ghost",), pinhole_allowed=("ghost",))
        problems = validate_zone_gate(zones)
        self.assertTrue(any("not a zone" in p for p in problems))

    def test_zones_without_the_field_are_clean(self):
        """R2 again, from the file's side: absent means absent, not invalid."""
        self.assertEqual(validate_zone_gate(zones_fixture(snat_allowed=())), [])


class TestReachability(unittest.TestCase):
    """R1's premise: reachable by an EDGE or by a HOLE, not the hole alone (#629)."""

    def test_edge_counts_as_reachability(self):
        src = zone("srvHome", "10.2.10.0/24", access=["internet", "iotCloud"])
        self.assertTrue(reaches(src, "iotCloud"))

    def test_wildcard_access_counts(self):
        """`all` is a wildcard pass; a zone told it may reach everything has not
        been told to skip this one (operator decision, #629)."""
        self.assertTrue(reaches(zone("mgmt", "10.0.0.0/24", access=["all"]), "iotCloud"))

    def test_internet_is_not_reachability_into_a_zone(self):
        src = zone("home", "10.3.10.0/24", access=["internet"])
        self.assertFalse(reaches(src, "iotCloud"))

    def test_no_edge_is_not_reachability(self):
        self.assertFalse(reaches(zone("guest", "10.5.10.0/24"), "iotCloud"))


class TestR1AcceptsEitherMechanism(unittest.TestCase):
    """The #629 regression: an access-to edge must satisfy R1 on its own."""

    def _zones(self, *, srv_access, iot_pinhole, iot_snat):
        return {
            "home": zone("home", "10.3.10.0/24"),
            "srvHome": zone("srvHome", "10.2.10.0/24", access=srv_access),
            "iotCloud": zone("iotCloud", "10.4.20.0/24",
                             pinhole=iot_pinhole, snat=iot_snat),
        }

    def test_edge_alone_satisfies_r1(self):
        """srvHome reaches iotCloud zone-wide, so it needs no redundant pinhole.

        This is the reported case: hassanova in srvHome already talks to the
        charger over the zone edge, and R1 refused the masquerade grant because
        srvHome was not ALSO in pinhole-allowed-from.
        """
        zones = self._zones(srv_access=["internet", "iotCloud"],
                            iot_pinhole=["home"], iot_snat=["home", "srvHome"])
        self.assertEqual(validate_zone_gate(zones), [])

    def test_pinhole_alone_still_satisfies_r1(self):
        zones = self._zones(srv_access=["internet"],
                            iot_pinhole=["home", "srvHome"], iot_snat=["srvHome"])
        self.assertEqual(validate_zone_gate(zones), [])

    def test_neither_mechanism_is_still_a_violation(self):
        """Widening R1 must not empty it: no edge and no hole is still refused."""
        zones = self._zones(srv_access=["internet"],
                            iot_pinhole=["home"], iot_snat=["srvHome"])
        problems = validate_zone_gate(zones)
        self.assertEqual(len(problems), 1)
        self.assertIn("cannot reach", problems[0])
        # The message must name BOTH remedies, or it just redirects the same
        # redundant-pinhole workaround the issue objected to.
        self.assertIn("access-to", problems[0])
        self.assertIn("pinhole-allowed-from", problems[0])

    def test_wildcard_access_satisfies_r1(self):
        zones = self._zones(srv_access=["all"],
                            iot_pinhole=["home"], iot_snat=["srvHome"])
        self.assertEqual(validate_zone_gate(zones), [])


class TestRuleDescription(unittest.TestCase):
    def test_canonical_form(self):
        self.assertEqual(
            rule_description("alfen", "home", "iotCloud"),
            "tappaas-snat:alfen:home->iotCloud",
        )

    def test_prefix_is_distinct_from_the_community_pattern(self):
        """The pre-ADR Community rules used 'tappaas-nat:' and are NOT adopted."""
        desc = rule_description("alfen", "home", "iotCloud")
        self.assertTrue(desc.startswith(DESC_PREFIX))
        self.assertFalse(desc.startswith("tappaas-nat:"))


class TestLoaders(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def _write(self, name, payload):
        path = self.dir / name
        path.write_text(json.dumps(payload))
        return path

    def test_load_zones_skips_documentation_keys(self):
        path = self._write(
            "zones.json",
            {
                "_README": {"anything": "here"},
                "home": {"ip": "10.3.10.0/24", "vlantag": 310},
                "iotCloud": {
                    "ip": "10.4.20.0/24",
                    "vlantag": 420,
                    "pinhole-allowed-from": ["home"],
                    "snat-allowed-from": ["home"],
                },
            },
        )
        zones = load_zones(path)
        self.assertNotIn("_README", zones)
        self.assertEqual(zones["iotCloud"].snat_allowed_from, ["home"])
        self.assertEqual(zones["home"].snat_allowed_from, [])

    def test_load_request_reads_pattern_a_nesting(self):
        self._write(
            "alfen.json",
            {
                "vmname": "alfen",
                "zone0": "iotCloud",
                "config": {
                    "network:snat": {
                        "snatFrom": ["home"],
                        "snatReason": "firmware rejects outside /24",
                    }
                },
            },
        )
        req = load_request(self.dir, "alfen")
        self.assertEqual(req.snat_from, ["home"])
        self.assertEqual(req.reason, "firmware rejects outside /24")

    def test_load_request_falls_back_to_top_level(self):
        self._write(
            "alfen.json",
            {
                "vmname": "alfen",
                "zone0": "iotCloud",
                "snatFrom": ["home"],
                "snatReason": "why",
            },
        )
        req = load_request(self.dir, "alfen")
        self.assertEqual(req.snat_from, ["home"])

    def test_load_request_defaults_to_empty(self):
        self._write("plain.json", {"vmname": "plain", "zone0": "srvHome"})
        req = load_request(self.dir, "plain")
        self.assertEqual(req.snat_from, [])
        self.assertEqual(req.reason, "")

    def test_missing_module_config_raises(self):
        with self.assertRaises(FileNotFoundError):
            load_request(self.dir, "absent")


if __name__ == "__main__":
    unittest.main()
