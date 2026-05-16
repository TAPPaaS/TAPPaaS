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

from opnsense_controller.zone_manager import (
    Zone,
    ValidationMessage,
    discover_module_files,
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


if __name__ == "__main__":
    unittest.main()
