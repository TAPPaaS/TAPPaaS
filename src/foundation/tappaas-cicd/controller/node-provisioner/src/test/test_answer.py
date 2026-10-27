"""Offline unit tests for answer.toml rendering + the POST /answer core.

Golden-ish assertions on the rendered TOML (fqdn, zfs raid mapping,
disk-list, credentials, ZFS by default and ext4 on request) and the end-to-end answer flow
(handle_answer_post): MAC hit -> 200 + one-shot consumption + 0600 secret,
no match -> 404 leaving registrations pending.
"""

from __future__ import annotations

import json
import stat
import tempfile
import unittest
from unittest import mock
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
    known_node_macs,
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

    def test_network_pinned_to_the_registered_nic(self):
        out = self._render(mgmt_mac="AA:BB:CC:DD:EE:03", mgmt_cidr="10.0.0.12/24",
                           mgmt_gateway="10.0.0.1")
        self.assertIn('source = "from-answer"', out)
        self.assertIn('cidr = "10.0.0.12/24"', out)
        self.assertIn('gateway = "10.0.0.1"', out)
        self.assertIn('filter.ID_NET_NAME_MAC = "*aabbccddee03"', out)
        self.assertNotIn("from-dhcp", out)

    # ── The installer NEVER touches declared data pools ──────────────
    #
    # These three tests used to assert the opposite: that a declared pool drove
    # the installer's filesystem/zfs.raid (single -> raid0, mirror -> raid1) and
    # that disk-list held the POOL's disks. That contract is superseded — see
    # answer.py ("declared pools are post-join data pools ... the installer only
    # ever formats the boot disk") and registry.py. The installer now
    # always lays down the TAPPaaS standard boot layout, and pools are created
    # post-join by the storage plane.
    #
    # The safety property worth pinning is the INVARIANT, not the strings: an
    # answer.toml must never instruct the installer to format a data-pool disk,
    # because doing so would wipe it during an unattended install.

    def test_boot_disk_only_zfs_raid0_regardless_of_declared_pools(self):
        out = self._render()  # POOL = single:nvme0n1
        self.assertIn('filesystem = "zfs"', out, "ZFS on the boot disk by default (ADR-037 D1)")
        self.assertIn('zfs.raid = "raid0"', out, "one boot disk: raid0, never a data pool's level")
        self.assertIn('disk-list = ["sda"]', out, "installer must target the BOOT disk")
        self.assertNotIn('zfs.raid = "raid1"', out)

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

    # ── The boot disk by serial (#729 §3: nvme0n1/nvme1n1 swapped between boots) ──

    def test_boot_disk_by_serial_is_a_udev_filter(self):
        out = self._render(boot_disk="25414A800205")
        self.assertIn('filter.ID_SERIAL = "*25414A800205*"', out)
        self.assertNotIn("disk-list", out, "a serial must not also pin a kernel name")

    def test_boot_disk_kernel_name_keeps_disk_list(self):
        out = self._render(boot_disk="nvme1n1")
        self.assertIn('disk-list = ["nvme1n1"]', out)
        self.assertNotIn("filter.ID_SERIAL", out)

    def test_no_pools_is_zfs_on_the_boot_disk(self):
        out = self._render(pools=[])
        self.assertIn('filesystem = "zfs"', out)
        self.assertIn("TODO(V-2)", out)
        self.assertNotIn('filesystem = "ext4"', out)

    def test_boot_mirror_is_raid1_over_both_disks(self):
        out = self._render(boot_disk="nvme0n1", boot_mirror="nvme1n1")
        self.assertIn('zfs.raid = "raid1"', out)
        self.assertIn('disk-list = ["nvme0n1", "nvme1n1"]', out)
        self.assertNotIn("filter.ID_SERIAL", out)
        self.assertNotIn('zfs.raid = "raid0"', out)

    def test_ext4_on_request(self):
        out = self._render(boot_filesystem="ext4")
        self.assertIn('filesystem = "ext4"', out)
        self.assertNotIn("zfs.raid", out, "ext4 carries no raid level")
        self.assertIn('disk-list = ["sda"]', out)

    def test_mailto_defaults_from_domain(self):
        out = self._render(mailto="")
        self.assertIn('mailto = "root@mgmt.internal"', out)

    def test_toml_escaping(self):
        out = self._render(root_password='pw"with\\quotes')
        self.assertIn('root-password = "pw\\"with\\\\quotes"', out)


