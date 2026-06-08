"""Unit tests for rules_manager.

Covers the pure-Python pieces — helpers, loaders, validation, compilation,
sequence allocation, peer resolution — without touching OPNsense.

Run with:
    cd src && python -m unittest test.test_rules_manager -v
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from opnsense_controller import rules_manager as rm
from opnsense_controller.config import Config
from opnsense_controller.firewall_manager import FirewallRuleInfo
from opnsense_controller.rules_manager import (
    BAND_EGRESS_BASE,
    BAND_INGRESS_BASE,
    SLOT_SIZE,
    ModuleSpec,
    RulesManager,
    ValidationError,
    ZoneSpec,
    _canonical_description,
    _canonical_part,
    _module_alias_name,
    _normalize_protocol,
    load_global_aliases,
    load_module,
    load_zones,
    stable_hash_index,
)


# ─────────────────────────────────────────────────────────────────────────────
# Fixtures
# ─────────────────────────────────────────────────────────────────────────────

ZONES_FIXTURE = {
    "mgmt": {"type": "mgmt", "state": "Manual", "typeId": "0", "subId": "0",
              "vlantag": 0, "ip": "10.0.0.0/24", "bridge": "lan",
              "access-to": [], "pinhole-allowed-from": []},
    "srvWork": {"type": "service", "state": "Active", "typeId": "2", "subId": "10",
                  "vlantag": 210, "ip": "10.2.10.0/24", "bridge": "lan",
                  "access-to": ["internet"],
                  "pinhole-allowed-from": ["srvWork", "dmz", "home"]},
    "dmz": {"type": "dmz", "state": "Mandatory", "typeId": "6", "subId": "0",
             "vlantag": 610, "ip": "10.6.0.0/24", "bridge": "lan",
             "access-to": ["internet"], "pinhole-allowed-from": ["internet"]},
    "home": {"type": "client", "state": "Active", "typeId": "3", "subId": "10",
              "vlantag": 310, "ip": "10.3.10.0/24", "bridge": "lan",
              "access-to": ["internet"], "pinhole-allowed-from": []},
}

LITELLM_FIXTURE = {
    "vmname": "litellm",
    "zone0": "srvWork",
    "bridge0": "lan",
    "ports": [
        {"port": 4000, "protocol": "TCP", "description": "API"},
    ],
    "ingress": [
        {"from": "srvWork", "ports": [4000], "description": "Intra-zone"},
        {"from": "dmz", "ports": [4000], "description": "Reverse proxy"},
    ],
    "egress": [
        {"to": "alias:llm_providers", "ports": [443], "description": "Upstream"},
        {"to": "vllm", "ports": [11434], "description": "Local inference"},
    ],
    "aliases": {
        "llm_providers": {
            "type": "host",
            "addresses": ["api.example.com"],
            "description": "Whitelist",
        }
    },
}

VLLM_FIXTURE = {
    "vmname": "vllm",
    "zone0": "srvWork",
    "bridge0": "lan",
    "ports": [{"port": 11434, "protocol": "TCP"}],
}


# ─────────────────────────────────────────────────────────────────────────────
# Helpers under test
# ─────────────────────────────────────────────────────────────────────────────


class TestHelpers(unittest.TestCase):
    def test_stable_hash_index_deterministic(self):
        self.assertEqual(stable_hash_index("litellm"), stable_hash_index("litellm"))

    def test_stable_hash_index_range(self):
        for name in ["a", "vaultwarden", "hassosova", "x-y-z"]:
            self.assertTrue(0 <= stable_hash_index(name) < 100)

    def test_canonical_description_tcp_omits_protocol(self):
        self.assertEqual(
            _canonical_description("litellm", "ingress", "srvWork", 4000, "TCP"),
            "tappaas-module:litellm:ingress:srvWork:4000",
        )

    def test_canonical_description_non_tcp_includes_protocol(self):
        self.assertEqual(
            _canonical_description("hassosova", "egress", "iot-home", 5353, "UDP"),
            "tappaas-module:hassosova:egress:iot-home:5353/UDP",
        )

    def test_module_alias_name(self):
        # Short names (< 28 chars): plain tm_ alias; hyphens normalised to _.
        self.assertEqual(_module_alias_name("vllm-amd"), "tm_vllm_amd")
        self.assertEqual(_module_alias_name("vllm"), "tm_vllm")
        # A 19-char name stays plain under the 28-char threshold.
        self.assertEqual(_module_alias_name("nextcloud-acme-corp"), "tm_nextcloud_acme_corp")
        # A name at/above 28 chars gets a readable prefix + 6-hex hash, <=32.
        long_alias = _module_alias_name("nextcloud-customer-environment-one")
        self.assertLessEqual(len(long_alias), 32)
        self.assertTrue(long_alias.startswith("tm_"))
        self.assertLessEqual(len(_module_alias_name("a" * 50)), 32)

    def test_module_alias_name_deterministic_and_collision_free(self):
        # Hashing is deterministic and distinguishes >=28-char names that share
        # their first sanitised chars (truncation would have collided them).
        self.assertEqual(
            _module_alias_name("nextcloud-customer-environment-one"),
            _module_alias_name("nextcloud-customer-environment-one"),
        )
        self.assertNotEqual(
            _module_alias_name("nextcloud-customer-environment-one"),
            _module_alias_name("nextcloud-customer-environment-two"),
        )

    def test_normalize_protocol_default_tcp(self):
        self.assertEqual(_normalize_protocol(None), "TCP")
        self.assertEqual(_normalize_protocol(""), "TCP")

    def test_normalize_protocol_passthrough(self):
        self.assertEqual(_normalize_protocol("udp"), "UDP")
        self.assertEqual(_normalize_protocol("ICMP"), "ICMP")

    def test_normalize_protocol_tcp_udp_canonical(self):
        for value in ["tcp/udp", "TCP-UDP", "both"]:
            self.assertEqual(_normalize_protocol(value), "TCP/UDP")


# ─────────────────────────────────────────────────────────────────────────────
# Loaders
# ─────────────────────────────────────────────────────────────────────────────


class TestLoaders(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        (self.dir / "zones.json").write_text(json.dumps(ZONES_FIXTURE))
        (self.dir / "litellm.json").write_text(json.dumps(LITELLM_FIXTURE))
        (self.dir / "aliases.json").write_text(json.dumps({
            "private_ranges": {
                "type": "network",
                "addresses": ["10.0.0.0/8"],
                "description": "RFC1918",
            },
            "_comment": "ignored",
        }))

    def tearDown(self):
        self.tmp.cleanup()

    def test_load_zones(self):
        zones = load_zones(self.dir / "zones.json")
        self.assertIn("srvWork", zones)
        self.assertEqual(zones["srvWork"].ip_network, "10.2.10.0/24")
        self.assertEqual(zones["srvWork"].vlan_tag, 210)
        self.assertIn("dmz", zones["srvWork"].pinhole_allowed_from)

    def test_load_module(self):
        mod = load_module(self.dir, "litellm")
        self.assertEqual(mod.vmname, "litellm")
        self.assertEqual(mod.zone0, "srvWork")
        self.assertEqual(len(mod.ingress), 2)
        self.assertIn("llm_providers", mod.aliases)

    def test_load_module_missing(self):
        with self.assertRaises(FileNotFoundError):
            load_module(self.dir, "does-not-exist")

    def test_load_global_aliases_filters_non_dict(self):
        aliases = load_global_aliases(self.dir / "aliases.json")
        self.assertIn("private_ranges", aliases)
        self.assertNotIn("_comment", aliases)

    def test_load_global_aliases_missing(self):
        self.assertEqual(load_global_aliases(self.dir / "nope.json"), {})


# ─────────────────────────────────────────────────────────────────────────────
# Validation
# ─────────────────────────────────────────────────────────────────────────────


def _make_manager(zones=None, modules_dir=None, global_aliases=None, firewall_type="opnsense"):
    """Build a RulesManager without connecting."""
    config = Config(firewall="example.invalid", ssl_verify=False)
    mgr = RulesManager(
        config=config,
        zones=zones or {n: ZoneSpec(name=n, ip_network=z.get("ip", ""),
                                      bridge=z.get("bridge", "lan"),
                                      vlan_tag=z.get("vlantag", 0),
                                      access_to=z.get("access-to", []),
                                      pinhole_allowed_from=z.get("pinhole-allowed-from", []))
                          for n, z in ZONES_FIXTURE.items()},
        modules_dir=modules_dir or Path("/tmp"),
        global_aliases=global_aliases or {},
        sequence_map_file=None,
        firewall_type=firewall_type,
    )
    return mgr


class TestValidation(unittest.TestCase):
    def _module(self, **overrides) -> ModuleSpec:
        base = dict(
            vmname="litellm", zone0="srvWork", bridge0="lan",
            ports=[{"port": 4000, "protocol": "TCP"}],
            ingress=[], egress=[], aliases={}, firewall_type="opnsense",
        )
        base.update(overrides)
        return ModuleSpec(**base)

    def test_valid_module_has_no_errors(self):
        mgr = _make_manager()
        mod = self._module(ingress=[{"from": "srvWork", "ports": [4000], "description": "ok"}])
        self.assertEqual(mgr._validate(mod), [])

    def test_policy_violation_rejected(self):
        # iotCams not in srvWork.pinhole-allowed-from
        zones = ZONES_FIXTURE.copy()
        zones["iotCams"] = {
            **ZONES_FIXTURE["home"], "ip": "10.4.30.0/24",
            "access-to": [], "pinhole-allowed-from": []
        }
        mgr = _make_manager(zones={
            n: ZoneSpec(name=n, ip_network=z.get("ip", ""),
                          bridge=z.get("bridge", "lan"),
                          vlan_tag=z.get("vlantag", 0),
                          access_to=z.get("access-to", []),
                          pinhole_allowed_from=z.get("pinhole-allowed-from", []))
            for n, z in zones.items()
        })
        mod = self._module(ingress=[{"from": "iotCams", "ports": [4000], "description": "x"}])
        errors = mgr._validate(mod)
        self.assertTrue(any("violates policy" in e.message for e in errors), errors)

    def test_port_consistency_required(self):
        mgr = _make_manager()
        # Ingress declares port 5000 not in module.ports[]
        mod = self._module(ingress=[{"from": "srvWork", "ports": [5000], "description": "x"}])
        errors = mgr._validate(mod)
        self.assertTrue(any("not declared in module.ports" in e.message for e in errors), errors)

    def test_missing_description_rejected(self):
        mgr = _make_manager()
        mod = self._module(ingress=[{"from": "srvWork", "ports": [4000]}])
        errors = mgr._validate(mod)
        self.assertTrue(any("missing 'description'" in e.message for e in errors), errors)

    def test_unknown_peer_rejected(self):
        # tmp dir does not contain hypothetical-module.json
        with tempfile.TemporaryDirectory() as tmp:
            mgr = _make_manager(modules_dir=Path(tmp))
            mod = self._module(ingress=[
                {"from": "ghost-module", "ports": [4000], "description": "x"}
            ])
            errors = mgr._validate(mod)
            self.assertTrue(any("not a known zone, alias, or module" in e.message
                                  for e in errors), errors)

    def test_alias_peer_accepted_when_module_local(self):
        mgr = _make_manager()
        mod = self._module(
            aliases={"providers": {"type": "host", "addresses": ["x"], "description": "y"}},
            egress=[{"to": "alias:providers", "ports": [443], "description": "x"}],
        )
        self.assertEqual(mgr._validate(mod), [])

    def test_alias_peer_rejected_when_undefined(self):
        mgr = _make_manager()
        mod = self._module(egress=[
            {"to": "alias:missing", "ports": [443], "description": "x"}
        ])
        errors = mgr._validate(mod)
        self.assertTrue(any("alias 'missing' not found" in e.message for e in errors), errors)


# ─────────────────────────────────────────────────────────────────────────────
# Compilation
# ─────────────────────────────────────────────────────────────────────────────


class TestCompile(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        (self.dir / "litellm.json").write_text(json.dumps(LITELLM_FIXTURE))
        (self.dir / "vllm.json").write_text(json.dumps(VLLM_FIXTURE))
        self.mgr = _make_manager(modules_dir=self.dir)

    def tearDown(self):
        self.tmp.cleanup()

    def test_compile_produces_correct_descriptions(self):
        mod = load_module(self.dir, "litellm")
        rules, errors = self.mgr._compile(mod)
        self.assertEqual(errors, [])
        descs = {r.description for r in rules}
        self.assertIn("tappaas-module:litellm:ingress:srvWork:4000", descs)
        self.assertIn("tappaas-module:litellm:ingress:dmz:4000", descs)
        self.assertIn("tappaas-module:litellm:egress:alias:llm_providers:443", descs)
        self.assertIn("tappaas-module:litellm:egress:vllm:11434", descs)

    def test_compile_is_idempotent(self):
        mod = load_module(self.dir, "litellm")
        rules1, _ = self.mgr._compile(mod)
        rules2, _ = self.mgr._compile(mod)
        self.assertEqual([r.description for r in rules1],
                         [r.description for r in rules2])
        self.assertEqual([r.sequence for r in rules1],
                         [r.sequence for r in rules2])

    def test_module_peer_resolved_via_fqdn_alias(self):
        """An egress entry referencing another module's name must point at
        the FQDN-alias (tm_<peer>), not a literal IP."""
        mod = load_module(self.dir, "litellm")
        rules, _ = self.mgr._compile(mod)
        egress_to_vllm = next(r for r in rules if r.peer == "vllm" and r.direction == "egress")
        self.assertEqual(egress_to_vllm.destination_net, "tm_vllm")

    def test_self_destination_is_module_alias(self):
        """Ingress destination is the module's own FQDN alias."""
        mod = load_module(self.dir, "litellm")
        rules, _ = self.mgr._compile(mod)
        ingress = next(r for r in rules if r.direction == "ingress")
        self.assertEqual(ingress.destination_net, "tm_litellm")

    def test_zone_peer_resolved_to_cidr(self):
        mod = load_module(self.dir, "litellm")
        rules, _ = self.mgr._compile(mod)
        ingress_srv = next(r for r in rules if r.peer == "srvWork")
        self.assertEqual(ingress_srv.source_net, "10.2.10.0/24")

    def test_peer_module_fqdn_alias_generated(self):
        mod = load_module(self.dir, "litellm")
        aliases = self.mgr._module_aliases_to_provision(mod)
        # Self alias — host type, FQDN content
        self_alias = aliases["tm_litellm"]
        self.assertEqual(self_alias.alias_type, "host")
        self.assertEqual(self_alias.content, ["litellm.srvWork.internal"])
        # Peer (egress to vllm)
        peer_alias = aliases["tm_vllm"]
        self.assertEqual(peer_alias.alias_type, "host")
        self.assertEqual(peer_alias.content, ["vllm.srvWork.internal"])


