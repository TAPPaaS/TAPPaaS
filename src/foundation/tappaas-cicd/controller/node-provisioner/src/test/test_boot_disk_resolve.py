"""The installer's boot-disk matching (ADR-037 D4): assets.RESOLVE_SH run by a
POSIX sh against a fake /sys, and the per-MAC fields boot.ipxe carries."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from node_provisioner.assets import RESOLVE_SH, boot_disk_lines

GB = 1_000_000_000


def _shells():
    found = [sh for sh in ("sh", "dash") if shutil.which(sh)]
    if shutil.which("busybox"):
        found.append("busybox sh")
    return found


class FakeSys:
    """/sys/block/<name> -> /sys/devices/<bus>/<name>, as the kernel lays it out."""

    def __init__(self, root: Path):
        self.root = root
        (root / "block").mkdir(parents=True)

    def disk(self, name, size_bytes, model="", serial="", ssd=True, usb=False, wwid=""):
        dev = self.root / "devices" / ("usb1/1-1" if usb else "pci0000:00") / name
        (dev / "device").mkdir(parents=True)
        (dev / "queue").mkdir()
        (dev / "size").write_text(f"{size_bytes // 512}\n")
        (dev / "device" / "model").write_text(model + "\n")
        if serial:
            (dev / "device" / "serial").write_text(serial + "\n")
        if wwid:
            (dev / "device" / "wwid").write_text(wwid + "\n")
        (dev / "queue" / "rotational").write_text("0\n" if ssd else "1\n")
        os.symlink(dev, self.root / "block" / name)


class TestResolve(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.sys = FakeSys(Path(self._tmp.name) / "sys")

    def resolve(self, boot, mirror=""):
        out = {}
        script = RESOLVE_SH + '\n_tap_resolve "$1" "$2"; rc=$?\necho "$rc|$_tap_disk|$_tap_mirror|$_tap_why"\n'
        for sh in _shells():
            r = subprocess.run(sh.split() + ["-c", script, "t", boot, mirror],
                               env={"TAPPAAS_SYS": str(self.sys.root), "PATH": os.environ["PATH"]},
                               capture_output=True, text=True)
            self.assertEqual(r.stderr, "", f"{sh}: {r.stderr}")
            out[sh] = r.stdout.strip().split("|")
        first = next(iter(out.values()))
        for sh, v in out.items():
            self.assertEqual(v, first, f"{sh} disagrees")
        return int(first[0]), first[1], first[2]

    def two_alike_and_a_big_one(self):
        self.sys.disk("nvme0n1", 2000 * GB, "Samsung SSD 990 PRO 2TB", "S7HENJ0X100001")
        self.sys.disk("nvme1n1", 2000 * GB, "Samsung SSD 990 PRO 2TB", "S7HENJ0X100002")
        self.sys.disk("sda", 8000 * GB, "ST8000VN004", ssd=False, wwid="t10.ATA ST8000VN004 ZA1X2Y3Z")

    def test_auto_mirrors_an_identical_smallest_pair(self):
        self.two_alike_and_a_big_one()
        self.assertEqual(self.resolve("auto"), (0, "nvme0n1", "nvme1n1"))
        self.assertEqual(self.resolve(""), (0, "nvme0n1", "nvme1n1"))

    def test_auto_with_mirror_none_is_one_disk(self):
        self.two_alike_and_a_big_one()
        self.assertEqual(self.resolve("auto", "none"), (0, "nvme0n1", ""))

    def test_auto_takes_the_smallest_ssd_and_skips_usb_and_spinning(self):
        self.sys.disk("sda", 120 * GB, "USB stick", usb=True)
        self.sys.disk("sdb", 4000 * GB, "WD Red", ssd=False)
        self.sys.disk("nvme0n1", 1000 * GB, "KINGSTON SNV2S1000G")
        self.sys.disk("nvme1n1", 512 * GB, "Samsung 980")
        self.assertEqual(self.resolve("auto"), (0, "nvme1n1", ""))

    def test_auto_with_two_different_smallest_is_one_disk(self):
        self.sys.disk("nvme0n1", 1000 * GB, "KINGSTON SNV2S1000G")
        self.sys.disk("nvme1n1", 1000 * GB, "Samsung 980 PRO 1TB")
        self.assertEqual(self.resolve("auto")[2], "")

    def test_auto_without_an_ssd_asks(self):
        self.sys.disk("sda", 4000 * GB, "WD Red", ssd=False)
        self.assertEqual(self.resolve("auto")[0], 1)

    def test_a_size_names_the_disk_within_ten_percent(self):
        self.sys.disk("nvme0n1", 1920 * GB, "Micron 7450")
        self.sys.disk("sda", 8000 * GB, "ST8000VN004", ssd=False)
        self.assertEqual(self.resolve("2TB"), (0, "nvme0n1", ""))
        self.assertEqual(self.resolve("1.92T"), (0, "nvme0n1", ""))
        self.assertEqual(self.resolve("8tb"), (0, "sda", ""))
        self.assertEqual(self.resolve("500GB")[0], 1)

    def test_a_size_that_finds_two_alike_mirrors_them(self):
        self.two_alike_and_a_big_one()
        self.assertEqual(self.resolve("2TB"), (0, "nvme0n1", "nvme1n1"))
        self.assertEqual(self.resolve("2TB", "none")[0], 1)  # two disks, mirroring refused: ask

    def test_a_model_or_serial_matches_case_insensitively(self):
        self.two_alike_and_a_big_one()
        self.assertEqual(self.resolve("samsung.ssd.990"), (0, "nvme0n1", "nvme1n1"))
        self.assertEqual(self.resolve("S7HENJ0X100002"), (0, "nvme1n1", ""))
        self.assertEqual(self.resolve("za1x2y3z"), (0, "sda", ""))       # a SATA serial in wwid
        self.assertEqual(self.resolve("S7HENJ0X100001", "S7HENJ0X100002"), (0, "nvme0n1", "nvme1n1"))

    def test_kernel_names_and_failures(self):
        self.two_alike_and_a_big_one()
        self.assertEqual(self.resolve("sda"), (0, "sda", ""))
        self.assertEqual(self.resolve("nvme0n1", "nvme0n1")[0], 1)       # the same disk twice
        self.assertEqual(self.resolve("Kingston")[0], 1)                 # no match
        self.assertEqual(self.resolve("ask")[0], 1)


class TestBootDiskLines(unittest.TestCase):
    @staticmethod
    def reg(disk, mirror="", macs=()):
        return SimpleNamespace(boot_disk=disk, boot_mirror=mirror, macs=list(macs))

    def test_one_registration_is_the_default_and_by_its_mac(self):
        lines = boot_disk_lines([self.reg("Samsung 990", "none", ["aa:bb:cc:dd:ee:01"])])
        self.assertIn("set tapdisk tappaas.bootdisk=Samsung.990 tappaas.bootmirror=none\n", lines)
        self.assertIn("iseq ${netX/mac} aa:bb:cc:dd:ee:01 && set tapdisk tappaas.bootdisk=Samsung.990 tappaas.bootmirror=none ||", lines)

    def test_several_are_chosen_by_mac_and_the_default_is_auto(self):
        lines = boot_disk_lines([self.reg("2TB", macs=["aa:bb:cc:dd:ee:01"]), self.reg("ask", macs=["aa:bb:cc:dd:ee:02"])])
        self.assertTrue(lines.startswith("set tapdisk tappaas.bootdisk=auto\n"))
        self.assertIn("aa:bb:cc:dd:ee:02 && set tapdisk tappaas.bootdisk=ask ||", lines)

    def test_nothing_pending_is_auto(self):
        self.assertEqual(boot_disk_lines([]), "set tapdisk tappaas.bootdisk=auto\n")


if __name__ == "__main__":
    unittest.main()
