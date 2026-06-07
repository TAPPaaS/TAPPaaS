"""Unit tests for zone_manager's pinhole-allowed-from validator (issue #163).

Covers the pure-Python validator path — no OPNsense connection needed.

Run with:
    cd src && python -m unittest test.test_zone_manager -v
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from opnsense_controller.firewall_manager import (
    FirewallRuleInfo,
    RuleAction,
)
from opnsense_controller.zone_manager import (
    Zone,
    ValidationMessage,
    ZoneManager,
    _check_egress,
    discover_module_files,
    postflight_checks,
    preflight_checks,
    validate_pinhole_allowed_from,
)


# ─────────────────────────────────────────────────────────────────────────────
# Fixtures
# ─────────────────────────────────────────────────────────────────────────────


def _zone(
    name: str,
    *,
    access_to: list[str] | None = None,
    pinhole_allowed_from: list[str] | None = None,
) -> Zone:
    return Zone(
        name=name,
        zone_type="Service",
        state="Active",
        type_id="2",
        sub_id="10",
        vlan_tag=210,
        ip_network="10.2.10.0/24",
        bridge="lan",
        description=f"{name} zone",
        access_to=access_to or [],
        pinhole_allowed_from=pinhole_allowed_from or [],
    )


def _build_zones(**overrides) -> dict[str, Zone]:
    """Default 4-zone topology.

    - srv:        access-to=[internet, dmz], pinhole-allowed-from=[dmz, srv]
    - dmz:        access-to=[internet],      pinhole-allowed-from=[internet]
    - home:       access-to=[internet],      pinhole-allowed-from=[]
    - locked-srv: access-to=[internet],      pinhole-allowed-from=[]  (deliberately strict)

    `overrides` is a mapping of {zone_name: {attr_name: value}} to tweak any
    field on a per-test basis.
    """
    zones = {
        "srv": _zone("srv", access_to=["internet", "dmz"],
                    pinhole_allowed_from=["dmz", "srv"]),
        "dmz": _zone("dmz", access_to=["internet"],
                    pinhole_allowed_from=["internet"]),
        "home": _zone("home", access_to=["internet"],
                     pinhole_allowed_from=[]),
        "locked-srv": _zone("locked-srv", access_to=["internet"],
                            pinhole_allowed_from=[]),
    }
    for n, attrs in overrides.items():
        if n not in zones:
            continue
        for k, v in attrs.items():
            setattr(zones[n], k, v)
    return zones


def _write_module(dir_: Path, vmname: str, body: dict, location: str = "") -> Path:
    """Write a module.json into `dir_` with sensible defaults."""
    body = dict(body)
    body.setdefault("vmname", vmname)
    if location:
        body.setdefault("location", location)
    path = dir_ / f"{vmname}.json"
    path.write_text(json.dumps(body, indent=2))
    return path


# ─────────────────────────────────────────────────────────────────────────────
# Test cases
# ─────────────────────────────────────────────────────────────────────────────


class TestDiscoverModuleFiles(unittest.TestCase):
    """Discovery should skip well-known non-module JSONs and *.orig backups."""

    def test_skips_known_non_module_stems(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "configuration.json").write_text("{}")
            (d / "firewall.json").write_text("{}")
            (d / "zones.json").write_text("{}")
            (d / "aliases.json").write_text("{}")
            (d / "module-fields.json").write_text("{}")
            (d / "real-module.json").write_text("{}")
            stems = [p.stem for p in discover_module_files(d)]
            self.assertEqual(stems, ["real-module"])

    def test_skips_orig_backups(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "x.json").write_text("{}")
            (d / "x.json.orig").write_text("{}")
            stems = sorted(p.name for p in discover_module_files(d))
            self.assertEqual(stems, ["x.json"])

    def test_missing_dir_returns_empty(self):
        self.assertEqual(discover_module_files(Path("/nonexistent/xyz")), [])


class TestMatchingScenarios(unittest.TestCase):
    """Scenarios where the validator should emit NO warnings or errors."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.zones = _build_zones()

    def tearDown(self):
        self.tmp.cleanup()

    def test_ingress_from_zone_in_pinhole_allowed_from(self):
        """ingress.from='dmz' to a srv-zone module — dmz IS in srv.pinhole-allowed-from."""
        _write_module(self.dir, "vault", {
            "zone0": "srv",
            "ports": [{"port": 8080}],
            "ingress": [
                {"from": "dmz", "ports": [8080], "description": "reverse proxy"},
            ],
        })
        warnings, errors = validate_pinhole_allowed_from(self.zones, self.dir)
        self.assertEqual(errors, [])
        self.assertEqual(warnings, [])

    def test_intra_zone_ingress_silently_passes(self):
        """from=srv to srv-zone module — same zone needs no pinhole, no warning."""
        _write_module(self.dir, "intra", {
            "zone0": "srv",
            "ports": [{"port": 4000}],
            "ingress": [
                {"from": "srv", "ports": [4000], "description": "intra-zone"},
            ],
        })
        warnings, errors = validate_pinhole_allowed_from(self.zones, self.dir)
        self.assertEqual(errors, [])
        self.assertEqual(warnings, [])

    def test_ingress_internet_and_alias_are_out_of_scope(self):
        """'internet' and 'alias:...' are not pinhole-allowed-from concerns."""
        _write_module(self.dir, "web", {
            "zone0": "dmz",
            "ports": [{"port": 443}, {"port": 80}],
            "ingress": [
                {"from": "internet", "ports": [443], "description": "public web"},
                {"from": "alias:admin_ips", "ports": [80], "description": "admin"},
            ],
        })
        warnings, errors = validate_pinhole_allowed_from(self.zones, self.dir)
        self.assertEqual(errors, [])
        self.assertEqual(warnings, [])

    def test_module_peer_ingress_zone_compatible(self):
        """ingress.from=<module-name>, peer's zone IS in dest.pinhole-allowed-from."""
        _write_module(self.dir, "peer-in-dmz", {"zone0": "dmz",
                                                "ports": [{"port": 80}]})
        _write_module(self.dir, "consumer", {
            "zone0": "srv",
            "ports": [{"port": 80}],
            "ingress": [
                {"from": "peer-in-dmz", "ports": [80],
                 "description": "peer in dmz → consumer in srv"},
            ],
        })
        warnings, errors = validate_pinhole_allowed_from(self.zones, self.dir)
        self.assertEqual(errors, [])
        self.assertEqual(warnings, [])


