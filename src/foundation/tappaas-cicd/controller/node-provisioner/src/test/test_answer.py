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

    # ── The installer NEVER touches declared data pools ──────────────
    #
    # These three tests used to assert the opposite: that a declared pool drove
    # the installer's filesystem/zfs.raid (single -> raid0, mirror -> raid1) and
    # that disk-list held the POOL's disks. That contract is superseded — see
    # answer.py ("declared pools are post-join data pools ... the installer only
    # ever formats the boot disk (ext4/LVM)") and registry.py. The installer now
    # always lays down the TAPPaaS standard boot layout, and pools are created
    # post-join by the storage plane.
    #
    # The safety property worth pinning is the INVARIANT, not the strings: an
    # answer.toml must never instruct the installer to format a data-pool disk,
    # because doing so would wipe it during an unattended install.

    def test_boot_disk_only_ext4_regardless_of_declared_pools(self):
        out = self._render()  # POOL = single:nvme0n1
        self.assertIn('filesystem = "ext4"', out)
        self.assertIn('disk-list = ["sda"]', out, "installer must target the BOOT disk")
        self.assertNotIn("zfs.raid", out, "installer must not configure a data-pool raid level")

    def test_declared_pool_disks_are_never_in_disk_list(self):
        """The regression that matters: a pool disk in disk-list would be wiped."""
        out = self._render(pools=[MIRROR, POOL])
        disk_list = [ln for ln in out.splitlines() if ln.startswith("disk-list")]
        self.assertEqual(len(disk_list), 1, "exactly one disk-list line")
        for pool_disk in ("sdb", "sdc", "nvme0n1"):
            self.assertNotIn(pool_disk, disk_list[0],
                             f"data-pool disk {pool_disk} must never be handed to the installer")

    def test_declared_pools_are_recorded_as_a_post_join_note(self):
        out = self._render(pools=[MIRROR, POOL])
        self.assertIn("NOT created by the installer", out)
        self.assertIn("tankb1=mirror:sdb+sdc", out)
        self.assertIn("tanka1=single:nvme0n1", out)

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
        # The served answer lays down the standard boot layout and records the
        # declared pool as post-join work — it must never hand a data-pool disk
        # to the installer. (Was: assertIn 'zfs.raid = "raid0"', the superseded
        # contract where a declared pool drove the installer's raid level.)
        self.assertIn('filesystem = "ext4"', body)
        self.assertNotIn("zfs.raid", body)
        self.assertNotIn("nvme0n1", body.split("disk-list")[1].split("\n")[0])
        self.assertIn("tanka1=single:nvme0n1", body)  # noted, not installed

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
