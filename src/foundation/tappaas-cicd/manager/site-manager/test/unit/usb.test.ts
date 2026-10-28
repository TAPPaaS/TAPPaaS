// usb.test.ts — `node usb`: which disks are sticks, when one is in use, and
// what `node usb write` refuses before it touches the node.

import { describeStick, humanGb, inUseReason, isKeyStick, parseSticks, usbImagePath, usbWriteProblems } from "../../src/usb";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) passed++;
  else {
    failed++;
    console.error(`  FAIL: ${msg}`);
  }
}

// lsblk -J -b -d on a node with the boot NVMe, a SATA data disk, two sticks, a
// zvol and a DVD drive: only the sticks are offered.
const LSBLK = JSON.stringify({ blockdevices: [
  { name: "nvme0n1", path: "/dev/nvme0n1", size: 512110190592, tran: "nvme", type: "disk", vendor: null, model: "Samsung SSD 980", serial: "S6B0NX0T" },
  { name: "sda", path: "/dev/sda", size: 8001563222016, tran: "sata", type: "disk", vendor: "ATA     ", model: "ST8000VN004", serial: "ZA1" },
  { name: "sdb", path: "/dev/sdb", size: 30752000000, tran: "usb", type: "disk", vendor: "SanDisk ", model: "Ultra", serial: "4C530001" },
  { name: "sdc", path: "/dev/sdc", size: 15376000000, tran: "usb", type: "disk", vendor: " Kingston", model: "DataTraveler 3.0", serial: null },
  { name: "sr0", path: "/dev/sr0", size: 1073741312, tran: "sata", type: "rom", vendor: "HL-DT-ST", model: "DVDRAM", serial: "X" },
  { name: "zd0", path: "/dev/zd0", size: 34359738368, tran: null, type: "disk", vendor: null, model: null, serial: null },
] });

// lsblk -nP -o MOUNTPOINT,FSTYPE,LABEL <disk>: the disk line, then its partitions.
const TREES: Record<string, string> = {
  "/dev/sdb": 'MOUNTPOINT="" FSTYPE="" LABEL=""\nMOUNTPOINT="" FSTYPE="vfat" LABEL="TAPPAASKEYS"\n',
  "/dev/sdc": 'MOUNTPOINT="" FSTYPE="iso9660" LABEL="PVE"\nMOUNTPOINT="" FSTYPE="iso9660" LABEL="PVE"\nMOUNTPOINT="" FSTYPE="vfat" LABEL="EFI"\n',
};
const asked: string[] = [];
const sticks = parseSticks(LSBLK, (dev) => { asked.push(dev); return TREES[dev] ?? ""; });

check(sticks.map((s) => s.device).join(",") === "/dev/sdb,/dev/sdc", `only the USB disks are sticks (${sticks.map((s) => s.device).join(",")})`);
check(asked.join(",") === "/dev/sdb,/dev/sdc", "the tree is asked for the sticks only, not the NVMe, the data disk or the zvol");
check(sticks[0].size === 30752000000 && sticks[0].vendor === "SanDisk" && sticks[0].model === "Ultra" && sticks[0].serial === "4C530001",
  "size in bytes, vendor and model trimmed of lsblk's padding, serial kept");
check(sticks[1].serial === null && sticks[1].vendor === "Kingston", "no serial is null, not an empty string");
check(sticks[0].keyStick && !sticks[0].inUse && sticks[0].why === null, "a TAPPAASKEYS partition marks the key stick; unmounted it is not in use");
check(!sticks[1].keyStick && !sticks[1].inUse, "an old installer stick (iso9660, unmounted) is free to overwrite");
check(describeStick(sticks[0]) === "SanDisk Ultra serial 4C530001" && describeStick(sticks[1]) === "Kingston DataTraveler 3.0",
  "the description is vendor, model and serial, each only when known");
check(humanGb(30752000000) === "30.8 GB" && humanGb(1300000000) === "1.3 GB", "sizes as 31.0 GB-style decimals");