class TestMismatchingScenarios(unittest.TestCase):
    """Scenarios where the validator MUST emit a warning (still exit 0)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.zones = _build_zones()

    def tearDown(self):
        self.tmp.cleanup()

    def test_ingress_from_zone_not_in_pinhole_allowed_from(self):
        """from='home' to a srv-zone module — home is NOT in srv.pinhole-allowed-from."""
        _write_module(self.dir, "secret", {
            "zone0": "srv",
            "ports": [{"port": 9000}],
            "ingress": [
                {"from": "home", "ports": [9000], "description": "home → srv"},
            ],
        })
        warnings, errors = validate_pinhole_allowed_from(self.zones, self.dir)
        self.assertEqual(errors, [])
        self.assertEqual(len(warnings), 1)
        msg = warnings[0]
        self.assertEqual(msg.severity, "warning")
        self.assertEqual(msg.module, "secret")
        # File path is the absolute path to secret.json
        self.assertTrue(msg.file_path.endswith("secret.json"))
        # Line number is set, > 0
        self.assertGreater(msg.line, 0)
        # Message names the offending zone, the destination, and quotes the policy
        self.assertIn("'home'", msg.text)
        self.assertIn("'srv'", msg.text)
        self.assertIn("pinhole-allowed-from", msg.text)

    def test_peer_module_ingress_violates_policy(self):
        """ingress.from=<peer> where peer's zone is NOT in dest.pinhole-allowed-from."""
        _write_module(self.dir, "peer-in-home", {"zone0": "home",
                                                 "ports": [{"port": 80}]})
        _write_module(self.dir, "consumer", {
            "zone0": "srv",  # srv.pinhole-allowed-from = [dmz, srv] — no home
            "ports": [{"port": 80}],
            "ingress": [
                {"from": "peer-in-home", "ports": [80],
                 "description": "peer in home → consumer in srv"},
            ],
        })
        warnings, errors = validate_pinhole_allowed_from(self.zones, self.dir)
        self.assertEqual(errors, [])
        self.assertEqual(len(warnings), 1)
        self.assertEqual(warnings[0].module, "consumer")
        self.assertIn("'peer-in-home'", warnings[0].text)
        self.assertIn("home", warnings[0].text)  # source zone resolved from peer

    def test_auto_pinhole_dependsOn_violates_policy(self):
        """A dependsOn that would trigger an auto-pinhole (#173) into a denied zone."""
        # Provider in 'locked-srv' which permits no pinholes.
        provider_loc = self.dir / "provider-loc"
        (provider_loc / "services" / "api").mkdir(parents=True)
        (provider_loc / "services" / "api" / "pinhole.json").write_text(
            json.dumps({"ports": [{"port": 8080}]})
        )
        _write_module(self.dir, "provider", {
            "zone0": "locked-srv",
            "ports": [{"port": 8080}],
            "provides": ["api"],
        }, location=str(provider_loc))
        _write_module(self.dir, "consumer", {
            "zone0": "dmz",
            "dependsOn": ["cluster:vm", "provider:api"],
        })
        warnings, errors = validate_pinhole_allowed_from(self.zones, self.dir)
        self.assertEqual(errors, [])
        self.assertTrue(any("dependsOn" in w.text and "'provider:api'" in w.text
                            for w in warnings), warnings)
        # Verify the warning carries a file:line pointing into consumer.json
        offending = next(w for w in warnings if "'provider:api'" in w.text)
        self.assertTrue(offending.file_path.endswith("consumer.json"))
        self.assertGreater(offending.line, 0)

    def test_warnings_carry_correct_line_numbers(self):
        """The file:line attached to a warning should point at the offending entry."""
        body = {
            "vmname": "secret",
            "zone0": "srv",
            "ports": [{"port": 9000}, {"port": 9001}],
            "ingress": [
                {"from": "srv", "ports": [9000], "description": "intra"},
                {"from": "home", "ports": [9001], "description": "bad — home denied"},
            ],
        }
        # Use pretty-printed JSON so each entry is on its own block of lines.
        path = self.dir / "secret.json"
        path.write_text(json.dumps(body, indent=2))
        warnings, errors = validate_pinhole_allowed_from(self.zones, self.dir)
        self.assertEqual(len(errors), 0)
        self.assertEqual(len(warnings), 1)
        # The 'from': 'home' substring should appear at the warning's line.
        line = warnings[0].line
        raw_lines = path.read_text().splitlines()
        snippet = raw_lines[line - 1] if 0 < line <= len(raw_lines) else ""
        # Tolerate either the entry's opening brace line OR the actual 'from' line.
        nearby = "\n".join(raw_lines[max(0, line - 1): line + 3])
        self.assertIn('"home"', nearby)