# ─────────────────────────────────────────────────────────────────────────────
# aliasType: host vs network (issue #241)
# ─────────────────────────────────────────────────────────────────────────────


class TestAliasType(unittest.TestCase):
    def _module(self, **overrides) -> ModuleSpec:
        base = dict(
            vmname="sonos-fleet", zone0="srvWork", bridge0="lan",
            ports=[], ingress=[], egress=[], aliases={}, firewall_type="opnsense",
        )
        base.update(overrides)
        return ModuleSpec(**base)

    def test_load_module_defaults_alias_type_host(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "vllm.json").write_text(json.dumps(VLLM_FIXTURE))
            self.assertEqual(load_module(d, "vllm").alias_type, "host")

    def test_load_module_reads_alias_type_network(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "sonos.json").write_text(json.dumps(
                {"vmname": "sonos", "zone0": "srvWork", "aliasType": "network"}
            ))
            self.assertEqual(load_module(d, "sonos").alias_type, "network")

    def test_self_alias_network_targets_zone_subnet(self):
        mgr = _make_manager()
        mod = self._module(alias_type="network")
        aliases = mgr._module_aliases_to_provision(mod)
        target = aliases["tm_sonos_fleet"]
        self.assertEqual(target.alias_type, "network")
        self.assertEqual(target.content, ["10.2.10.0/24"])

    def test_self_alias_host_unchanged(self):
        mgr = _make_manager()
        target = mgr._module_aliases_to_provision(self._module())["tm_sonos_fleet"]
        self.assertEqual(target.alias_type, "host")
        self.assertEqual(target.content, ["sonos-fleet.srvWork.internal"])

    def test_peer_alias_honors_peer_network_type(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "sonos-fleet.json").write_text(json.dumps(
                {"vmname": "sonos-fleet", "zone0": "srvWork", "aliasType": "network"}
            ))
            mgr = _make_manager(modules_dir=d)
            consumer = self._module(
                vmname="hass", egress=[{"to": "sonos-fleet", "ports": [1400], "description": "x"}]
            )
            aliases = mgr._module_aliases_to_provision(consumer)
            peer = aliases["tm_sonos_fleet"]
            self.assertEqual(peer.alias_type, "network")
            self.assertEqual(peer.content, ["10.2.10.0/24"])

    def test_validate_network_requires_zone_subnet(self):
        # A zone present in the map but with an empty subnet → error.
        zones = {n: ZoneSpec(name=n, ip_network=z.get("ip", ""), bridge="lan",
                             vlan_tag=z.get("vlantag", 0), access_to=z.get("access-to", []),
                             pinhole_allowed_from=z.get("pinhole-allowed-from", []))
                 for n, z in ZONES_FIXTURE.items()}
        zones["nosubnet"] = ZoneSpec(name="nosubnet", ip_network="", bridge="lan",
                                     vlan_tag=0, access_to=[], pinhole_allowed_from=[])
        mgr = _make_manager(zones=zones)
        mod = self._module(zone0="nosubnet", alias_type="network")
        errors = mgr._validate(mod)
        self.assertTrue(any("requires zone0" in e.message for e in errors), errors)

    def test_validate_network_ok_with_subnet(self):
        mgr = _make_manager()
        mod = self._module(alias_type="network")
        self.assertFalse(any(e.path == "aliasType" for e in mgr._validate(mod)))

    def test_validate_unknown_alias_type_rejected(self):
        mgr = _make_manager()
        mod = self._module(alias_type="bogus")
        errors = mgr._validate(mod)
        self.assertTrue(any(e.path == "aliasType" for e in errors), errors)


