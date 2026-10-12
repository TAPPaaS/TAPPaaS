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
    IpProtocol,
    Protocol,
    RuleAction,
)
from opnsense_controller.zone_manager import (
    ORPHAN_SWEEP_LIMIT,
    plan_dnsmasq_interfaces,
    Zone,
    ValidationMessage,
    ZoneManager,
    select_orphan_ranges,
    select_orphan_zone_rules,
    rule_drift,
    ZONE_RULE_RE,
    firewall_rule_plan,
    pending_change_count,
    _check_egress,
    discover_module_files,
    main,
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
    zone_type: str = "Service",
    state: str = "Active",
    vlan_tag: int = 210,
) -> Zone:
    return Zone(
        name=name,
        zone_type=zone_type,
        state=state,
        type_id="2",
        sub_id="10",
        vlan_tag=vlan_tag,
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
    """Convert a created FirewallRule (or a FirewallRuleInfo) into what a later run sees."""
    iface = rule.interface if isinstance(rule.interface, str) else rule.interface[0]
    return FirewallRuleInfo(
        uuid=uuid,
        description=rule.description,
        enabled=True,
        action="pass" if rule.action == RuleAction.PASS else "block",
        interface=iface,
        direction="in",
        protocol=getattr(rule.protocol, "value", rule.protocol),
        source_net=rule.source_net,
        source_port=None,
        destination_net=rule.destination_net,
        destination_port=rule.destination_port,
        log=True,
        sequence=rule.sequence,
        source_invert=rule.source_invert,
        ip_protocol=getattr(rule.ip_protocol, "value", rule.ip_protocol),
        quick=rule.quick,
    )


class _FakeFirewall:
    """Records create/delete calls instead of touching OPNsense."""

    def __init__(self, existing=None, rule_ifaces=None, fail_create=False,
                 fail_apply=False):
        self._existing = list(existing or [])
        self.created = []   # list[FirewallRule]
        self.deleted = []   # list[str] (descriptions)
        self.rule_ifaces = rule_ifaces      # None: the pre-check is unavailable
        self.fail_create = fail_create
        self.fail_apply = fail_apply
        # The raw client: zone-manager writes the zone-networks alias through it.
        self.alias_calls = []
        self.client = MagicMock()
        self.client.run_module.side_effect = self._run_module

    def _run_module(self, module, check_mode=False, params=None):
        self.alias_calls.append((module, check_mode, dict(params or {})))
        return {"result": {"changed": True}}

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def list_rules(self):
        return list(self._existing)

    def list_rule_interfaces(self):
        if self.rule_ifaces is None:
            raise RuntimeError("getRule unavailable")
        return set(self.rule_ifaces)

    def create_rule(self, rule, apply=False):
        if self.fail_create:
            raise RuntimeError("'rule.interface': 'Option [wireguard] not in list.'")
        self.created.append(rule)
        return {"uuid": f"new-{len(self.created)}"}

    def delete_rule(self, description, apply=False):
        self.deleted.append(description)

    def delete_rule_by_uuid(self, uuid, apply=False):
        self.deleted.append(
            next(r.description for r in self._existing if r.uuid == uuid)
        )

    def apply_changes(self):
        if self.fail_apply:
            raise RuntimeError("apply failed")


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
        zm._resolve_zone_interfaces = lambda zones, **kw: (
            {z.name: f"opt_{z.name}" for z in zones}, [])
        return zm

    def _run(self, zones, existing=None, check_mode=False, **fake_kw) -> _FakeFirewall:
        zm = self._manager(zones)
        fake = _FakeFirewall(existing, **fake_kw)
        with patch(
            "opnsense_controller.zone_manager.FirewallManager",
            return_value=fake,
        ):
            self.results = zm.configure_firewall_rules(check_mode=check_mode)
        self.zm = zm
        return fake

    def _seqs_by_desc(self, fake) -> dict[str, int]:
        return {r.description: r.sequence for r in fake.created}

    def test_all_zone_rules_in_band_5(self):
        fake = self._run(_build_zones())
        # Caddy reachability (#366) and the admin-port guard (#384) live in band
        # 1 on purpose; the access-to/block/internet rules are band 5.
        zone_rules = [r for r in fake.created if r.sequence >= 1000]
        self.assertTrue(all(
            "-> caddy " in r.description or " block firewall " in r.description
            or r.description.endswith(" block spoofed source")
            for r in fake.created if r.sequence < 1000))
        self.assertTrue(zone_rules)
        for rule in zone_rules:
            self.assertGreaterEqual(rule.sequence, 30000)
            self.assertLessEqual(rule.sequence, 39999)

    def test_zone_rules_sit_above_module_bands(self):
        # Band 5 must exceed the rules-manager pinhole/egress bands (10000-29999)
        # so a zone's rfc1918 block no longer shadows module pinholes (#243).
        # (Caddy reachability is band 1 by design and excluded here.)
        fake = self._run(_build_zones())
        for rule in fake.created:
            if rule.sequence < 1000:   # band 1: caddy, admin guard, anti-spoof
                continue
            self.assertGreater(rule.sequence, 29999)

    def test_block_and_internet_trail_passes(self):
        # srv: access-to=[internet, dmz] → gateway, pass dmz, 3 blocks, internet.
        fake = self._run(_build_zones())
        s = self._seqs_by_desc(fake)
        gateway = s["Zone srv -> gateway dns"]
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
        gw = next(r for r in fake.created if r.description == "Zone srv -> gateway dns")
        stale = _to_info(gw)
        stale.sequence = 3100  # legacy numbering
        second = self._run(_build_zones(), existing=[stale])
        self.assertIn("Zone srv -> gateway dns", second.deleted)
        recreated = next(
            r for r in second.created if r.description == "Zone srv -> gateway dns"
        )
        self.assertGreaterEqual(recreated.sequence, 30000)


class TestRuleDrift(TestConfigureFirewallRulesSequencing):
    """A zone rule changed on the firewall is put back as declared: not only what
    it matches, but whether it is enabled, its protocol and address family."""

    def _second_run_with(self, desc, **changes):
        first = self._run(_build_zones())
        existing = [_to_info(r, uuid=f"u{i}") for i, r in enumerate(first.created)]
        target = next(r for r in existing if r.description == desc)
        for k, v in changes.items():
            setattr(target, k, v)
        return self._run(_build_zones(), existing=existing)

    def test_a_rule_as_declared_is_left_alone(self):
        first = self._run(_build_zones())
        existing = [_to_info(r, uuid=f"u{i}") for i, r in enumerate(first.created)]
        second = self._run(_build_zones(), existing=existing)
        self.assertEqual(second.deleted, [])
        self.assertEqual(second.created, [])

    def test_each_changed_property_is_repaired(self):
        cases = {
            "enabled": {"enabled": False},
            "protocol": {"protocol": "UDP"},
            "address family": {"ip_protocol": "inet6"},
            "direction": {"direction": "out"},
            "log": {"log": False},
            "quick": {"quick": False},
        }
        for name, change in cases.items():
            with self.subTest(name):
                second = self._second_run_with("Zone srv -> caddy https", **change)
                self.assertEqual(second.deleted, ["Zone srv -> caddy https"])
                again = next(r for r in second.created
                             if r.description == "Zone srv -> caddy https")
                self.assertEqual(again.protocol, Protocol.TCP)
                self.assertEqual(again.ip_protocol, IpProtocol.BOTH)
                self.assertTrue(again.enabled and again.log and again.quick)

    def test_rule_drift_names_what_differs(self):
        first = self._run(_build_zones())
        rule = next(r for r in first.created if r.description == "Zone srv -> caddy https")
        info = _to_info(rule)
        info.enabled = False
        info.ip_protocol = "inet46"
        self.assertEqual(
            rule_drift(info, interface=info.interface, action="pass",
                       source_net=rule.source_net, destination_net=rule.destination_net,
                       destination_port=rule.destination_port,
                       source_invert=rule.source_invert, sequence=rule.sequence,
                       protocol=rule.protocol, ip_protocol=IpProtocol.IPV4),
            ["address family", "enabled"])


class TestGatewayAndAdminPorts(TestConfigureFirewallRulesSequencing):
    """A zone asks its gateway for DNS/NTP/DHCP/ICMP only (#399), and no zone
    this module writes rules for reaches the firewall's admin ports (#384)."""

    def _zone_rules(self, fake, zone):
        return {r.description: r for r in fake.created
                if r.description.startswith(f"Zone {zone} ")}

    def test_a_zone_without_access_to_gets_its_gateway_and_protection_only(self):
        fake = self._run(_build_zones(home={"access_to": []}))
        rules = self._zone_rules(fake, "home")
        self.assertEqual(sorted(rules), [
            "Zone home -> gateway dhcp", "Zone home -> gateway dns",
            "Zone home -> gateway icmp", "Zone home -> gateway icmpv6",
            "Zone home -> gateway ntp",
            "Zone home block firewall ssh", "Zone home block firewall webgui",
            "Zone home block spoofed source"])
        # The gateway passes reach the gateway's /32 on their own ports only.
        dns = rules["Zone home -> gateway dns"]
        self.assertEqual(dns.destination_net, "opt_homeip")
        self.assertEqual(dns.destination_port, "53")

    def test_losing_access_to_keeps_only_gateway_and_protection(self):
        first = self._run(_build_zones())
        existing = [_to_info(r, uuid=f"u{i}") for i, r in enumerate(first.created)]
        second = self._run(_build_zones(home={"access_to": []}), existing=existing)
        gone = {d for d in second.deleted if d.startswith("Zone home ")}
        self.assertIn("Zone home -> internet", gone)
        self.assertIn("Zone home block rfc1918-10", gone)
        for kept in ("Zone home block spoofed source", "Zone home block firewall webgui",
                     "Zone home block firewall ssh", "Zone home -> gateway dns",
                     "Zone home -> gateway ntp", "Zone home -> gateway dhcp",
                     "Zone home -> gateway icmp"):
            self.assertNotIn(kept, gone)

    def test_the_gateway_is_never_open_on_every_port(self):
        fake = self._run(_build_zones())
        gw = [r for r in fake.created if " -> gateway" in r.description]
        self.assertTrue(gw)
        for r in gw:
            # The zone interface's own address: one address per family, never a range.
            self.assertEqual(r.destination_net, r.interface + "ip", r.description)
            if r.protocol in (Protocol.ICMP, Protocol.ICMPV6):
                self.assertIsNone(r.destination_port, r.description)
            else:
                self.assertIn(r.destination_port, ("53", "123", "67"), r.description)

    # ── IPv6 parity (#815): rules name interfaces, and cover both families ──

    def test_zone_rules_name_the_zone_interface_not_its_ipv4_subnet(self):
        rules = self._zone_rules(self._run(_build_zones()), "srv")
        for d, r in rules.items():
            if " -> caddy " in d:
                continue
            self.assertEqual(r.source_net, "opt_srv", d)
        self.assertEqual(rules["Zone srv -> internet"].ip_protocol, IpProtocol.BOTH)
        # Anti-spoofing stays IPv4: a negated IPv6 interface network would also
        # block link-local (OPNsense adds fe80::/10 to it).
        self.assertEqual(rules["Zone srv block spoofed source"].ip_protocol, IpProtocol.IPV4)
        self.assertEqual(rules["Zone srv -> dmz"].destination_net, "opt_dmz")
        self.assertEqual(rules["Zone srv -> dmz"].ip_protocol, IpProtocol.BOTH)
        self.assertEqual(rules["Zone srv block rfc1918-10"].ip_protocol, IpProtocol.IPV4)

    def test_ipv6_blocks_stand_in_for_rfc1918(self):
        s = self._seqs_by_desc(self._run(_build_zones()))
        rules = self._zone_rules(self._run(_build_zones()), "srv")
        for label, dest in (("zone-networks", "tappaas_zone_networks"), ("ula", "fc00::/7")):
            r = rules[f"Zone srv block {label}"]
            self.assertEqual(r.destination_net, dest)
            self.assertEqual(r.ip_protocol, IpProtocol.IPV6)
            self.assertEqual(r.action, RuleAction.BLOCK)
            self.assertLess(s["Zone srv -> dmz"], s[f"Zone srv block {label}"])
            self.assertLess(s[f"Zone srv block {label}"], s["Zone srv -> internet"])

    def test_the_zone_networks_alias_lists_every_zone_interface(self):
        fake = self._run(_build_zones())
        alias = [p for m, _, p in fake.alias_calls if m == "alias"]
        self.assertEqual(len(alias), 1)
        self.assertEqual(alias[0]["name"], "tappaas_zone_networks")
        self.assertEqual(alias[0]["type"], "networkgroup")
        self.assertIn("__opt_srv_network", alias[0]["content"])
        self.assertIn("__opt_home_network", alias[0]["content"])

    def test_a_dry_run_does_not_write_the_alias(self):
        fake = self._run(_build_zones(), check_mode=True)
        self.assertTrue(all(check for m, check, _ in fake.alias_calls if m == "alias"))

    def test_a_target_without_an_interface_keeps_its_ipv4_subnet(self):
        zm = self._manager(_build_zones())
        zm._resolve_zone_interfaces = lambda zones, **kw: (
            {z.name: f"opt_{z.name}" for z in zones if z.name != "dmz"}, [])
        fake = _FakeFirewall(None)
        with patch("opnsense_controller.zone_manager.FirewallManager", return_value=fake):
            zm.configure_firewall_rules(check_mode=False)
        r = next(r for r in fake.created if r.description == "Zone srv -> dmz")
        self.assertEqual(r.ip_protocol, IpProtocol.IPV4)
        self.assertTrue(r.destination_net[0].isdigit(), r.destination_net)

    def test_the_gateway_services(self):
        rules = self._zone_rules(self._run(_build_zones()), "srv")
        got = {d.split(" -> gateway ")[1]: (r.protocol, r.destination_port)
               for d, r in rules.items() if " -> gateway " in d}
        self.assertEqual(got, {
            "dns": (Protocol.TCP_UDP, "53"), "ntp": (Protocol.UDP, "123"),
            "dhcp": (Protocol.UDP, "67"), "icmp": (Protocol.ICMP, None),
            "icmpv6": (Protocol.ICMPV6, None),
        })

    def test_gateway_passes_precede_the_rfc1918_block(self):
        # The block covers 10/8, the gateway included: a pass after it is dead.
        s = self._seqs_by_desc(self._run(_build_zones()))
        for label in ("dns", "ntp", "dhcp", "icmp"):
            self.assertLess(s[f"Zone srv -> gateway {label}"], s["Zone srv block rfc1918-10"])

    def test_admin_ports_are_blocked_on_every_firewall_address(self):
        rules = self._zone_rules(self._run(_build_zones()), "srv")
        for label, port in (("webgui", "8443"), ("ssh", "22")):
            r = rules[f"Zone srv block firewall {label}"]
            self.assertEqual((r.action, r.protocol, r.destination_net, r.destination_port),
                             (RuleAction.BLOCK, Protocol.TCP, "(self)", port))

    def test_the_guard_precedes_every_pass_of_the_zone(self):
        # An access-to edge into another zone includes that zone's gateway —
        # this firewall — so the guard must be evaluated first.
        rules = self._zone_rules(self._run(_build_zones()), "srv")
        guard = max(r.sequence for d, r in rules.items() if " block firewall " in d)
        passes = [r.sequence for r in rules.values()
                  if r.action == RuleAction.PASS and "-> caddy " not in r.description]
        self.assertLess(guard, min(passes))

    def test_manual_zones_keep_their_reach(self):
        # mgmt, the NetBird overlay and the admin VPN are Manual: no guard.
        fake = self._run(self._with_manual())
        self.assertFalse([r for r in fake.created
                          if r.description.startswith(("Zone mgmt ", "Zone admin "))
                          and (" block firewall " in r.description
                               or r.description.endswith(" block spoofed source"))])

    def _with_manual(self):
        zones = _build_zones()
        zones["admin"] = _zone("admin", access_to=["mgmt"], zone_type="Overlay",
                               state="Manual", vlan_tag=0)
        return zones

    def test_only_the_zone_subnet_may_speak_on_its_interface(self):
        # #159: the first rule of a zone drops every source outside its subnet.
        rules = self._zone_rules(self._run(_build_zones()), "srv")
        r = rules["Zone srv block spoofed source"]
        self.assertEqual(
            (r.action, r.source_net, r.source_invert, r.destination_net, r.protocol),
            (RuleAction.BLOCK, rules["Zone srv -> gateway dns"].source_net, True, "any", Protocol.ANY))
        self.assertEqual(r.sequence, min(x.sequence for x in rules.values()))

    def test_anti_spoofing_is_reconciled_when_the_invert_is_lost(self):
        # A rule whose `source_not` was lost would block the zone's OWN subnet —
        # every host in it, cut off. The reconcile must see that as drift.
        first = self._run(_build_zones())
        existing = [_to_info(r, uuid=f"u{i}") for i, r in enumerate(first.created)]
        for e in existing:
            if e.description == "Zone srv block spoofed source":
                e.source_invert = False
        second = self._run(_build_zones(), existing=existing)
        self.assertIn("Zone srv block spoofed source", second.deleted)
        self.assertTrue(next(r for r in second.created
                             if r.description == "Zone srv block spoofed source").source_invert)

    def test_an_existing_all_ports_gateway_rule_is_reaped(self):
        # A site upgrading from before #399 carries `Zone srv -> gateway` on
        # every port; the reconcile must delete it, not leave it beside the new ones.
        first = self._run(_build_zones())
        existing = [_to_info(r, uuid=f"u{i}") for i, r in enumerate(first.created)]
        old = _to_info(next(r for r in first.created
                            if r.description == "Zone srv -> gateway dns"), uuid="old")
        old.description, old.destination_port = "Zone srv -> gateway", None
        second = self._run(_build_zones(), existing=existing + [old])
        self.assertIn("Zone srv -> gateway", second.deleted)
        self.assertEqual(second.created, [])


class TestStaleZoneRuleReaping(TestConfigureFirewallRulesSequencing):
    """A rule the reconcile did not ask for is drift and gets deleted (#618)."""

    def test_dropped_access_to_target_is_reaped(self):
        # ADR-021 D3b(ii): removing `dmz` from a Service zone's access-to must
        # actually remove the pass. Until the reaper existed the rule survived,
        # so the removal closed nothing — the whole DMZ subnet (gateway, hence
        # the firewall GUI and SSH) stayed reachable.
        first = self._run(_build_zones())
        existing = [_to_info(r, uuid=f"u{i}") for i, r in enumerate(first.created)]
        # srv drops dmz from access-to; everything else is unchanged.
        second = self._run(_build_zones(srv={"access_to": ["internet"]}),
                           existing=existing)
        self.assertIn("Zone srv -> dmz", second.deleted)

    def test_still_desired_rules_are_not_reaped(self):
        # The reaper must converge, not churn: a second run with the same input
        # deletes nothing.
        first = self._run(_build_zones())
        existing = [_to_info(r, uuid=f"u{i}") for i, r in enumerate(first.created)]
        second = self._run(_build_zones(), existing=existing)
        self.assertEqual(second.deleted, [])
        self.assertEqual(second.created, [])

    def test_caddy_rule_is_not_reaped(self):
        # The caddy-reach rules are created after the access-to passes; the
        # reaper must count them as desired or it would delete them every run.
        first = self._run(_build_zones())
        existing = [_to_info(r, uuid=f"u{i}") for i, r in enumerate(first.created)]
        second = self._run(_build_zones(), existing=existing)
        for d in second.deleted:
            self.assertNotIn("-> caddy ", d)

    def test_foreign_rules_are_left_alone(self):
        # Only this module's `Zone <name> ` namespace is reaped.
        first = self._run(_build_zones())
        existing = [_to_info(r, uuid=f"u{i}") for i, r in enumerate(first.created)]
        foreign = _to_info(first.created[0], uuid="uX")
        foreign.description = "tappaas-module:nextcloud:egress:home:443"
        second = self._run(_build_zones(), existing=existing + [foreign])
        self.assertNotIn(foreign.description, second.deleted)


# ─────────────────────────────────────────────────────────────────────────────
# Caddy reverse-proxy reachability (issue #366)
# ─────────────────────────────────────────────────────────────────────────────


class TestCaddyReachability(TestConfigureFirewallRulesSequencing):
    """Every zone gets a band-1 PASS to the DMZ gateway on tcp/80+443 (#366)."""

    def _caddy_rules(self, fake):
        return [r for r in fake.created if "-> caddy " in r.description]

    def test_rule_emitted_per_zone_including_dmz(self):
        fake = self._run(_build_zones())
        descs = {r.description for r in self._caddy_rules(fake)}
        # Every candidate zone gets https + http — dmz included (ADR-021 D3b).
        for z in ("srv", "home", "locked-srv", "dmz"):
            self.assertIn(f"Zone {z} -> caddy https", descs)
            self.assertIn(f"Zone {z} -> caddy http", descs)

    def test_dmz_zone_gets_its_own_rule(self):
        # ADR-021 D3b(i). The dmz zone used to be skipped as "reaches the gateway
        # locally" — but locally is the unrestricted `Zone dmz -> gateway` rule
        # that #399 narrows to DNS/NTP/DHCP/ICMP. Without its own /32 a DMZ
        # workload would lose tcp/443 to Caddy the moment #399 lands.
        fake = self._run(_build_zones())
        rules = {r.description: r for r in self._caddy_rules(fake)}
        self.assertIn("Zone dmz -> caddy https", rules)
        r = rules["Zone dmz -> caddy https"]
        self.assertEqual(r.destination_net, "opt_dmzip")   # the DMZ interface's address
        self.assertEqual(r.destination_port, "443")
        self.assertEqual(r.protocol, Protocol.TCP)

    def test_overlay_zone_with_access_to_gets_rule(self):
        # ADR-021 D3a. An Overlay zone carries no `internet` (it is not a routed
        # segment) but its peers resolve the same split-horizon answer, so they
        # need the same /32. `admin` is the live case.
        zones = _build_zones()
        zones["admin"] = _zone(
            "admin", access_to=["mgmt"], zone_type="Overlay",
            state="Manual", vlan_tag=0,
        )
        fake = self._run(zones)
        descs = {r.description for r in self._caddy_rules(fake)}
        self.assertIn("Zone admin -> caddy https", descs)
        self.assertIn("Zone admin -> caddy http", descs)

    def test_dormant_overlay_zone_gets_no_rule(self):
        # An Overlay with an empty access-to is dormant (netbird/edge today) and
        # stays out — admitting an overlay to Caddy is a decision to take when
        # that overlay is actually terminated.
        zones = _build_zones()
        zones["netbird"] = _zone(
            "netbird", access_to=[], zone_type="Overlay",
            state="Manual", vlan_tag=0,
        )
        fake = self._run(zones)
        descs = {r.description for r in self._caddy_rules(fake)}
        self.assertNotIn("Zone netbird -> caddy https", descs)

    def test_targets_dmz_gateway_on_tcp_80_and_443(self):
        fake = self._run(_build_zones())
        for r in self._caddy_rules(fake):
            zone = r.description.split()[1]
            self.assertEqual(r.destination_net, "opt_dmzip")      # the DMZ interface address
            self.assertEqual(r.source_net, f"opt_{zone}")         # the zone's own network
            self.assertEqual(r.ip_protocol, IpProtocol.BOTH)
            self.assertEqual(r.action, RuleAction.PASS)
            self.assertEqual(r.protocol, Protocol.TCP)
            self.assertIn(r.destination_port, ("80", "443"))

    def test_sits_below_rfc1918_block(self):
        # Band 1 < band 5: under first-match-quick the pass beats the zone's
        # rfc1918 block, so traffic to the DMZ gateway reaches Caddy.
        fake = self._run(_build_zones())
        s = self._seqs_by_desc(fake)
        for z in ("srv", "home", "locked-srv"):
            caddy = s[f"Zone {z} -> caddy https"]
            block10 = s[f"Zone {z} block rfc1918-10"]
            self.assertLess(caddy, block10)
            self.assertLess(caddy, 30000)

    def test_skipped_when_no_dmz_zone(self):
        zones = _build_zones()
        del zones["dmz"]
        fake = self._run(zones)
        self.assertEqual(self._caddy_rules(fake), [])

    def test_isolated_zone_without_internet_gets_no_rule(self):
        # A zone with empty access-to (fully isolated) must NOT reach Caddy.
        zones = _build_zones(home={"access_to": []})
        fake = self._run(zones)
        descs = {r.description for r in self._caddy_rules(fake)}
        self.assertNotIn("Zone home -> caddy https", descs)
        self.assertNotIn("Zone home -> caddy http", descs)
        # internet-capable peers still get theirs.
        self.assertIn("Zone srv -> caddy https", descs)

    def test_all_access_zone_gets_rule(self):
        # access-to=[all] implies internet → still reachable.
        zones = _build_zones(home={"access_to": ["all"]})
        fake = self._run(zones)
        descs = {r.description for r in self._caddy_rules(fake)}
        self.assertIn("Zone home -> caddy https", descs)

    def test_idempotent_rerun_creates_nothing(self):
        first = self._run(_build_zones())
        existing = [_to_info(r, uuid=f"u{i}") for i, r in enumerate(first.created)]
        second = self._run(_build_zones(), existing=existing)
        self.assertEqual([r.description for r in self._caddy_rules(second)], [])

    def _with_admin(self):
        zones = _build_zones()
        zones["admin"] = _zone(
            "admin", access_to=["mgmt"], zone_type="Overlay",
            state="Manual", vlan_tag=0,
        )
        return zones

    def test_overlay_without_interface_is_skipped(self):
        # #640: a site without admin-vpn has no 'wireguard' interface, and
        # OPNsense rejected the admin caddy pair on every apply.
        fake = self._run(self._with_admin(),
                         rule_ifaces={"lan", "opt_srv", "opt_dmz"})
        descs = {r.description for r in self._caddy_rules(fake)}
        self.assertNotIn("Zone admin -> caddy https", descs)
        self.assertIn("Zone srv -> caddy https", descs)
        self.assertEqual(self.zm.failures, [])

    def test_overlay_with_interface_gets_rule(self):
        fake = self._run(self._with_admin(), rule_ifaces={"lan", "opt_admin"})
        descs = {r.description for r in self._caddy_rules(fake)}
        self.assertIn("Zone admin -> caddy https", descs)


# ─────────────────────────────────────────────────────────────────────────────
# Convergence failures fail the run (issue #639)
# ─────────────────────────────────────────────────────────────────────────────


class TestConvergenceFailures(TestConfigureFirewallRulesSequencing):

    def test_clean_run_records_no_failure(self):
        self._run(_build_zones())
        self.assertEqual(self.zm.failures, [])

    def test_rejected_rule_is_a_failure(self):
        self._run(_build_zones(), fail_create=True)
        self.assertTrue(self.zm.failures)

    def test_failed_apply_is_a_failure(self):
        # Staged rules that never reach pf are not converged either.
        self._run(_build_zones(), fail_apply=True)
        self.assertTrue(any("Applying" in f for f in self.zm.failures))

    def _main(self, failures):
        def fake_rules(zm_self, check_mode=True):
            zm_self.failures.extend(failures)
            return {}
        with patch("opnsense_controller.zone_manager.Config"), \
                patch("opnsense_controller.rules_manager._find_zones_file",
                      return_value=Path("/nonexistent.json")), \
                patch.object(ZoneManager, "load_zones"), \
                patch.object(ZoneManager, "print_zone_summary"), \
                patch.object(ZoneManager, "configure_firewall_rules", fake_rules), \
                patch("sys.argv", ["zone-manager", "--firewall-rules-only"]):
            main()

    def test_main_exits_nonzero_on_failure(self):
        with self.assertRaises(SystemExit) as cm:
            self._main(["Firewall rule 'Zone admin -> caddy https': rejected"])
        self.assertEqual(cm.exception.code, 1)

    def test_main_exits_zero_when_converged(self):
        self._main([])  # no SystemExit


# ─────────────────────────────────────────────────────────────────────────────
# Rules of zones no longer in zones.json (issue #641)
# ─────────────────────────────────────────────────────────────────────────────


class TestSelectOrphanZoneRules(unittest.TestCase):

    def test_groups_rules_of_absent_zones(self):
        orphans, refusal = select_orphan_zone_rules(
            ["Zone home -> internet", "Zone srv-home -> internet",
             "Zone srv-home block rfc1918-10", "Zone guest -> gateway"],
            {"home", "guest", "srvHome"},
        )
        self.assertEqual(refusal, "")
        self.assertEqual(orphans, {"srv-home": [
            "Zone srv-home -> internet", "Zone srv-home block rfc1918-10"]})

    def test_protective_rules_of_absent_zones_are_reaped(self):
        # Anti-spoofing and the admin guard outlive a removed zone otherwise; on
        # an interface reused by a new zone, the old anti-spoofing rule blocks it.
        orphans, refusal = select_orphan_zone_rules(
            ["Zone home -> internet", "Zone old block spoofed source",
             "Zone old block firewall webgui", "Zone old block firewall ssh"],
            {"home"},
        )
        self.assertEqual(refusal, "")
        self.assertEqual(sorted(orphans["old"]), [
            "Zone old block firewall ssh", "Zone old block firewall webgui",
            "Zone old block spoofed source"])

    def test_similar_hand_made_blocks_are_not_ours(self):
        orphans, _ = select_orphan_zone_rules(
            ["Zone old block spoofed source extra", "Zone old block firewall gui",
             "Zone home -> internet"],
            {"home"},
        )
        self.assertEqual(orphans, {})

    def test_other_shapes_are_not_ours(self):
        orphans, _ = select_orphan_zone_rules(
            ["Zone gone allow printer", "tappaas-admin admin->mgmt",
             "Zone home -> internet"],
            {"home"},
        )
        self.assertEqual(orphans, {})

    def test_refuses_when_orphans_outnumber_live_zones(self):
        # A wrong --zones-file makes most of the site look orphaned.
        orphans, refusal = select_orphan_zone_rules(
            ["Zone a -> internet", "Zone b -> internet", "Zone home -> internet"],
            {"home"},
        )
        self.assertEqual(orphans, {})
        self.assertIn("Refusing", refusal)


class TestOrphanZoneRuleReaping(TestConfigureFirewallRulesSequencing):

    def _existing_with(self, *descs):
        first = self._run(_build_zones())
        existing = [_to_info(r, uuid=f"u{i}") for i, r in enumerate(first.created)]
        for i, d in enumerate(descs):
            orphan = _to_info(first.created[0], uuid=f"o{i}")
            orphan.description = d
            orphan.interface = "opt2"  # an optN since reassigned (wg0 on-site)
            existing.append(orphan)
        return existing

    def test_every_emitted_rule_shape_is_reapable(self):
        # Whatever configure_firewall_rules writes, the orphan reaper must know
        # it, or the rule survives its zone (the anti-spoofing case above).
        first = self._run(_build_zones())
        unknown = [r.description for r in first.created
                   if not ZONE_RULE_RE.match(r.description)]
        self.assertTrue(first.created)
        self.assertEqual(unknown, [])

    def test_protective_rules_of_renamed_zone_are_reaped(self):
        existing = self._existing_with(
            "Zone rossen-private block spoofed source",
            "Zone rossen-private block firewall webgui",
            "Zone rossen-private block firewall ssh",
        )
        fake = self._run(_build_zones(), existing=existing)
        for d in ("Zone rossen-private block spoofed source",
                  "Zone rossen-private block firewall webgui",
                  "Zone rossen-private block firewall ssh"):
            self.assertIn(d, fake.deleted)

    def test_rules_of_renamed_zone_are_reaped(self):
        existing = self._existing_with(
            "Zone rossen-private -> internet", "Zone rossen-private block rfc1918-10",
        )
        fake = self._run(_build_zones(), existing=existing)
        self.assertIn("Zone rossen-private -> internet", fake.deleted)
        self.assertIn("Zone rossen-private block rfc1918-10", fake.deleted)
        self.assertEqual(self.zm.failures, [])

    def test_dry_run_lists_but_keeps_them(self):
        existing = self._existing_with("Zone rossen-private -> internet")
        fake = self._run(_build_zones(), existing=existing, check_mode=True)
        self.assertEqual(fake.deleted, [])
        rules = self.results["rossen-private"]["rules"]
        self.assertEqual(rules[0]["status"], "would_delete")

    def test_refusal_deletes_nothing_and_fails(self):
        existing = self._existing_with(*(f"Zone gone{i} -> internet" for i in range(5)))
        fake = self._run(_build_zones(), existing=existing)
        self.assertFalse([d for d in fake.deleted if d.startswith("Zone gone")])
        self.assertTrue(self.zm.failures)


class TestDryRunRulePlan(TestConfigureFirewallRulesSequencing):
    """A check-mode run names every rule --execute would change (#645)."""

    def _in_sync(self):
        first = self._run(_build_zones())
        return [_to_info(r, uuid=f"u{i}") for i, r in enumerate(first.created)]

    def test_in_sync_plans_nothing(self):
        self._run(_build_zones(), existing=self._in_sync(), check_mode=True)
        self.assertEqual(firewall_rule_plan(self.results), [])
        self.assertEqual(pending_change_count({"firewall": self.results}), 0)

    def test_fresh_firewall_plans_creates_and_touches_nothing(self):
        fake = self._run(_build_zones(), check_mode=True)
        self.assertEqual(fake.created, [])
        plan = firewall_rule_plan(self.results)
        self.assertIn(("srv", "create", "Zone srv -> dmz"), plan)
        self.assertEqual(pending_change_count({"firewall": self.results}), len(plan))

    def test_dropped_target_is_planned_as_delete(self):
        fake = self._run(_build_zones(srv={"access_to": ["internet"]}),
                         existing=self._in_sync(), check_mode=True)
        self.assertEqual(fake.deleted, [])
        self.assertEqual(firewall_rule_plan(self.results),
                         [("srv", "delete", "Zone srv -> dmz")])

    def test_orphan_zone_rules_are_planned_as_delete(self):
        existing = self._in_sync()
        orphan = _to_info(existing[0], uuid="o1")
        orphan.description = "Zone gone -> internet"
        self._run(_build_zones(), existing=existing + [orphan], check_mode=True)
        self.assertIn(("gone", "delete", "Zone gone -> internet"),
                      firewall_rule_plan(self.results))

    def test_disabled_zone_rules_are_listed_one_by_one(self):
        existing = self._in_sync()
        self._run(_build_zones(home={"state": "Disabled"}), existing=existing,
                  check_mode=True)
        home = [d for z, v, d in firewall_rule_plan(self.results) if z == "home"]
        self.assertEqual(sorted(home), sorted(
            r.description for r in existing if r.description.startswith("Zone home ")))

    def _dnsmasq(self, current):
        zm = self._manager(_build_zones())
        zm.get_vlan_zones = lambda: list(zm.zones)
        zm._resolve_zone_interfaces = lambda zones: (
            {z.name: f"opt_{z.name}" for z in zones}, [])
        fake = MagicMock()
        fake.__enter__.return_value = fake
        if isinstance(current, Exception):
            fake.get_dnsmasq_interfaces.side_effect = current
        else:
            fake.get_dnsmasq_interfaces.return_value = current
        with patch("opnsense_controller.zone_manager.DhcpManager", return_value=fake):
            r = zm.update_dnsmasq_interfaces(check_mode=True)
        fake.set_dnsmasq_interfaces.assert_not_called()
        return r

    def test_dnsmasq_in_sync_is_not_pending(self):
        want = ["lan"] + [f"opt_{n}" for n in _build_zones()]
        r = self._dnsmasq(list(reversed(want)))
        self.assertEqual(r["status"], "in_sync")
        self.assertEqual(pending_change_count({"dnsmasq_interfaces": r}), 0)

    def test_dnsmasq_missing_interface_is_pending(self):
        r = self._dnsmasq(["lan", "opt_srv"])
        self.assertEqual(r["status"], "would_update")

    def test_dnsmasq_unreadable_stays_pending(self):
        r = self._dnsmasq(RuntimeError("api down"))
        self.assertEqual(r["status"], "would_update")

    def test_vlan_and_dhcp_outcomes_count_as_pending(self):
        self.assertEqual(pending_change_count(
            {"vlans": {"x": {"status": "would_create"}},
             "dhcp": {"x": {"status": "exists"}, "y": {"boot": "would_clear"}}}), 2)


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


class TestZoneBootOptions(unittest.TestCase):
    """Zone.from_json parsing + _reconcile_boot_options (DHCP 66/67, #546)."""

    def _zm(self) -> ZoneManager:
        # zones_file is never loaded here — we call the reconcile helper directly.
        return ZoneManager(config=MagicMock(), zones_file="/nonexistent.json")

    def _boot_zone(self, tftp: str, bootfile: str) -> Zone:
        return Zone.from_json("iotLocal", {
            "type": "IoT", "state": "Active", "typeId": "4", "subId": "0",
            "vlantag": 400, "ip": "10.4.0.0/24", "bridge": "lan",
            "tftp-server-name": tftp, "bootfile-name": bootfile,
        })

    def test_from_json_parses_and_strips(self):
        z = self._boot_zone("  10.4.0.10 ", " pxelinux.0 ")
        self.assertEqual(z.tftp_server_name, "10.4.0.10")
        self.assertEqual(z.bootfile_name, "pxelinux.0")
        self.assertTrue(z.has_boot_options)

    def test_has_boot_options_needs_both(self):
        self.assertFalse(self._boot_zone("10.4.0.10", "").has_boot_options)
        self.assertFalse(self._boot_zone("", "pxelinux.0").has_boot_options)

    def test_reconcile_sets_bootp_and_options_ip_server(self):
        zm = self._zm()
        mgr = MagicMock()
        zone = self._boot_zone("10.4.0.10", "pxelinux.0")
        changed, result = zm._reconcile_boot_options(mgr, zone, "opt1", False)
        self.assertTrue(changed)
        self.assertEqual(result["boot"], "set")
        # BOOTP header: an IP tftp server → address (siaddr), empty servername.
        mgr.set_boot_entry.assert_called_once()
        kw = mgr.set_boot_entry.call_args.kwargs
        self.assertEqual(kw["filename"], "pxelinux.0")
        self.assertEqual(kw["address"], "10.4.0.10")
        self.assertEqual(kw["servername"], "")
        self.assertEqual(kw["interface"], "opt1")
        self.assertEqual(kw["description"], "iotLocal boot")
        # Explicit dhcp-option 66 + 67.
        opts = {c.kwargs["option"]: c.kwargs for c in mgr.create_set_option.call_args_list}
        self.assertEqual(opts["66"]["value"], "10.4.0.10")
        self.assertEqual(opts["66"]["description"], "iotLocal option66")
        self.assertEqual(opts["67"]["value"], "pxelinux.0")
        self.assertEqual(opts["67"]["description"], "iotLocal option67")

    def test_reconcile_hostname_server_uses_servername(self):
        zm = self._zm()
        mgr = MagicMock()
        zone = self._boot_zone("tftp.internal", "pxelinux.0")
        zm._reconcile_boot_options(mgr, zone, "opt1", False)
        kw = mgr.set_boot_entry.call_args.kwargs
        self.assertEqual(kw["address"], "")
        self.assertEqual(kw["servername"], "tftp.internal")
        # option 66 still carries the raw value regardless.
        opt66 = [c.kwargs for c in mgr.create_set_option.call_args_list
                 if c.kwargs["option"] == "66"][0]
        self.assertEqual(opt66["value"], "tftp.internal")

    def test_reconcile_absent_and_clean_is_noop(self):
        zm = self._zm()
        mgr = MagicMock()
        mgr.get_boot_by_description.return_value = None
        mgr.list_dhcp_options.return_value = []
        zone = self._boot_zone("", "")
        changed, result = zm._reconcile_boot_options(mgr, zone, "opt1", False)
        self.assertFalse(changed)
        self.assertEqual(result["boot"], "none")
        mgr.set_boot_entry.assert_not_called()
        mgr.delete_boot_entry.assert_not_called()

    def test_reconcile_absent_self_heals_stale(self):
        zm = self._zm()
        mgr = MagicMock()
        # A boot entry lingers from a previous config where the zone had options.
        mgr.get_boot_by_description.side_effect = (
            lambda d: {"uuid": "u"} if d == "iotLocal boot" else None
        )
        mgr.list_dhcp_options.return_value = [
            {"uuid": "o66", "description": "iotLocal option66"},
        ]
        zone = self._boot_zone("", "")
        changed, result = zm._reconcile_boot_options(mgr, zone, "opt1", False)
        self.assertTrue(changed)
        self.assertEqual(result["boot"], "cleared")
        mgr.delete_boot_entry.assert_called_once_with(
            "iotLocal boot", reconfigure=False)
        deleted = {c.args[0] for c in mgr.delete_option_by_description.call_args_list}
        self.assertEqual(deleted, {"iotLocal option66", "iotLocal option67"})

    def test_reconcile_check_mode_makes_no_writes(self):
        zm = self._zm()
        mgr = MagicMock()
        zone = self._boot_zone("10.4.0.10", "pxelinux.0")
        changed, result = zm._reconcile_boot_options(mgr, zone, "opt1", True)
        self.assertFalse(changed)
        self.assertEqual(result["boot"], "would_set")
        mgr.set_boot_entry.assert_not_called()
        mgr.create_set_option.assert_not_called()


class TestOrphanRangeSweep(unittest.TestCase):
    """The sweep that deleted seven live DHCP ranges in one second.

    It is meant to clear what a zone RENAME leaves behind. It has no way to tell
    a rename leftover from a range whose zone is missing only because the WRONG
    zones file was loaded, so the batch size is the guard: one or two is a
    rename, seven is a bad zone set.
    """

    def test_sweeps_a_rename_leftover(self):
        orphans, refusal = select_orphan_ranges(
            {"rossen DHCP": {}, "srv DHCP": {}}, {"rossen DHCP"}
        )
        self.assertEqual(orphans, ["srv DHCP"])
        self.assertEqual(refusal, "")

    def test_leaves_operator_ranges_alone(self):
        """Only the "<name> DHCP" convention is swept."""
        orphans, refusal = select_orphan_ranges(
            {"lab range for printers": {}}, {"rossen DHCP"}
        )
        self.assertEqual(orphans, [])
        self.assertEqual(refusal, "")

    def test_refuses_a_batch_too_large_to_be_a_rename(self):
        """The real incident: the repo template loaded instead of the site's."""
        live = {
            f"{z} DHCP": {}
            for z in ("rossen", "home", "guest", "dmz", "iotLocal", "iotCloud", "iotCams")
        }
        orphans, refusal = select_orphan_ranges(live, {"srv DHCP"})
        self.assertEqual(orphans, [], "nothing may be deleted when we refuse")
        self.assertIn("Refusing to delete 7", refusal)
        self.assertIn("/home/tappaas/config/zones.json", refusal)

    def test_boundary_is_inclusive(self):
        at_limit = {f"z{i} DHCP": {} for i in range(ORPHAN_SWEEP_LIMIT)}
        orphans, refusal = select_orphan_ranges(at_limit, set())
        self.assertEqual(len(orphans), ORPHAN_SWEEP_LIMIT)
        self.assertEqual(refusal, "")

        over = {f"z{i} DHCP": {} for i in range(ORPHAN_SWEEP_LIMIT + 1)}
        _, refusal = select_orphan_ranges(over, set())
        self.assertNotEqual(refusal, "")


class TestZonesFileResolution(unittest.TestCase):
    """`zone-manager` with no --zones-file must never pick the repo template
    while the site's own zones.json exists — that substitution is what made
    every live zone look orphaned."""

    def test_live_config_beats_repo_template(self):
        # The candidate ORDER is the contract, and it is cheaper and more honest
        # to assert it than to fake a filesystem where both files exist.
        import inspect

        from opnsense_controller import rules_manager

        src = inspect.getsource(rules_manager._find_zones_file)
        live_at = src.index('Path("/home/tappaas/config/zones.json")')
        tmpl_at = src.index("DEFAULT_ZONES_FILE")
        self.assertLess(
            live_at, tmpl_at, "the live config must be tried before the template"
        )

    def test_cli_uses_the_shared_resolver(self):
        """zone_manager.main() must not carry a second, divergent search list."""
        import inspect

        from opnsense_controller import zone_manager

        src = inspect.getsource(zone_manager.main)
        self.assertIn("_find_zones_file", src)
        self.assertNotIn(
            'Path("src/foundation/tappaas-cicd/manager/network-manager/zones.json")',
            src,
            "the old template-only search list is back",
        )


class TestDnsmasqListenSet(unittest.TestCase):
    """The listen set is written wholesale from a list rebuilt as
    ["lan"] + resolved VLAN interfaces. One incomplete interfacesInfo read
    resolves nothing and collapses it to "lan" — which is what actually took
    DHCP and per-zone DNS down site-wide on 2026-09-04, not the orphan sweep.
    """

    LIVE = ["lan", "opt1", "opt3", "opt4", "opt5", "opt7", "opt8", "opt9"]

    def test_refuses_the_collapse_to_lan(self):
        ifaces, refusal = plan_dnsmasq_interfaces(self.LIVE, ["lan"], 7)
        self.assertEqual(ifaces, self.LIVE, "the live set must be kept intact")
        self.assertIn("Refusing to drop 7", refusal)

    def test_normal_growth_is_written(self):
        desired = self.LIVE + ["opt11"]
        ifaces, refusal = plan_dnsmasq_interfaces(self.LIVE, desired, 8)
        self.assertEqual(ifaces, desired)
        self.assertEqual(refusal, "")

    def test_no_change_is_written(self):
        ifaces, refusal = plan_dnsmasq_interfaces(self.LIVE, list(self.LIVE), 7)
        self.assertEqual(ifaces, self.LIVE)
        self.assertEqual(refusal, "")

    def test_a_real_zone_disable_still_shrinks(self):
        """Some zones still resolved, so the read was good — honour the drop."""
        desired = ["lan", "opt1", "opt3", "opt4", "opt5", "opt7", "opt8"]
        ifaces, refusal = plan_dnsmasq_interfaces(self.LIVE, desired, 6)
        self.assertEqual(ifaces, desired)
        self.assertEqual(refusal, "")

    def test_no_vlan_zones_at_all_may_shrink_to_lan(self):
        """A site with no VLAN zones legitimately listens only on lan."""
        ifaces, refusal = plan_dnsmasq_interfaces(self.LIVE, ["lan"], 0)
        self.assertEqual(ifaces, ["lan"])
        self.assertEqual(refusal, "")

    def test_partial_resolve_is_additive_only(self):
        """One zone unresolved (#574 ask 3): its interface must be KEPT and
        the newly-resolved one merged in — a suspect read never drops."""
        desired = ["lan", "opt1", "opt3", "opt4", "opt5", "opt7", "opt10"]
        ifaces, refusal = plan_dnsmasq_interfaces(
            self.LIVE, desired, 8, unresolved=2
        )
        self.assertEqual(refusal, "")
        self.assertEqual(ifaces, self.LIVE + ["opt10"],
                         "unresolved zones' interfaces stay; additions merge")

    def test_full_resolve_still_allows_real_shrink(self):
        """unresolved=0 keeps the genuine zone-disable shrink working."""
        desired = ["lan", "opt1", "opt3", "opt4", "opt5", "opt7", "opt8"]
        ifaces, refusal = plan_dnsmasq_interfaces(
            self.LIVE, desired, 6, unresolved=0
        )
        self.assertEqual(ifaces, desired)
        self.assertEqual(refusal, "")

    def test_total_resolve_failure_still_refused_even_with_unresolved(self):
        """The none-resolved collapse is refused before the additive rule."""
        ifaces, refusal = plan_dnsmasq_interfaces(
            self.LIVE, ["lan"], 7, unresolved=7
        )
        self.assertEqual(ifaces, self.LIVE)
        self.assertIn("Refusing to drop 7", refusal)


if __name__ == "__main__":
    unittest.main()