class TestAnswerSettingsFromSite(unittest.TestCase):
    def test_extracts_location_and_email(self):
        site = {"email": "admin@acme.example",
                "location": {"country": "DK", "timezone": "Europe/Copenhagen",
                             "keyboard": "dk"}}
        self.assertEqual(
            answer_settings_from_site(site),
            {"country": "DK", "keyboard": "dk", "tz": "Europe/Copenhagen",
             "mailto": "admin@acme.example"},
        )

    def test_the_primary_location_and_the_site_keyboard(self):
        # ADR-036 D1: the place is the primary location's, the keyboard the site's.
        site = {"email": "a@b.example", "keyboard": "dk", "primaryLocation": "home",
                "locations": {"far": {"country": "DE", "timezone": "Europe/Berlin"},
                              "home": {"country": "DK", "timezone": "Europe/Copenhagen"}}}
        self.assertEqual(
            answer_settings_from_site(site),
            {"country": "DK", "keyboard": "dk", "tz": "Europe/Copenhagen",
             "mailto": "a@b.example"},
        )

    def test_keyboard_comes_from_the_site(self):
        # #408: before this, every PXE-installed node got DEFAULT_KEYBOARD while
        # the first node had the operator's layout — tappaas2/3 came up 'us'
        # against tappaas1's 'dk'.
        site = {"location": {"country": "DK", "timezone": "Europe/Copenhagen",
                             "keyboard": "dk"}}
        self.assertEqual(answer_settings_from_site(site)["keyboard"], "dk")

    def test_keyboard_falls_back_for_a_site_that_predates_the_field(self):
        site = {"location": {"country": "DK", "timezone": "Europe/Copenhagen"}}
        self.assertEqual(answer_settings_from_site(site)["keyboard"], "en-us")

    def test_settings_reach_the_rendered_answer(self):
        site = {"location": {"country": "DK", "timezone": "Europe/Copenhagen",
                             "keyboard": "dk"}}
        out = render_answer(name="tappaas2", domain="mgmt.internal",
                            root_password="pw", ssh_keys=["ssh-ed25519 AAAA"],
                            pools=[POOL], **answer_settings_from_site(site))
        self.assertIn('keyboard = "dk"', out)
        self.assertIn('country = "dk"', out)
        self.assertIn('timezone = "Europe/Copenhagen"', out)

    def test_defaults_on_empty_site(self):
        settings = answer_settings_from_site({})
        self.assertEqual(settings["country"], "us")
        self.assertEqual(settings["keyboard"], "en-us")
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


class TestNodeSecretOwnership(unittest.TestCase):
    """2026-10-04: the answer server runs as root; its secrets were root-owned in
    the operator's home. As root they now take the owner of the home they sit in."""

    def test_as_root_the_secret_takes_its_homes_owner(self):
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            chowned = []
            with mock.patch("os.geteuid", return_value=0), \
                 mock.patch("os.chown", side_effect=lambda p, u, g: chowned.append((Path(p).name, u, g))):
                path = write_node_secret("tappaas2", "pw", directory=home / ".node-secrets")
            st = home.stat()
            self.assertEqual(chowned, [(".node-secrets", st.st_uid, st.st_gid), ("tappaas2.pw", st.st_uid, st.st_gid)])
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_not_root_nothing_is_chowned(self):
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp, mock.patch("os.chown") as ch:
            write_node_secret("tappaas2", "pw", directory=Path(tmp) / "s")
            ch.assert_not_called()