# ─────────────────────────────────────────────────────────────────────────────
# Description suffix: verify + reconcile-prune match on canonical part (#246)
# ─────────────────────────────────────────────────────────────────────────────


def _live_from_compiled(mgr, rules) -> list[FirewallRuleInfo]:
    """Build the FirewallRuleInfo a fresh add-rules would leave in OPNsense:
    descriptions carry the ' | <freetext>' suffix from _to_firewall_rule."""
    live = []
    for i, r in enumerate(rules):
        fw_rule = mgr._to_firewall_rule(r)
        live.append(FirewallRuleInfo(
            uuid=f"U{i}", description=fw_rule.description, enabled=True,
            action="pass", interface=fw_rule.interface, direction="in",
            protocol="TCP", source_net=fw_rule.source_net, source_port=None,
            destination_net=fw_rule.destination_net, destination_port=None,
            log=True, sequence=fw_rule.sequence,
        ))
    return live


class TestCanonicalPart(unittest.TestCase):
    def test_strips_freetext_suffix(self):
        self.assertEqual(
            _canonical_part("tappaas-module:alfen:ingress:home:80 | Alfen web UI"),
            "tappaas-module:alfen:ingress:home:80",
        )

    def test_no_suffix_unchanged(self):
        self.assertEqual(
            _canonical_part("tappaas-module:alfen:ingress:home:80"),
            "tappaas-module:alfen:ingress:home:80",
        )

    def test_freetext_with_pipe_only_splits_once(self):
        self.assertEqual(
            _canonical_part("tappaas-module:x:egress:y:443 | note | extra"),
            "tappaas-module:x:egress:y:443",
        )


