// usb.ts — `site-manager node usb`: the USB sticks in a cluster node, and the
// installer stick written to one of them.
//
//   node usb <node> [--json]                 the sticks plugged into the node
//   node usb write <node> <device> --yes     the installer stick image onto one
//
// A new machine with no network boot path is installed from a stick that
// carries /var/lib/tappaas-pxe/tappaas-usb.iso (`node media prepare` builds it
// on the mothership, media.ts; the same image for every node). The operator
// plugs a stick into any cluster node, this verb writes it there over ssh, and
// the console's node-add page offers the same from the list. What counts as a
// stick, and when one is left alone, is the backup key stick's rule
// (backup/scripts/keys-from-usb.sh): a whole disk on the USB bus — never a
// SATA/NVMe disk, an optical drive or a ZFS volume — and never one that is
// mounted, swap, or a ZFS/LVM/RAID member, which is in use whatever it is.

import { spawnSync } from "child_process";
import * as fs from "fs";

import { GN, YW, CL, die, info } from "../../../lib/ts/src/cli";
import { mgmtDomain, ssh, sshIdentity } from "../../../lib/ts/src/cluster";

// Where prepare-netboot.sh stages the netboot material; the stick image sits
// beside the PXE answer. TAPPAAS_PXE_DIR is for the tests, which must not need
// a 1.3 GB image under /var/lib.
export const USB_IMAGE_NAME = "tappaas-usb.iso";
export function usbImagePath(): string {
  return `${(process.env.TAPPAAS_PXE_DIR ?? "/var/lib/tappaas-pxe").replace(/\/$/, "")}/${USB_IMAGE_NAME}`;
}

// The label keys-to-usb.sh gives the backup key stick's partition: that stick
// is listed, marked, and the console will not propose it as an installer stick.
export const KEY_STICK_LABEL = "TAPPAASKEYS";
// What a stick with no medium is: ejected, until it is pulled and plugged in again.
export const EJECTED = "ejected: unplug it and plug it in again";

// What lsblk -J -b -d -o NAME,PATH,SIZE,TRAN,TYPE,VENDOR,MODEL,SERIAL says.
export const LSBLK_STICKS = "lsblk -J -b -d -o NAME,PATH,SIZE,TRAN,TYPE,VENDOR,MODEL,SERIAL";
// And what it says about one disk's whole tree, one line per device, key="value".
export function lsblkTreeCmd(device: string): string {
  return `lsblk -nP -o MOUNTPOINT,FSTYPE,LABEL ${device}`;
}

export interface UsbStick {
  device: string;
  size: number;
  vendor: string;
  model: string;
  serial: string | null;
  inUse: boolean;
  // why it is in use: mounted, or the file system type that claims it.
  why: string | null;
  keyStick: boolean;
}

// The file system types that mean a device belongs to something live even
// when nothing is mounted: a pool, a volume group, swap, an md array.
const CLAIMING_FSTYPES = new Set(["zfs_member", "LVM2_member", "swap", "linux_raid_member"]);

// Parse lsblk's -P output: one device per line, KEY="value" pairs.
function pairsOf(tree: string): Map<string, string>[] {
  const lines: Map<string, string>[] = [];
  for (const line of tree.split("\n")) {
    if (!line.trim()) continue;
    const m = new Map<string, string>();
    for (const kv of line.matchAll(/([A-Z_-]+)="((?:[^"\\]|\\.)*)"/g)) m.set(kv[1], kv[2].replace(/\\(.)/g, "$1"));
    lines.push(m);
  }
  return lines;
}

// Why the disk (its tree: `lsblk -nP -o MOUNTPOINT,FSTYPE,LABEL <disk>`) is in
// use, or null when nothing holds it. keys-from-usb.sh's usbk_in_use. Pure.
export function inUseReason(tree: string): string | null {
  for (const dev of pairsOf(tree)) {
    if (dev.get("MOUNTPOINT")) return "mounted";
    const fs = dev.get("FSTYPE") ?? "";
    if (CLAIMING_FSTYPES.has(fs)) return fs;
  }
  return null;
}

// Whether the disk (the same tree) carries the backup key stick's partition. Pure.
export function isKeyStick(tree: string): boolean {
  return pairsOf(tree).some((dev) => dev.get("LABEL") === KEY_STICK_LABEL);
}

interface LsblkDisk {
  path?: string; size?: number | string; tran?: string | null; type?: string;
  vendor?: string | null; model?: string | null; serial?: string | null;
}