check(inUseReason('MOUNTPOINT="" FSTYPE="" LABEL=""\nMOUNTPOINT="/mnt/stick" FSTYPE="vfat" LABEL=""\n') === "mounted", "a mounted partition: in use (mounted)");
check(inUseReason('MOUNTPOINT="" FSTYPE="zfs_member" LABEL="tanka1"\n') === "zfs_member", "a pool member: in use, by its fstype");
check(inUseReason('MOUNTPOINT="" FSTYPE="" LABEL=""\nMOUNTPOINT="" FSTYPE="LVM2_member" LABEL=""\n') === "LVM2_member"
  && inUseReason('MOUNTPOINT="[SWAP]" FSTYPE="swap" LABEL=""\n') === "mounted"
  && inUseReason('MOUNTPOINT="" FSTYPE="swap" LABEL=""\n') === "swap"
  && inUseReason('MOUNTPOINT="" FSTYPE="linux_raid_member" LABEL=""\n') === "linux_raid_member",
  "LVM, swap and md members: in use");
check(inUseReason('MOUNTPOINT="" FSTYPE="ext4" LABEL="data"\n') === null && inUseReason("") === null, "an unmounted file system, or no tree at all: free");
check(inUseReason('MOUNTPOINT="/mnt/a b" FSTYPE="vfat" LABEL="x\\"y"\n') === "mounted" && isKeyStick('MOUNTPOINT="" FSTYPE="vfat" LABEL="TAPPAASKEYS"\n'),
  "quoted values with spaces and escapes parse; the key label is matched exactly");
check(!isKeyStick('MOUNTPOINT="" FSTYPE="vfat" LABEL="tappaaskeys"\n'), "the key label is case-sensitive, as the stick's twin writes it");

let threw = false;
try { parseSticks("not json", () => ""); } catch { threw = true; }
check(threw, "unreadable lsblk output is an error, not an empty list");

// `node usb write` refusals, in the order the verb checks them.
process.env.TAPPAAS_PXE_DIR = "/tmp/pxe-test";
check(usbImagePath() === "/tmp/pxe-test/tappaas-usb.iso", "TAPPAAS_PXE_DIR relocates the image for tests");
const free = sticks[1];
const ok = (c: Parameters<typeof usbWriteProblems>[0]): string[] => usbWriteProblems(c, "tappaas1");
check(ok({ yes: true, imagePresent: true, sticks, device: free.device }).length === 0, "a free stick, the image staged, --yes: nothing in the way");
check(ok({ yes: false, imagePresent: true, sticks, device: free.device }).join() === "erases the stick: add --yes", "no --yes: refused, and told why");
const noimg = ok({ yes: true, imagePresent: false, sticks, device: free.device });
check(noimg.length === 1 && noimg[0].includes("/tmp/pxe-test/tappaas-usb.iso") && noimg[0].includes("prepare-netboot.sh"),
  "no image: names the path and what stages it");
check(ok({ yes: false, imagePresent: false, sticks: undefined, device: free.device }).length === 2, "before the node is asked: the cheap refusals only");
const unreach = ok({ yes: true, imagePresent: true, sticks: null, device: free.device });
check(unreach.length === 1 && unreach[0].includes("cannot reach tappaas1"), "an unreachable node: refused, the device not judged");
const notStick = ok({ yes: true, imagePresent: true, sticks, device: "/dev/nvme0n1" });
check(notStick.length === 1 && notStick[0].includes("/dev/nvme0n1 is no USB stick") && notStick[0].includes("/dev/sdb, /dev/sdc"),
  "the boot disk: refused, the sticks named instead");
check(ok({ yes: true, imagePresent: true, sticks: [], device: "/dev/sdb" })[0].includes("none is plugged in"), "no stick at all: says so");
const mounted = parseSticks(LSBLK, () => 'MOUNTPOINT="/mnt/x" FSTYPE="vfat" LABEL=""\n');
const inUse = ok({ yes: true, imagePresent: true, sticks: mounted, device: "/dev/sdb" });
check(inUse.length === 1 && inUse[0].includes("/dev/sdb is in use (mounted)"), "a mounted stick: refused, with why");
check(ok({ yes: true, imagePresent: true, sticks, device: "/dev/sdb" }).length === 0, "the key stick is a stick: writable with --yes (the verb warns)");

console.log(`usb: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