class TestHandleAnswerPost(unittest.TestCase):
    SITE = {"email": "ops@acme.example",
            "location": {"country": "DK", "timezone": "Europe/Copenhagen"}}

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        base = Path(self._tmp.name)
        self.registry = Registry(directory=base / "provision")
        self.secrets = base / "secrets"

    def _post(self, macs, bootdisk="", bootmirror=""):
        info = {"network_interfaces": [{"mac": m} for m in macs],
                "dmi": {"system": {"serial": "SN-1"}}}
        return handle_answer_post(
            info, self.registry, self.SITE,
            domain="mgmt.internal", secrets_directory=self.secrets,
            boot_disk_override=bootdisk, boot_mirror_override=bootmirror,
        )

    # ADR-037 D4: the installer resolves the fields and sends kernel names.
    def test_installer_named_mirror_is_raid1_over_both(self):
        self.registry.register("tappaas4", boot_disk="2TB")
        with mock.patch("node_provisioner.server._reserve_standard_ip"):
            status, body = self._post(["de:ad:be:ef:00:01"], bootdisk="nvme0n1", bootmirror="nvme1n1")
        self.assertEqual(status, 200)
        self.assertIn('zfs.raid = "raid1"', body)
        self.assertIn('disk-list = ["nvme0n1", "nvme1n1"]', body)

    def test_installer_named_single_disk(self):
        self.registry.register("tappaas4", boot_disk="auto")
        with mock.patch("node_provisioner.server._reserve_standard_ip"):
            status, body = self._post(["de:ad:be:ef:00:01"], bootdisk="sda")
        self.assertEqual(status, 200)
        self.assertIn('zfs.raid = "raid0"', body)
        self.assertIn('disk-list = ["sda"]', body)

    def test_a_field_without_the_installers_names_is_refused_unconsumed(self):
        for field in ("auto", "2TB", "Samsung 990", "ask"):
            self.registry.register("tappaas4", boot_disk=field)
            status, _ = self._post(["de:ad:be:ef:00:01"])
            self.assertEqual(status, 409, field)
            self.assertEqual(len(self.registry.list_pending()), 1)

    def test_a_mac_less_registration_never_answers_a_cluster_node(self):
        cfg = Path(self._tmp.name) / "config"
        cfg.mkdir()
        (cfg / "tappaas2.json").write_text(json.dumps({"moduleSource": "/x/pvehost",
            "uplinks": {"lan": {"ports": ["AA:BB:CC:00:00:02"]}, "wan": {"ports": ["aa:bb:cc:00:00:03"]}}}))
        (cfg / "old.json").write_text(json.dumps({"moduleSource": "/x/pvehost", "status": "archived",
            "uplinks": {"lan": {"ports": ["aa:bb:cc:00:00:09"]}}}))
        self.assertEqual(known_node_macs(cfg), {"aa:bb:cc:00:00:02", "aa:bb:cc:00:00:03"})
        self.registry.register("tappaas4", boot_disk="sda")
        for mac in ("aa:bb:cc:00:00:02", "AA:BB:CC:00:00:03"):
            status, _ = handle_answer_post({"network_interfaces": [{"mac": mac}]}, self.registry, self.SITE,
                                           domain="mgmt.internal", secrets_directory=self.secrets, config_directory=cfg)
            self.assertEqual(status, 403, mac)
        self.assertEqual(len(self.registry.list_pending()), 1)
        with mock.patch("node_provisioner.server._reserve_standard_ip"):
            status, _ = handle_answer_post({"network_interfaces": [{"mac": "aa:bb:cc:00:00:09"}]}, self.registry, self.SITE,
                                           domain="mgmt.internal", secrets_directory=self.secrets, config_directory=cfg)
        self.assertEqual(status, 200, "an archived node's MAC is no node's any more")

    def test_bad_mirror_parameter_is_refused(self):
        self.registry.register("tappaas4", boot_disk="auto")
        status, _ = self._post(["de:ad:be:ef:00:01"], bootdisk="sda", bootmirror="sdb;rm")
        self.assertEqual(status, 400)
        self.assertEqual(len(self.registry.list_pending()), 1)

    def test_mac_hit_serves_answer_and_consumes(self):
        self.registry.register("tappaas3", macs=["aa:bb:cc:dd:ee:03"],
                               pool_specs=["tanka1=single:nvme0n1"])
        status, body = self._post(["AA:BB:CC:DD:EE:03"])
        self.assertEqual(status, 200)
        self.assertIn('fqdn = "tappaas3.mgmt.internal"', body)
        self.assertIn('country = "dk"', body)
        # The served answer lays down the standard boot layout — ZFS on the boot
        # disk alone (raid0, ADR-037 D1) — and records the declared pool as
        # post-join work: it must never hand a data-pool disk to the installer.
        self.assertIn('filesystem = "zfs"', body)
        self.assertIn('zfs.raid = "raid0"', body)
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

    def test_pinned_registration_gets_its_nic_and_address(self):
        self.registry.register("tappaas3", macs=["aa:bb:cc:dd:ee:03"])
        with mock.patch("node_provisioner.server.detect_mgmt_ip", return_value="10.0.0.5"), \
             mock.patch("node_provisioner.server._reserve_standard_ip"):
            status, body = self._post(["11:22:33:44:55:66", "AA:BB:CC:DD:EE:03"])
        self.assertEqual(status, 200)
        self.assertIn('filter.ID_NET_NAME_MAC = "*aabbccddee03"', body)
        self.assertIn('cidr = "10.0.0.12/24"', body)

    def test_unpinned_registration_stays_on_dhcp(self):
        self.registry.register("tappaas4")
        with mock.patch("node_provisioner.server._reserve_standard_ip"):
            status, body = self._post(["de:ad:be:ef:00:01"])
        self.assertEqual(status, 200)
        self.assertIn('source = "from-dhcp"', body)

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