class TestSchemaErrors(unittest.TestCase):
    """Schema errors → ``errors`` list non-empty → CLI exits 2."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.zones = _build_zones()

    def tearDown(self):
        self.tmp.cleanup()

    def test_invalid_json_is_a_schema_error(self):
        (self.dir / "broken.json").write_text("{not-json")
        warnings, errors = validate_pinhole_allowed_from(self.zones, self.dir)
        self.assertEqual(len(errors), 1)
        self.assertEqual(errors[0].module, "broken")
        self.assertIn("invalid JSON", errors[0].text)
        self.assertGreaterEqual(errors[0].line, 1)

    def test_top_level_not_object_is_a_schema_error(self):
        (self.dir / "array.json").write_text("[1, 2, 3]")
        warnings, errors = validate_pinhole_allowed_from(self.zones, self.dir)
        self.assertEqual(len(errors), 1)
        self.assertIn("top-level JSON value", errors[0].text)

    def test_ingress_not_array_is_a_schema_error(self):
        _write_module(self.dir, "bad-ingress", {
            "zone0": "srv",
            "ingress": {"oops": "not an array"},
        })
        warnings, errors = validate_pinhole_allowed_from(self.zones, self.dir)
        self.assertTrue(any("'ingress' is not an array" in e.text for e in errors))

    def test_ingress_missing_from_field_is_a_schema_error(self):
        _write_module(self.dir, "no-from", {
            "zone0": "srv",
            "ingress": [
                {"ports": [80], "description": "missing from"},
            ],
        })
        warnings, errors = validate_pinhole_allowed_from(self.zones, self.dir)
        self.assertTrue(any("missing required 'from'" in e.text for e in errors))

    def test_ingress_from_unknown_zone_or_module_is_a_schema_error(self):
        _write_module(self.dir, "unknown-peer", {
            "zone0": "srv",
            "ingress": [
                {"from": "ghost-zone", "ports": [80], "description": "x"},
            ],
        })
        warnings, errors = validate_pinhole_allowed_from(self.zones, self.dir)
        self.assertTrue(any("not a known zone" in e.text for e in errors))


class TestGetZoneInterfaceVlanTagType(unittest.TestCase):
    """Regression test for issue #179.

    get_zone_interface() must resolve a VLAN zone to its assigned OPNsense
    interface regardless of whether the upstream API returns vlan_tag as int
    or str. Both cases have been observed in the wild across OPNsense versions.
    """

    def _make_manager(self) -> ZoneManager:
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            json.dump(
                {
                    "srv": {
                        "type": "Service",
                        "state": "Active",
                        "typeId": "2",
                        "subId": "10",
                        "vlantag": 210,
                        "ip": "10.2.10.0/24",
                        "bridge": "lan",
                        "access-to": [],
                        "pinhole-allowed-from": [],
                        "description": "srv zone",
                    },
                },
                f,
            )
            zones_file = f.name
        zm = ZoneManager(config=MagicMock(), zones_file=zones_file)
        zm.load_zones()
        return zm

    def _resolve(self, assigned_vlan_tag) -> str | None:
        """Stub VlanManager to return a single assigned VLAN, then resolve."""
        zm = self._make_manager()
        srv = next(z for z in zm.zones if z.name == "srv")

        fake_vlan_mgr = MagicMock()
        fake_vlan_mgr.get_assigned_vlans.return_value = [{
            "vlan_tag": assigned_vlan_tag,
            "device": "vlan0.210",
            "identifier": "opt1",
            "description": "srv zone",
            "enabled": True,
        }]
        fake_ctx = MagicMock()
        fake_ctx.__enter__ = MagicMock(return_value=fake_vlan_mgr)
        fake_ctx.__exit__ = MagicMock(return_value=False)

        with patch(
            "opnsense_controller.zone_manager.VlanManager",
            return_value=fake_ctx,
        ):
            return zm.get_zone_interface(srv)

    def test_resolves_when_api_returns_str(self):
        # OPNsense 26.x interfacesInfo returns vlan_tag as str.
        self.assertEqual(self._resolve("210"), "opt1")

    def test_resolves_when_api_returns_int(self):
        # Some OPNsense versions / endpoints return vlan_tag as int.
        # This is the case the original issue #179 was filed against.
        self.assertEqual(self._resolve(210), "opt1")


# ─────────────────────────────────────────────────────────────────────────────
# configure_firewall_rules — sequence layout / collision regression (issue #243)
# ─────────────────────────────────────────────────────────────────────────────


def _to_info(rule, uuid="u") -> FirewallRuleInfo:
    """Convert a created FirewallRule into the FirewallRuleInfo a later run sees."""
    iface = rule.interface if isinstance(rule.interface, str) else rule.interface[0]
    return FirewallRuleInfo(
        uuid=uuid,
        description=rule.description,
        enabled=True,
        action="pass" if rule.action == RuleAction.PASS else "block",
        interface=iface,
        direction="in",
        protocol="any",
        source_net=rule.source_net,
        source_port=None,
        destination_net=rule.destination_net,
        destination_port=None,
        log=True,
        sequence=rule.sequence,
    )


class _FakeFirewall:
    """Records create/delete calls instead of touching OPNsense."""

    def __init__(self, existing=None):
        self._existing = list(existing or [])
        self.created = []   # list[FirewallRule]
        self.deleted = []   # list[str] (descriptions)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def list_rules(self):
        return list(self._existing)

    def create_rule(self, rule, apply=False):
        self.created.append(rule)
        return {"uuid": f"new-{len(self.created)}"}

    def delete_rule(self, description, apply=False):
        self.deleted.append(description)

    def apply_changes(self):
        pass


class TestConfigureFirewallRulesSequencing(unittest.TestCase):
    """Zone firewall rules land in band 5 with a fixed, collision-free layout."""

    def _manager(self, zones: dict[str, Zone]) -> ZoneManager:
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump({}, f)
            zones_file = f.name
        zm = ZoneManager(config=MagicMock(), zones_file=zones_file)
        zm.zones = list(zones.values())
        # Each zone on its own interface (real resolution needs OPNsense).
        zm.get_zone_interface = lambda zone: f"opt_{zone.name}"
        return zm

    def _run(self, zones, existing=None) -> _FakeFirewall:
        zm = self._manager(zones)
        fake = _FakeFirewall(existing)
        with patch(
            "opnsense_controller.zone_manager.FirewallManager",
            return_value=fake,
        ):
            zm.configure_firewall_rules(check_mode=False)
        return fake

    def _seqs_by_desc(self, fake) -> dict[str, int]:
        return {r.description: r.sequence for r in fake.created}

    def test_all_zone_rules_in_band_5(self):
        fake = self._run(_build_zones())
        self.assertTrue(fake.created)
        for rule in fake.created:
            self.assertGreaterEqual(rule.sequence, 30000)
            self.assertLessEqual(rule.sequence, 39999)

    def test_zone_rules_sit_above_module_bands(self):
        # Band 5 must exceed the rules-manager pinhole/egress bands (10000-29999)
        # so a zone's rfc1918 block no longer shadows module pinholes (#243).
        fake = self._run(_build_zones())
        for rule in fake.created:
            self.assertGreater(rule.sequence, 29999)

    def test_block_and_internet_trail_passes(self):
        # srv: access-to=[internet, dmz] → gateway, pass dmz, 3 blocks, internet.
        fake = self._run(_build_zones())
        s = self._seqs_by_desc(fake)
        gateway = s["Zone srv -> gateway"]
        passes = s["Zone srv -> dmz"]
        block10 = s["Zone srv block rfc1918-10"]
        internet = s["Zone srv -> internet"]
        self.assertLess(gateway, passes)
        self.assertLess(passes, block10)
        self.assertLess(block10, internet)

    def test_no_duplicate_sequence_per_interface(self):
        fake = self._run(_build_zones())
        by_iface: dict[str, list[int]] = {}
        for rule in fake.created:
            iface = rule.interface
            by_iface.setdefault(iface, []).append(rule.sequence)
        for iface, seqs in by_iface.items():
            self.assertEqual(len(seqs), len(set(seqs)), f"dup sequence on {iface}")

    def test_adding_access_to_zone_does_not_collide_with_blocks(self):
        # The core regression: 'home' grows its access-to; the new pass rules
        # must never reuse a block/internet rule's sequence.
        zones1 = _build_zones(home={"access_to": ["internet", "srv", "dmz"]})
        first = self._run(zones1)
        existing = [_to_info(r, uuid=f"u{i}") for i, r in enumerate(first.created)]

        zones2 = _build_zones(
            home={"access_to": ["internet", "srv", "dmz", "locked-srv"]}
        )
        second = self._run(zones2, existing=existing)

        # Final desired state = whatever was already in sync + whatever was (re)created.
        in_sync = {
            r.description: r for r in existing
            if r.description not in second.deleted
        }
        final: dict[str, int] = {d: r.sequence for d, r in in_sync.items()}
        for r in second.created:
            final[r.description] = r.sequence

        home_seqs = [seq for desc, seq in final.items() if desc.startswith("Zone home ")]
        self.assertEqual(len(home_seqs), len(set(home_seqs)),
                         f"home sequence collision: {final}")
        # The new pass rule exists and sits below the block band.
        new_pass = final["Zone home -> locked-srv"]
        block10 = final["Zone home block rfc1918-10"]
        self.assertLess(new_pass, block10)

    def test_idempotent_rerun_creates_nothing(self):
        first = self._run(_build_zones())
        existing = [_to_info(r, uuid=f"u{i}") for i, r in enumerate(first.created)]
        second = self._run(_build_zones(), existing=existing)
        self.assertEqual(second.created, [])
        self.assertEqual(second.deleted, [])

    def test_stale_sequence_is_reconciled(self):
        # A rule carried over at the OLD vlan*10 sequence (~3100) must be
        # detected as drift and renumbered into band 5.
        fake = self._run(_build_zones())
        gw = next(r for r in fake.created if r.description == "Zone srv -> gateway")
        stale = _to_info(gw)
        stale.sequence = 3100  # legacy numbering
        second = self._run(_build_zones(), existing=[stale])
        self.assertIn("Zone srv -> gateway", second.deleted)
        recreated = next(
            r for r in second.created if r.description == "Zone srv -> gateway"
        )
        self.assertGreaterEqual(recreated.sequence, 30000)


# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight / post-flight health guards (issue #307)
# ─────────────────────────────────────────────────────────────────────────────


class TestEgressProbe(unittest.TestCase):
    """_check_egress() opens a TCP connection to an IP literal (no DNS)."""

    @patch("opnsense_controller.zone_manager.socket.create_connection")
    def test_egress_reachable_returns_true(self, mock_conn):
        mock_conn.return_value = MagicMock()  # context-manager-capable
        self.assertTrue(_check_egress(label="TEST"))
        # Probed an IP literal on the control port — never a hostname.
        addr = mock_conn.call_args.args[0]
        self.assertEqual(addr, ("1.1.1.1", 443))

    @patch("opnsense_controller.zone_manager.socket.create_connection",
           side_effect=OSError("Network is unreachable"))
    def test_egress_unreachable_returns_false(self, _mock_conn):
        self.assertFalse(_check_egress(label="TEST"))

    @patch("opnsense_controller.zone_manager.socket.create_connection",
           side_effect=TimeoutError("timed out"))
    def test_egress_timeout_returns_false(self, _mock_conn):
        self.assertFalse(_check_egress(label="TEST"))


class TestPreflightChecks(unittest.TestCase):
    """preflight_checks()/postflight_checks() gate on Unbound DNS + egress."""

    @patch("opnsense_controller.zone_manager._check_egress", return_value=True)
    @patch("opnsense_controller.zone_manager._check_unbound_dns", return_value=True)
    def test_all_healthy_passes(self, _dns, _egress):
        self.assertTrue(preflight_checks())
        self.assertTrue(postflight_checks())

    @patch("opnsense_controller.zone_manager._check_egress", return_value=True)
    @patch("opnsense_controller.zone_manager._check_unbound_dns", return_value=False)
    def test_dns_down_fails(self, _dns, _egress):
        self.assertFalse(preflight_checks())
        self.assertFalse(postflight_checks())

    @patch("opnsense_controller.zone_manager._check_egress", return_value=False)
    @patch("opnsense_controller.zone_manager._check_unbound_dns", return_value=True)
    def test_egress_down_fails(self, _dns, _egress):
        self.assertFalse(preflight_checks())
        self.assertFalse(postflight_checks())

    @patch("opnsense_controller.zone_manager._check_egress", return_value=False)
    @patch("opnsense_controller.zone_manager._check_unbound_dns", return_value=True)
    def test_skip_egress_ignores_egress_failure(self, _dns, mock_egress):
        # With skip_egress, a failing egress probe must NOT be run or counted.
        self.assertTrue(preflight_checks(skip_egress=True))
        self.assertTrue(postflight_checks(skip_egress=True))
        mock_egress.assert_not_called()

    @patch("opnsense_controller.zone_manager._check_egress", return_value=True)
    @patch("opnsense_controller.zone_manager._check_unbound_dns", return_value=False)
    def test_skip_egress_still_enforces_dns(self, _dns, _egress):
        # skip_egress must NOT bypass the DNS check.
        self.assertFalse(preflight_checks(skip_egress=True))


if __name__ == "__main__":
    unittest.main()