// The USB sticks in `lsblk -J -b -d` output, each asked about by its tree
// (treeOf: the device path → its `lsblk -nP` lines, which the caller fetches
// from the node). keys-from-usb.sh's usbk_candidates, with the in-use and
// key-stick verdicts folded in. Pure given treeOf.
export function parseSticks(lsblkJson: string, treeOf: (device: string) => string): UsbStick[] {
  let doc: { blockdevices?: LsblkDisk[] };
  try { doc = JSON.parse(lsblkJson) as { blockdevices?: LsblkDisk[] }; }
  catch { throw new Error("lsblk: unreadable output"); }
  const sticks: UsbStick[] = [];
  for (const d of doc.blockdevices ?? []) {
    if (d.type !== "disk" || d.tran !== "usb" || !d.path) continue;
    // A stick ejected after a write (the key stick's and the installer stick's
    // last step) stays listed by the kernel with no medium and size 0 until it
    // is pulled and plugged in again: shown, with that said, never written.
    const ejected = Number(d.size ?? 0) === 0;
    const tree = ejected ? "" : treeOf(d.path);
    const why = ejected ? EJECTED : inUseReason(tree);
    const trim = (s: string | null | undefined): string => (s ?? "").trim();
    sticks.push({
      device: d.path,
      size: Number(d.size ?? 0),
      vendor: trim(d.vendor),
      model: trim(d.model),
      serial: trim(d.serial) || null,
      inUse: why !== null,
      why,
      keyStick: !ejected && isKeyStick(tree),
    });
  }
  return sticks;
}

// 31.0 GB, as keys-from-usb.sh says it (a stick's size is a round decimal).
export function humanGb(bytes: number): string {
  return `${(bytes / 1e9).toFixed(1)} GB`;
}

// The one-line description: vendor, model, "serial <s>" — what is on the stick's label.
export function describeStick(s: UsbStick): string {
  return [s.vendor, s.model, s.serial ? `serial ${s.serial}` : ""].filter(Boolean).join(" ");
}

export interface UsbWriteCheck {
  yes: boolean;
  imagePresent: boolean;
  // the node's sticks; null when the node could not be reached; undefined when
  // it has not been asked yet (the refusals that need no node come first).
  sticks: UsbStick[] | null | undefined;
  device: string;
}

// What stops `node usb write` before anything is written. Each refusal says
// what to do instead; the device check is last because it means nothing when
// the node is out of reach. Pure.
export function usbWriteProblems(c: UsbWriteCheck, node: string, image: string = usbImagePath()): string[] {
  const p: string[] = [];
  if (!c.yes) p.push("erases the stick: add --yes");
  if (!c.imagePresent) p.push(`${image} is missing — node media prepare builds the installer stick image`);
  if (c.sticks === undefined) return p;
  if (c.sticks === null) { p.push(`cannot reach ${node}`); return p; }
  const s = c.sticks.find((x) => x.device === c.device);
  if (!s) {
    p.push(c.sticks.length
      ? `${c.device} is no USB stick in ${node}: ${c.sticks.map((x) => x.device).join(", ")} (node usb ${node})`
      : `${c.device} is no USB stick in ${node}: none is plugged in (node usb ${node})`);
  } else if (s.inUse) {
    p.push(`${c.device} is in use (${s.why}) — unmount or export it first, or use another stick`);
  }
  return p;
}

// ── the node side ─────────────────────────────────────────────────────

function hostOf(node: string): string {
  return `${node}.${mgmtDomain()}`;
}

// The node's sticks, or null when the node cannot be reached (the ssh failed
// before lsblk ran: rc 255, or no ssh at all). lsblk itself failing is an error
// the operator must see, not an unreachable node.
function readSticks(node: string): { sticks: UsbStick[] | null; error?: string } {
  const host = hostOf(node);
  const r = ssh("root", host, LSBLK_STICKS);
  if (!r.ran || r.rc === 255) return { sticks: null, error: r.stderr.trim() };
  if (r.rc !== 0) die(`lsblk on ${node} failed: ${r.stderr.trim()}`);
  try {
    return { sticks: parseSticks(r.stdout, (dev) => {
      const t = ssh("root", host, lsblkTreeCmd(dev));
      // A stick pulled between the two calls: not in use, not a key stick, and
      // the write's own listing will miss it.
      return t.rc === 0 ? t.stdout : "";
    }) };
  } catch (e) { die(`${node}: ${(e as Error).message}`); }
}

// `node usb <node>`: the sticks, for the operator or the console.
export function listNodeUsb(node: string, json: boolean): void {
  const { sticks, error } = readSticks(node);
  if (sticks === null) {
    if (json) { info(JSON.stringify({ node, reachable: false, sticks: [] }, null, 2)); return; }
    die(`cannot reach ${hostOf(node)}${error ? `: ${error}` : ""}`);
  }
  if (json) { info(JSON.stringify({ node, reachable: true, sticks }, null, 2)); return; }
  if (sticks.length === 0) { info(`(no USB stick on ${node})`); return; }
  for (const s of sticks) {
    const mark = s.inUse ? `  ${YW}(in use: ${s.why})${CL}` : s.keyStick ? "  (key stick)" : "";
    info(`${s.device}  ${humanGb(s.size)}  ${describeStick(s)}${mark}`);
  }
}

