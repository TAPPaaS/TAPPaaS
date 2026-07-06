"""Offline unit tests for answer.toml rendering + the POST /answer core.

Golden-ish assertions on the rendered TOML (fqdn, zfs raid mapping,
disk-list, credentials, ext4 TODO fallback) and the end-to-end answer flow
(handle_answer_post): MAC hit -> 200 + one-shot consumption + 0600 secret,
no match -> 404 leaving registrations pending.
"""

from __future__ import annotations

import stat
import tempfile
import unittest
from pathlib import Path

from node_provisioner.answer import (
    answer_settings_from_site,
    render_answer,
)
from node_provisioner.registry import Registry
from node_provisioner.server import (
    extract_macs,
    extract_serial,
    handle_answer_post,
    write_node_secret,
)

POOL = {"name": "tanka1", "layout": "single", "disks": ["nvme0n1"]}
MIRROR = {"name": "tankb1", "layout": "mirror", "disks": ["sdb", "sdc"]}


class TestRenderAnswer(unittest.TestCase):
    def _render(self, **kwargs):
        defaults = dict(
            name="tappaas3",
            domain="mgmt.internal",
            root_password="s3cret-Pass",
            ssh_keys=["ssh-ed25519 AAAA cicd@tappaas"],
            pools=[POOL],
            country="dk",
            tz="Europe/Copenhagen",
            mailto="ops@example.org",
        )
        defaults.update(kwargs)
        return render_answer(**defaults)

    def test_global_section(self):
        out = self._render()
        self.assertIn('[global]', out)
        self.assertIn('fqdn = "tappaas3.mgmt.internal"', out)
        self.assertIn('country = "dk"', out)
        self.assertIn('timezone = "Europe/Copenhagen"', out)
        self.assertIn('mailto = "ops@example.org"', out)
        self.assertIn('root-password = "s3cret-Pass"', out)
        self.assertIn('root-ssh-keys = ["ssh-ed25519 AAAA cicd@tappaas"]', out)

    def test_network_from_dhcp(self):
        self.assertIn('source = "from-dhcp"', self._render())

    def test_zfs_raid0_for_declared_single_pool(self):
        out = self._render()
        self.assertIn('filesystem = "zfs"', out)
        self.assertIn('zfs.raid = "raid0"', out)
        self.assertIn('disk-list = ["nvme0n1"]', out)

    def test_mirror_maps_to_raid1_and_extra_pools_noted(self):
        out = self._render(pools=[MIRROR, POOL])
        self.assertIn('zfs.raid = "raid1"', out)
        self.assertIn('disk-list = ["sdb", "sdc"]', out)
        self.assertIn("tanka1", out)  # extra pool noted as post-join work

    def test_no_pools_falls_back_to_ext4_with_todo(self):
        out = self._render(pools=[])
        self.assertIn('filesystem = "ext4"', out)
        self.assertIn("TODO(V-2)", out)
        self.assertNotIn('filesystem = "zfs"', out)

    def test_mailto_defaults_from_domain(self):
        out = self._render(mailto="")
        self.assertIn('mailto = "root@mgmt.internal"', out)

    def test_toml_escaping(self):
        out = self._render(root_password='pw"with\\quotes')
        self.assertIn('root-password = "pw\\"with\\\\quotes"', out)


class TestAnswerSettingsFromSite(unittest.TestCase):
    def test_extracts_location_and_email(self):
        site = {"email": "admin@acme.example",
                "location": {"country": "NL", "timezone": "Europe/Amsterdam"}}
        self.assertEqual(
            answer_settings_from_site(site),
            {"country": "NL", "tz": "Europe/Amsterdam",
             "mailto": "admin@acme.example"},
        )

    def test_defaults_on_empty_site(self):
        settings = answer_settings_from_site({})
        self.assertEqual(settings["country"], "us")
        self.assertEqual(settings["tz"], "UTC")


class TestSystemInfoExtraction(unittest.TestCase):
    INFO = {
        "network_interfaces": [
            {"link": "eth0", "mac": "AA:BB:CC:DD:EE:03"},
            {"link": "eth1"},  # no mac — skipped
            {"link": "eth2", "mac": "aa:bb:cc:dd:ee:04"},
        ],
        "dmi": {"system": {"serial": "SN-1234"}},
    }

    def test_extract_macs(self):
        self.assertEqual(
            extract_macs(self.INFO),
            ["AA:BB:CC:DD:EE:03", "aa:bb:cc:dd:ee:04"],
        )

    def test_extract_macs_tolerates_missing_key(self):
        self.assertEqual(extract_macs({}), [])

    def test_extract_serial(self):
        self.assertEqual(extract_serial(self.INFO), "SN-1234")
        self.assertEqual(extract_serial({}), "unknown")


class TestWriteNodeSecret(unittest.TestCase):
    def test_secret_file_is_0600(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_node_secret("tappaas3", "pw", directory=tmp)
            self.assertEqual(path.read_text(), "pw\n")
            mode = stat.S_IMODE(path.stat().st_mode)
            self.assertEqual(mode, 0o600)
            dir_mode = stat.S_IMODE(Path(tmp).stat().st_mode)
            self.assertEqual(dir_mode, 0o700)


class TestHandleAnswerPost(unittest.TestCase):
    SITE = {"email": "ops@acme.example",
            "location": {"country": "DK", "timezone": "Europe/Copenhagen"}}

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        base = Path(self._tmp.name)
        self.registry = Registry(directory=base / "provision")
        self.secrets = base / "secrets"

    def _post(self, macs):
        info = {"network_interfaces": [{"mac": m} for m in macs],
                "dmi": {"system": {"serial": "SN-1"}}}
        return handle_answer_post(
            info, self.registry, self.SITE,
            domain="mgmt.internal", secrets_directory=self.secrets,
        )

    def test_mac_hit_serves_answer_and_consumes(self):
        self.registry.register("tappaas3", macs=["aa:bb:cc:dd:ee:03"],
                               pool_specs=["tanka1=single:nvme0n1"])
        status, body = self._post(["AA:BB:CC:DD:EE:03"])
        self.assertEqual(status, 200)
        self.assertIn('fqdn = "tappaas3.mgmt.internal"', body)
        self.assertIn('country = "dk"', body)
        self.assertIn('zfs.raid = "raid0"', body)

        # secret stored, registration one-shot consumed
        secret = self.secrets / "tappaas3.pw"
        self.assertTrue(secret.is_file())
        self.assertIn(f'root-password = "{secret.read_text().strip()}"', body)
        self.assertEqual(self.registry.list_pending(), [])

        # a second identical request finds nothing
        status2, _ = self._post(["AA:BB:CC:DD:EE:03"])
        self.assertEqual(status2, 404)

    def test_single_pending_fallback_serves(self):
        self.registry.register("tappaas4")
        status, body = self._post(["de:ad:be:ef:00:01"])
        self.assertEqual(status, 200)
        self.assertIn('fqdn = "tappaas4.mgmt.internal"', body)

    def test_no_match_is_404_and_keeps_registrations(self):
        self.registry.register("tappaas3", macs=["aa:bb:cc:dd:ee:03"])
        self.registry.register("tappaas4", macs=["aa:bb:cc:dd:ee:04"])
        status, _ = self._post(["de:ad:be:ef:00:01"])
        self.assertEqual(status, 404)
        self.assertEqual(len(self.registry.list_pending()), 2)
        self.assertFalse((self.secrets / "tappaas3.pw").exists())


if __name__ == "__main__":
    unittest.main()