class TestVerifyAndPruneSuffix(unittest.TestCase):
    """A described rule (freetext suffix) must verify clean and survive reconcile."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        (self.dir / "litellm.json").write_text(json.dumps(LITELLM_FIXTURE))
        (self.dir / "vllm.json").write_text(json.dumps(VLLM_FIXTURE))
        self.mgr = _make_manager(modules_dir=self.dir)

    def tearDown(self):
        self.tmp.cleanup()

    def test_verify_reports_described_rules_present(self):
        desired, _ = self.mgr._compile(load_module(self.dir, "litellm"))
        live = _live_from_compiled(self.mgr, desired)
        self.mgr._list_owned_rules = lambda name: live
        result = self.mgr.verify_rules("litellm")
        self.assertEqual(result.desired, len(desired))
        self.assertEqual(result.present, len(desired))
        self.assertEqual(result.missing, [])
        self.assertEqual(result.extra, [])
        self.assertTrue(result.ok)

    def test_reconcile_keeps_valid_described_rules(self):
        desired, _ = self.mgr._compile(load_module(self.dir, "litellm"))
        live = _live_from_compiled(self.mgr, desired)
        self.mgr._list_owned_rules = lambda name: live
        self.mgr._write_sequence_map = lambda *a, **k: None
        fw = MagicMock()
        fw.create_savepoint.return_value = "rev"
        deleted = []
        fw.delete_rule_by_uuid.side_effect = lambda uuid, apply=False: deleted.append(uuid)
        self.mgr._fw = fw
        result = self.mgr._apply("litellm", prune=True)
        self.assertEqual(result.applied, len(desired))
        self.assertEqual(deleted, [])          # nothing pruned
        self.assertEqual(result.deleted, 0)

    def test_reconcile_prunes_a_truly_removed_rule(self):
        desired, _ = self.mgr._compile(load_module(self.dir, "litellm"))
        live = _live_from_compiled(self.mgr, desired)
        # An orphan that is NOT in the desired set must still be pruned.
        live.append(FirewallRuleInfo(
            uuid="ORPHAN", description="tappaas-module:litellm:ingress:home:9999 | stale",
            enabled=True, action="pass", interface="opt1", direction="in",
            protocol="TCP", source_net="x", source_port=None,
            destination_net="y", destination_port=None, log=True, sequence=10099,
        ))
        self.mgr._list_owned_rules = lambda name: live
        self.mgr._write_sequence_map = lambda *a, **k: None
        fw = MagicMock()
        fw.create_savepoint.return_value = "rev"
        deleted = []
        fw.delete_rule_by_uuid.side_effect = lambda uuid, apply=False: deleted.append(uuid)
        self.mgr._fw = fw
        result = self.mgr._apply("litellm", prune=True)
        self.assertEqual(deleted, ["ORPHAN"])
        self.assertEqual(result.deleted, 1)


# ─────────────────────────────────────────────────────────────────────────────
# Auto-pinholes (issue #173)
# ─────────────────────────────────────────────────────────────────────────────


class TestAutoPinholes(unittest.TestCase):
    """End-to-end-ish tests for the dependsOn-driven auto-pinhole compile path.

    Each test builds a temp modules dir with a consumer+provider pair, optionally
    drops a pinhole.json under the provider's `location`, and exercises
    ``_compile`` directly (no OPNsense connection needed).
    """

    def _make_zones(self, **overrides):
        """Default zone topology: srvWork, dmz, home — see ZONES_FIXTURE.

        Overrides let individual tests tweak access-to / pinhole-allowed-from
        without redefining the whole map.
        """
        zones = {}
        for n, z in ZONES_FIXTURE.items():
            zones[n] = ZoneSpec(
                name=n,
                ip_network=z.get("ip", ""),
                bridge=z.get("bridge", "lan"),
                vlan_tag=z.get("vlantag", 0),
                access_to=list(z.get("access-to", [])),
                pinhole_allowed_from=list(z.get("pinhole-allowed-from", [])),
            )
        for name, attrs in overrides.items():
            existing = zones.get(name)
            if not existing:
                continue
            for k, v in attrs.items():
                setattr(existing, k, list(v))
        return zones

    def _write_provider(
        self,
        dir_: Path,
        *,
        vmname: str,
        zone0: str,
        pinhole_ports: list[dict] | None,
        service: str = "api",
    ):
        """Create <vmname>.json + (optionally) services/<service>/pinhole.json."""
        location = dir_ / f"{vmname}-src"
        location.mkdir(parents=True, exist_ok=True)
        (dir_ / f"{vmname}.json").write_text(json.dumps({
            "vmname": vmname,
            "zone0": zone0,
            "bridge0": "lan",
            "location": str(location),
            "ports": [{"port": p["port"], "protocol": p.get("protocol", "TCP")}
                      for p in (pinhole_ports or [])],
        }))
        if pinhole_ports is not None:
            svc_dir = location / "services" / service
            svc_dir.mkdir(parents=True, exist_ok=True)
            (svc_dir / "pinhole.json").write_text(json.dumps({"ports": pinhole_ports}))
        return location

    def _write_consumer(
        self,
        dir_: Path,
        *,
        vmname: str,
        zone0: str,
        depends_on: list[str],
    ):
        (dir_ / f"{vmname}.json").write_text(json.dumps({
            "vmname": vmname,
            "zone0": zone0,
            "bridge0": "lan",
            "dependsOn": depends_on,
        }))

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    # ── happy path ───────────────────────────────────────────────────────

    def test_cross_zone_dependency_emits_auto_pinhole(self):
        # dmz -> srvWork: dmz IS in srvWork.pinhole-allowed-from
        # dmz is NOT in srvWork.access-to → policy permits, no zone shortcut
        # → auto-pinhole expected.
        self._write_provider(
            self.dir, vmname="api", zone0="srvWork",
            pinhole_ports=[{"port": 4000, "protocol": "TCP", "description": "API"}],
            service="rest",
        )
        self._write_consumer(
            self.dir, vmname="ui", zone0="dmz",
            depends_on=["api:rest", "cluster:vm"],
        )
        mgr = _make_manager(zones=self._make_zones(), modules_dir=self.dir)
        rules, errors = mgr._compile(load_module(self.dir, "ui"))
        self.assertEqual(errors, [])
        descs = [r.description for r in rules]
        self.assertIn("tappaas-svcdep:ui:rest:api:4000", descs)
        rule = next(r for r in rules if r.description.startswith("tappaas-svcdep:"))
        # Owner is the consumer
        self.assertEqual(rule.module_name, "ui")
        # Source is consumer's self alias, destination is provider's alias
        self.assertEqual(rule.source_net, "tm_ui")
        self.assertEqual(rule.destination_net, "tm_api")
        # Sequence is in ingress band, in ui's slot
        self.assertGreaterEqual(rule.sequence, BAND_INGRESS_BASE)
        self.assertLess(rule.sequence, BAND_EGRESS_BASE)
        slot = stable_hash_index("ui")
        self.assertEqual(rule.sequence, BAND_INGRESS_BASE + slot * SLOT_SIZE)

    def test_multiple_ports_emit_multiple_rules(self):
        self._write_provider(
            self.dir, vmname="api", zone0="srvWork",
            pinhole_ports=[
                {"port": 80,  "protocol": "TCP", "description": "HTTP"},
                {"port": 443, "protocol": "TCP", "description": "HTTPS"},
            ],
            service="web",
        )
        self._write_consumer(
            self.dir, vmname="ui", zone0="dmz",
            depends_on=["api:web"],
        )
        mgr = _make_manager(zones=self._make_zones(), modules_dir=self.dir)
        rules, _ = mgr._compile(load_module(self.dir, "ui"))
        descs = {r.description for r in rules}
        self.assertIn("tappaas-svcdep:ui:web:api:80", descs)
        self.assertIn("tappaas-svcdep:ui:web:api:443", descs)

    def test_non_tcp_protocol_appears_in_description(self):
        self._write_provider(
            self.dir, vmname="dns", zone0="srvWork",
            pinhole_ports=[{"port": 53, "protocol": "UDP"}], service="resolver",
        )
        self._write_consumer(
            self.dir, vmname="ui", zone0="dmz",
            depends_on=["dns:resolver"],
        )
        mgr = _make_manager(zones=self._make_zones(), modules_dir=self.dir)
        rules, _ = mgr._compile(load_module(self.dir, "ui"))
        descs = {r.description for r in rules}
        self.assertIn("tappaas-svcdep:ui:resolver:dns:53/UDP", descs)

    # ── skip predicates ──────────────────────────────────────────────────

    def test_intra_zone_dependency_emits_no_pinhole(self):
        self._write_provider(
            self.dir, vmname="api", zone0="srvWork",
            pinhole_ports=[{"port": 4000}], service="rest",
        )
        self._write_consumer(
            self.dir, vmname="ui", zone0="srvWork",  # same zone!
            depends_on=["api:rest"],
        )
        mgr = _make_manager(zones=self._make_zones(), modules_dir=self.dir)
        rules, _ = mgr._compile(load_module(self.dir, "ui"))
        self.assertFalse(any(r.description.startswith("tappaas-svcdep:") for r in rules))

    def test_access_to_covers_traffic_so_no_pinhole_needed(self):
        # Make dmz appear in srvWork.access-to → zone-level rule already
        # permits the traffic; the per-module pinhole is redundant.
        zones = self._make_zones(**{"srvWork": {"access_to": ["internet", "dmz"]}})
        self._write_provider(
            self.dir, vmname="api", zone0="srvWork",
            pinhole_ports=[{"port": 4000}], service="rest",
        )
        self._write_consumer(
            self.dir, vmname="ui", zone0="dmz",
            depends_on=["api:rest"],
        )
        mgr = _make_manager(zones=zones, modules_dir=self.dir)
        rules, _ = mgr._compile(load_module(self.dir, "ui"))
        self.assertFalse(any(r.description.startswith("tappaas-svcdep:") for r in rules))

    def testPinhole_allowed_from_violation_warns_and_skips(self):
        # Override srvWork.pinhole-allowed-from to NOT include 'home',
        # so the consumer (home) can't pinhole into srvWork.
        # Per #173 design: skip with a warning, do not hard-error.
        zones = self._make_zones(**{
            "srvWork": {"pinhole_allowed_from": ["srvWork", "dmz"]},
        })
        self._write_provider(
            self.dir, vmname="api", zone0="srvWork",
            pinhole_ports=[{"port": 4000}], service="rest",
        )
        self._write_consumer(
            self.dir, vmname="ui", zone0="home",
            depends_on=["api:rest"],
        )
        mgr = _make_manager(zones=zones, modules_dir=self.dir)
        rules, errors = mgr._compile(load_module(self.dir, "ui"))
        # No errors — it's a warning, not an error
        self.assertEqual(errors, [])
        self.assertFalse(any(r.description.startswith("tappaas-svcdep:") for r in rules))

    def test_service_without_pinhole_json_is_a_noop(self):
        # Provider has no pinhole.json for the 'metrics' service → no rule.
        self._write_provider(
            self.dir, vmname="api", zone0="srvWork",
            pinhole_ports=None, service="metrics",  # no pinhole.json written
        )
        self._write_consumer(
            self.dir, vmname="ui", zone0="dmz",
            depends_on=["api:metrics"],
        )
        mgr = _make_manager(zones=self._make_zones(), modules_dir=self.dir)
        rules, _ = mgr._compile(load_module(self.dir, "ui"))
        self.assertFalse(any(r.description.startswith("tappaas-svcdep:") for r in rules))

    # ── alias provisioning ───────────────────────────────────────────────

    def test_auto_pinhole_provider_alias_is_provisioned(self):
        # The provider must show up in _module_aliases_to_provision so that
        # OPNsense gets its FQDN alias before any rule references it.
        self._write_provider(
            self.dir, vmname="api", zone0="srvWork",
            pinhole_ports=[{"port": 4000}], service="rest",
        )
        self._write_consumer(
            self.dir, vmname="ui", zone0="dmz",
            depends_on=["api:rest"],
        )
        mgr = _make_manager(zones=self._make_zones(), modules_dir=self.dir)
        consumer = load_module(self.dir, "ui")
        aliases = mgr._module_aliases_to_provision(consumer)
        self.assertEqual(aliases["tm_api"].content, ["api.srvWork.internal"])
        # And self alias is still emitted
        self.assertEqual(aliases["tm_ui"].content, ["ui.dmz.internal"])


# ─────────────────────────────────────────────────────────────────────────────
# Sequence allocation
# ─────────────────────────────────────────────────────────────────────────────


class TestSequenceAllocation(unittest.TestCase):
    def test_ingress_band(self):
        mgr = _make_manager()
        slot = stable_hash_index("litellm")
        seq = mgr._assign_sequence("ingress", slot, 0)
        self.assertEqual(seq, BAND_INGRESS_BASE + slot * SLOT_SIZE)

    def test_egress_band(self):
        mgr = _make_manager()
        slot = stable_hash_index("hassosova")
        seq = mgr._assign_sequence("egress", slot, 3)
        self.assertEqual(seq, BAND_EGRESS_BASE + slot * SLOT_SIZE + 3)

    def test_slot_exhaustion_returns_none(self):
        mgr = _make_manager()
        self.assertIsNone(mgr._assign_sequence("ingress", 0, SLOT_SIZE))

    def test_different_modules_get_different_slots_likely(self):
        # Not a strict guarantee, but should hold for common names
        slots = {stable_hash_index(n) for n in
                 ["vaultwarden", "litellm", "hassosova", "nextcloud", "openwebui"]}
        self.assertTrue(len(slots) >= 4, slots)


# ─────────────────────────────────────────────────────────────────────────────
# Peer resolution edge cases
# ─────────────────────────────────────────────────────────────────────────────


class TestPeerResolution(unittest.TestCase):
    def setUp(self):
        self.mgr = _make_manager()
        self.module = ModuleSpec(
            vmname="litellm", zone0="srvWork", bridge0="lan",
            ports=[], ingress=[], egress=[], aliases={}, firewall_type="opnsense",
        )

    def test_internet_resolves_to_any(self):
        self.assertEqual(self.mgr._resolve_peer_net("internet", self.module), "any")

    def test_alias_prefix_stripped(self):
        self.assertEqual(self.mgr._resolve_peer_net("alias:foo", self.module), "foo")

    def test_zone_resolves_to_cidr(self):
        self.assertEqual(self.mgr._resolve_peer_net("dmz", self.module), "10.6.0.0/24")

    def test_module_name_resolves_to_alias(self):
        self.assertEqual(self.mgr._resolve_peer_net("some-module", self.module),
                         "tm_some_module")


# ─────────────────────────────────────────────────────────────────────────────
# NONE firewall type — no connection, no errors
# ─────────────────────────────────────────────────────────────────────────────


class TestNoneFirewallType(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        (self.dir / "litellm.json").write_text(json.dumps(LITELLM_FIXTURE))
        (self.dir / "vllm.json").write_text(json.dumps(VLLM_FIXTURE))

    def tearDown(self):
        self.tmp.cleanup()

    def test_add_rules_in_none_mode_does_not_connect(self):
        mgr = _make_manager(modules_dir=self.dir, firewall_type="NONE")
        # No connect() called — no FirewallManager interactions expected
        result = mgr.add_rules("litellm")
        self.assertEqual(result.applied, 0)
        self.assertEqual(result.errors, [])

    def test_is_none_mode_true(self):
        mgr = _make_manager(firewall_type="NONE")
        self.assertTrue(mgr.is_none_mode)

    def test_is_none_mode_default_false(self):
        mgr = _make_manager(firewall_type="opnsense")
        self.assertFalse(mgr.is_none_mode)


# ─────────────────────────────────────────────────────────────────────────────
# Global flag position (#253): flags must be honored both before and after the
# subcommand token, not silently reset to the subparser's default.
# ─────────────────────────────────────────────────────────────────────────────
class TestGlobalFlagPosition(unittest.TestCase):
    def _parse(self, argv):
        """Run main() with a fake argv, capturing the parsed namespace.

        _build_manager and _dispatch are stubbed so nothing touches OPNsense;
        we only care about how the argument parser populated the namespace.
        """
        captured = {}

        def fake_build(args):
            captured["args"] = args
            return MagicMock(__enter__=lambda s: s, __exit__=lambda *a: False)

        with patch.object(rm.sys, "argv", ["rules-manager", *argv]), \
                patch.object(rm, "_build_manager", side_effect=fake_build), \
                patch.object(rm, "_dispatch", return_value=0):
            rm.main()
        return captured["args"]

    def test_no_ssl_verify_before_subcommand(self):
        args = self._parse(["--no-ssl-verify", "reconcile", "homeassistant"])
        self.assertTrue(args.no_ssl_verify)

    def test_no_ssl_verify_after_subcommand(self):
        args = self._parse(["reconcile", "--no-ssl-verify", "homeassistant"])
        self.assertTrue(args.no_ssl_verify)

    def test_no_ssl_verify_default_false(self):
        args = self._parse(["reconcile", "homeassistant"])
        self.assertFalse(args.no_ssl_verify)

    def test_firewall_value_before_subcommand(self):
        args = self._parse(["--firewall", "fw.example", "reconcile", "homeassistant"])
        self.assertEqual(args.firewall, "fw.example")

    def test_firewall_value_after_subcommand(self):
        args = self._parse(["reconcile", "--firewall", "fw.example", "homeassistant"])
        self.assertEqual(args.firewall, "fw.example")


if __name__ == "__main__":
    unittest.main()