// `node usb write <node> <device> --yes`: the installer stick image, streamed
// from this machine onto the stick in the node.
export function writeNodeUsb(node: string, device: string, yes: boolean): void {
  const image = usbImagePath();
  const imagePresent = fs.existsSync(image);
  // The node is asked only once the cheap refusals are through: no --yes or no
  // image is answered without a round trip.
  const early = usbWriteProblems({ yes, imagePresent, sticks: undefined, device }, node, image);
  if (early.length) die(`node usb write: ${early.join("; ")}`);
  const { sticks, error } = readSticks(node);
  const problems = usbWriteProblems({ yes, imagePresent, sticks, device }, node, image);
  if (problems.length) die(`node usb write: ${problems.join("; ")}${sticks === null && error ? ` (${error})` : ""}`);
  const stick = (sticks ?? []).find((s) => s.device === device)!;

  const host = hostOf(node);
  const size = fs.statSync(image).size;
  info(`writing ${image} (${humanGb(size)}) to ${device} in ${node} (${describeStick(stick)}, ${humanGb(stick.size)}) — ${YW}the stick is erased${CL}`);
  if (stick.keyStick) info(`${YW}${device} was the backup key stick: it is one no longer${CL}`);

  // The image is dd's stdin on the node, read straight from the file here: no
  // copy of 1.3 GB in this process, and ssh's own flow control paces it. The
  // ssh options are cluster.ts ssh()'s, which has no streaming form. dd's
  // progress comes back on stdout as a line every few seconds (percent, rate,
  // time left: ddProgressCmd); what is not progress (an error) stays on stderr.
  info("a few minutes: the image streams over ssh, then the stick flushes");
  const fd = fs.openSync(image, "r");
  let r;
  try {
    r = spawnSync("ssh", [...sshArgs(), `root@${host}`, ddProgressCmd(device, size)],
      { stdio: [fd, "inherit", "pipe"], encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
  } finally { fs.closeSync(fd); }
  if (r.error) die(`node usb write: ssh could not be started: ${r.error.message}`);
  if (r.status !== 0) {
    const err = (r.stderr ?? "").trim();
    if (/No medium found/i.test(err)) die(`node usb write: ${device} on ${node} is ejected (${err}): unplug it and plug it in again, nothing was written`);
    die(`node usb write: dd to ${device} on ${node} failed (rc ${r.status}): ${err} — the stick holds a partial image, write it again`);
  }

  // Flush and let it go, as the key stick's twin does; an eject that fails
  // (a stick that cannot be ejected) is no failure of the write.
  info("flushed; ejecting the stick");
  const flush = ssh("root", host, `sync; blockdev --flushbufs ${device} 2>/dev/null; eject ${device} 2>/dev/null || true`);
  if (flush.rc !== 0) info(`${YW}flush/eject on ${node} reported: ${flush.stderr.trim()} — pull the stick after a moment${CL}`);
  info(`${GN}✓ ${device} on ${node} holds the installer stick (${humanGb(size)}): boot the new machine from it once${CL}`);
}

// The command on the node: dd with its progress (a line a second, '\r'-separated
// on stderr) turned into one line every fifth second on stdout — percent, MB
// written of the total, the rate, the time left at that rate — and anything
// else dd says (an error) left on stderr. The pipe fails as dd fails. The
// formatting is bash, not awk: mawk (the nodes' awk) buffers until the end
// when it writes to a pipe, fflush or not, and so does a tr in between — the
// lines all came at once when the write was over.
export function ddProgressCmd(device: string, total: number): string {
  const emit =
    "emit() { case \"$1\" in *\" bytes \"*\" copied, \"*) set -- $1; b=$1; s=${*: -4:1}; s=${s%.*}; r=\"${*: -2:1} ${*: -1}\"; n=$((n+1)); " +
    "if [ $((n%5)) -ne 0 ] && [ \"$b\" -lt \"$t\" ]; then return; fi; pct=$((b*100/t)); left=\"\"; " +
    "if [ \"$b\" -gt 0 ] && [ \"${s:-0}\" -gt 0 ] && [ \"$b\" -lt \"$t\" ]; then left=\", about $(( (t-b)*s/b )) s left\"; fi; " +
    "printf '  %3d%%  %d of %d MB  %s%s\\n' \"$pct\" $((b/1000000)) $((t/1000000)) \"$r\" \"$left\";; \"\") ;; *) printf '%s\\n' \"$1\" >&2;; esac; }";
  const loop = "while IFS= read -r -d $'\\r' c || [ -n \"$c\" ]; do while IFS= read -r l || [ -n \"$l\" ]; do emit \"$l\"; done <<<\"$c\"; done";
  // oflag=direct: written to the stick as it goes, so the progress is the
  // stick's own pace. Through the page cache the node swallowed most of the
  // image in seconds at memory speed, then sat at that percent for minutes
  // while the flush did the real writing with nothing to report.
  return `set -o pipefail; dd of=${device} bs=4M iflag=fullblock oflag=direct conv=fsync status=progress 2>&1 >/dev/null | { n=0; t=${total}; ${emit}; ${loop}; }`;
}

// cluster.ts ssh()'s option list, for the one call that streams a file: the
// same short timeout, batch mode, accept-new host keys and explicit identity.
function sshArgs(): string[] {
  return [
    "-o", "ConnectTimeout=5",
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "IdentitiesOnly=yes",
    "-i", sshIdentity(),
  ];
}
