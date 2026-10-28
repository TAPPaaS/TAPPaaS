"""`node-provisioner assets`: what is staged, read from the asset directory."""

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from node_provisioner import assets


class TestAssetsStatus(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.iso = self.dir / "pve-tappaas-netboot.iso"

    def tearDown(self):
        self.tmp.cleanup()

    def _stage(self, patch_value=None, with_stamp=True):
        for n in ("linux26", "initrd", "boot.ipxe"):
            (self.dir / n).write_bytes(b"x")
        if with_stamp:
            (self.dir / assets.STAMP_NAME).write_text(json.dumps(
                {"patch": patch_value or assets.patch_stamp(), "iso": str(self.iso)}))

    def test_nothing_staged(self):
        st = assets.assets_status(self.dir)
        self.assertFalse(st["staged"])
        self.assertFalse(st["current"])
        self.assertEqual(st["source"], assets.DEFAULT_SOURCE_ISO)
        self.assertFalse(st["stickImage"]["present"])
        self.assertEqual(st["stickImage"]["path"], str(self.dir / assets.USB_ISO_NAME))

    def test_staged_and_current_with_the_stick_image(self):
        self._stage()
        self.iso.write_bytes(b"iso")
        (self.dir / assets.USB_ISO_NAME).write_bytes(b"stick")
        st = assets.assets_status(self.dir)
        self.assertTrue(st["staged"] and st["current"] and st["sourcePresent"])
        self.assertEqual(st["source"], str(self.iso))
        self.assertTrue(st["stickImage"]["present"])
        self.assertEqual(st["stickImage"]["size"], 5)
        self.assertRegex(st["stickImage"]["modified"], r"^\d{4}-\d\d-\d\dT")

    def test_assets_from_an_older_hook_are_not_current(self):
        self._stage(patch_value="0000000000000000")
        st = assets.assets_status(self.dir)
        self.assertTrue(st["staged"])
        self.assertFalse(st["current"])
        self.assertEqual(st["source"], str(self.iso))

    def test_assets_without_a_stamp_are_not_current_and_name_the_default_iso(self):
        self._stage(with_stamp=False)
        st = assets.assets_status(self.dir)
        self.assertTrue(st["staged"])
        self.assertFalse(st["current"])
        self.assertEqual(st["source"], assets.DEFAULT_SOURCE_ISO)

    def test_xorriso_is_reported(self):
        with patch.object(assets.shutil, "which", return_value=None):
            self.assertFalse(assets.assets_status(self.dir)["xorriso"])
        with patch.object(assets.shutil, "which", return_value="/usr/bin/xorriso"):
            self.assertTrue(assets.assets_status(self.dir)["xorriso"])

    def test_the_directory_defaults_to_the_pxe_dir(self):
        with patch.dict(os.environ, {"TAPPAAS_PXE_DIR": str(self.dir)}):
            self.assertEqual(assets.assets_status()["directory"], str(self.dir))


if __name__ == "__main__":
    unittest.main()
