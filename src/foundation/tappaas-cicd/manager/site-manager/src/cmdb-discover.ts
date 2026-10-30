// cmdb-discover.ts — `site-manager report --discover` (ADR-040 D15): what a
// node holds whether or not TAPPaaS declared it. One ssh per node runs every
// read (NODE_DISCOVERY); the parsers here are pure. proxmox-controller's depth
// of the sweep: NICs used or not, every disk and what each partition holds,
// every ZFS pool and its layout, the storages the node knows, the PCI devices
// a guest could take, the CPU and memory.
//
// A NIC is a `port` of the node's asset when the machine is allocated to one
// (positions.json: the asset whose role is the node); a port cannot exist
// without an asset, and a sweep never invents one (D15). Disks are no CIs yet
// (O4): `nics[]` and `disks[]` are attributes of that server, else of the
// machine, so nothing is lost.

import { join } from "path";
import { CmdbObject } from "../../../lib/ts/src/cmdb";
import { compact, poolHealth } from "../../../lib/ts/src/cmdb-source";
import { parseProbeSections } from "../../../lib/ts/src/cluster";
import { readJsonObject } from "../../../lib/ts/src/config-io";
import { POSITIONS_FILE, PositionsDoc, assetNamed } from "../../../lib/ts/src/positions";

type Obj = Record<string, unknown>;

export interface Nic {
  name: string;
  mac?: string;
  kind: "rj45" | "sfp" | "wifi";
  speed?: string; // the D9 value for its kind; absent where D9 has none
  maxMbps?: number;
  link: boolean;
  operstate?: string;
  bond?: string;
  bridge?: string;
}

export interface Partition {
  device: string;
  size: number;
  holds: string; // zfs, efi, lvm, swap, bios-boot, a filesystem, or nothing
  pool?: string;
}

export interface Disk {
  name: string; // the /dev/disk/by-id name, else the device
  device: string;
  model?: string;
  serial?: string;
  size?: number;
  type?: string; // ssd, hdd, nvme, usb
  bus?: string;
  health?: string;
  holds: string; // what the whole disk holds, when it has no partitions
  partitions: Partition[];
}

export interface Vdev {
  name: string;
  group?: string; // logs, cache, special, spares
  state?: string;
  members: { device: string; serial?: string; state?: string }[];
}

export interface ZPool {
  name: string;
  state?: string;
  size?: number;
  used?: number;
  vdevs: Vdev[];
}

export interface NodeDiscovery {
  cpu?: string;
  cpus?: number;
  memory?: number; // MiB
  nics: Nic[];
  disks: Disk[];
  pools: ZPool[];
  storages: Obj[];
  pci: Obj[];
}

/** One ssh's reads of <node>, each a `@@section` (lib/ts cluster.ts's shape). */
export function nodeDiscoveryProbe(node: string): string {
  return [
    'sec() { n="$1"; shift; echo "@@section $n"; "$@"; r=$?; echo; echo "@@rc $r"; }',
    `nics() {
  for d in /sys/class/net/*; do
    [ -e "$d/device" ] || continue
    n="\${d##*/}"; m=""; u=""
    [ -e "$d/master" ] && m="$(basename "$(readlink "$d/master")")"
    [ -n "$m" ] && [ -e "/sys/class/net/$m/master" ] && u="$(basename "$(readlink "/sys/class/net/$m/master")")"
    echo "== $n"
    echo "address=$(cat "$d/address" 2>/dev/null)"
    echo "carrier=$(cat "$d/carrier" 2>/dev/null)"
    echo "operstate=$(cat "$d/operstate" 2>/dev/null)"
    echo "master=$m"
    echo "upper=$u"
    [ -n "$m" ] && [ -d "/sys/class/net/$m/bonding" ] && echo "masterIsBond=1"
    [ -d "$d/wireless" ] && echo "wireless=1"
    ethtool -P "$n" 2>/dev/null
    ethtool "$n" 2>/dev/null
  done
}`,
    `sec status pvesh get /nodes/${node}/status --output-format json`,
    "sec nics nics",
    `sec disks pvesh get /nodes/${node}/disks/list --output-format json`,
    "sec lsblk lsblk -J -b -o NAME,PATH,TYPE,SIZE,FSTYPE,LABEL,PARTTYPENAME,TRAN,MOUNTPOINTS",
    "sec zpool-list zpool list -Hp -o name,size,alloc,free,frag,cap,dedup,health",
    "sec zpool-status zpool status -L -P -p",
    "sec zfs-root zfs list -Hp -d 0 -o name,used,avail",
    `sec storage pvesh get /nodes/${node}/storage --output-format json`,
    `sec pci pvesh get /nodes/${node}/hardware/pci --output-format json`,
    "true",
  ].join("\n");
}

function json(text: string | undefined): unknown {
  try {
    return JSON.parse(text ?? "");
  } catch {
    return null;
  }
}

const str = (v: unknown): string | undefined => (typeof v === "string" && v !== "" ? v : undefined);
const num = (v: unknown): number | undefined => (typeof v === "number" ? v : typeof v === "string" && /^\d+$/.test(v) ? Number(v) : undefined);

// The largest link mode ethtool lists → D9's value for the kind, which allows
// only these (lib/ts positions.ts SPEEDS_OF): 100M and 40G NICs have none.
function d9Speed(kind: Nic["kind"], mbps: number | undefined): string | undefined {
  const allowed: Record<string, Record<number, string>> = {
    rj45: { 1000: "1g", 2500: "2.5g", 10000: "10g" },
    sfp: { 1000: "1g", 10000: "10g", 25000: "25g" },
  };
  return mbps === undefined ? undefined : allowed[kind]?.[mbps];
}

/** The `nics` section: one `== <name>` block per physical NIC, sysfs then
 *  ethtool. A bond's slave shows the bond's MAC in sysfs: the permanent one
 *  is ethtool's. */
export function parseNics(text: string): Nic[] {
  const out: Nic[] = [];
  for (const block of text.split(/^== /m).slice(1)) {
    const lines = block.split("\n");
    const name = lines[0].trim();
    const kv = new Map<string, string>();
    for (const l of lines.slice(1)) {
      const m = /^(address|carrier|operstate|master|upper|masterIsBond|wireless)=(.*)$/.exec(l);
      if (m) kv.set(m[1], m[2].trim());
    }
    const perm = /Permanent address:\s*([0-9a-f:]{17})/i.exec(block)?.[1];
    const usable = (m: string | undefined): string | undefined => (m && !/^(00:){5}00$/.test(m) ? m.toLowerCase() : undefined);
    const portLine = /^\s*Port:\s*(.+)$/m.exec(block)?.[1]?.trim() ?? "";
    const ports = /Supported ports:\s*\[(.*?)\]/.exec(block)?.[1] ?? "";
    const wireless = kv.get("wireless") === "1";
    const fibre = /FIBRE|Direct Attach/i.test(`${portLine} ${ports}`);
    const kind: Nic["kind"] = wireless ? "wifi" : fibre ? "sfp" : "rj45";
    let maxMbps: number | undefined;
    const modes = /Supported link modes:([\s\S]*?)(?:\n\s*Supported pause|\n\s*Supports auto|\n\s*Supported FEC|\n\s*Advertised)/.exec(block)?.[1] ?? "";
    for (const m of modes.matchAll(/(\d+)base/g)) maxMbps = Math.max(maxMbps ?? 0, Number(m[1]));
    const mbpsNow = /^\s*Speed:\s*(\d+)Mb\/s/m.exec(block)?.[1];
    maxMbps ??= mbpsNow ? Number(mbpsNow) : undefined;
    const master = kv.get("master") || undefined;
    const isBond = kv.get("masterIsBond") === "1";
    const carrier = kv.get("carrier") === "1" || /Link detected:\s*yes/.test(block);
    out.push(
      compact({
        name,
        mac: usable(perm) ?? usable(kv.get("address")),
        kind,
        speed: d9Speed(kind, maxMbps),
        maxMbps,
        link: carrier,
        operstate: kv.get("operstate") || undefined,
        bond: isBond ? master : undefined,
        bridge: isBond ? kv.get("upper") || undefined : master,
      }) as unknown as Nic,
    );
  }
  return out.sort((a, b) => a.name.localeCompare(b.name, "en", { numeric: true }));
}

function holdsOf(d: Obj): { holds: string; pool?: string } {
  const fs = str(d.fstype);
  const part = (str(d.parttypename) ?? "").toLowerCase();
  if (fs === "zfs_member") return { holds: "zfs", pool: str(d.label) };
  if (part.includes("efi system")) return { holds: "efi" };
  if (part.includes("bios boot")) return { holds: "bios-boot" };
  if (fs === "LVM2_member" || part.includes("lvm")) return { holds: "lvm" };
  if (fs === "swap" || part.includes("swap")) return { holds: "swap" };
  if (part.includes("solaris") || part.includes("zfs")) return { holds: "zfs" };
  return { holds: fs ?? "nothing" };
}

/** `pvesh …/disks/list` (model, serial, health, by-id) and `lsblk -J` (the
 *  partitions, the bus). A disk in no pool is one like any other. */
export function parseDisks(listText: string | undefined, lsblkText: string | undefined): Disk[] {
  const rows = json(listText);
  const blk = ((json(lsblkText) as Obj | null)?.blockdevices ?? []) as Obj[];
  const byPath = new Map(blk.filter((b) => b.type === "disk").map((b) => [str(b.path) ?? `/dev/${String(b.name)}`, b]));
  const out: Disk[] = [];
  for (const r of Array.isArray(rows) ? (rows as Obj[]) : []) {
    const device = str(r.devpath);
    if (!device) continue;
    const b = byPath.get(device);
    const byId = str(r.by_id_link);
    const parts = ((b?.children ?? []) as Obj[]).filter((c) => c.type === "part");
    const whole = b ? holdsOf(b) : { holds: str(r.used) ?? "nothing" };
    out.push(
      compact({
        name: byId && byId !== "n/a" ? byId.replace(/^.*\//, "") : device,
        device,
        model: str(r.model),
        serial: str(r.serial),
        size: num(r.size),
        type: str(r.type),
        bus: b ? str(b.tran) : undefined,
        health: str(r.health),
        holds: whole.holds,
        partitions: parts.map((p) => compact({ device: str(p.path) ?? `/dev/${String(p.name)}`, size: num(p.size), ...holdsOf(p) })),
      }) as unknown as Disk,
    );
  }
  return out;
}

/** `zpool status -L -P -p`, list and root dataset → each pool's layout, its
 *  members by the serial of the disk they are on. Size and used are the root
 *  dataset's, as storage-manager reports the pool (else `zpool list`'s raw). */
export function parseZPools(status: string | undefined, list: string | undefined, roots: string | undefined, disks: Disk[]): ZPool[] {
  const serialOf = (device: string): string | undefined =>
    disks.find((d) => d.device === device || d.partitions.some((p) => p.device === device))?.serial;
  const pools: ZPool[] = [];
  let cur: ZPool | null = null;
  let vdev: Vdev | null = null;
  let group: string | undefined;
  let inConfig = false;
  for (const raw of (status ?? "").split("\n")) {
    const kv = /^\s*(pool|state|config|errors|scan|status|action|see):\s?(.*)$/.exec(raw);
    if (kv && !raw.startsWith("\t")) {
      inConfig = kv[1] === "config";
      if (kv[1] === "pool") {
        cur = { name: kv[2].trim(), vdevs: [] };
        pools.push(cur);
        vdev = null;
        group = undefined;
      } else if (kv[1] === "state" && cur) cur.state = kv[2].trim();
      continue;
    }
    if (!inConfig || !cur || !raw.startsWith("\t")) continue;
    const body = raw.slice(1);
    const depth = Math.floor((body.length - body.trimStart().length) / 2);
    const [name, state] = body.trim().split(/\s+/);
    if (!name || name === "NAME") continue;
    if (depth === 0) {
      if (name !== cur.name) group = name; // logs, cache, special, spares
      vdev = null;
      continue;
    }
    if (depth === 1 && !name.startsWith("/")) {
      vdev = compact({ name, group, state, members: [] }) as unknown as Vdev;
      cur.vdevs.push(vdev);
      continue;
    }
    const member = compact({ device: name, serial: serialOf(name), state }) as Vdev["members"][number];
    if (depth === 1 || !vdev) cur.vdevs.push(compact({ name: "disk", group, state, members: [member] }) as unknown as Vdev);
    else vdev.members.push(member);
  }
  const raws = new Map((list ?? "").split("\n").map((l) => l.split("\t")).filter((f) => f.length >= 8).map((f) => [f[0], f]));
  const root = new Map((roots ?? "").split("\n").map((l) => l.split("\t")).filter((f) => f.length >= 3).map((f) => [f[0], f]));
  for (const p of pools) {
    const r = root.get(p.name);
    const z = raws.get(p.name);
    if (r) {
      p.size = Number(r[1]) + Number(r[2]);
      p.used = Number(r[1]);
    } else if (z) {
      p.size = Number(z[1]);
      p.used = Number(z[2]);
    }
    if (z) p.state = z[7].trim() || p.state;
  }
  return pools;
}

/** The probe's stdout → the node. */
export function parseNodeDiscovery(stdout: string): NodeDiscovery {
  const s = parseProbeSections(stdout);
  const ok = (n: string): string | undefined => (s[n] && s[n].rc === 0 ? s[n].out : undefined);
  const st = json(ok("status")) as Obj | null;
  const cpu = (st?.cpuinfo ?? {}) as Obj;
  const mem = (st?.memory ?? {}) as Obj;
  const disks = parseDisks(ok("disks"), ok("lsblk"));
  const list = (n: string): Obj[] => {
    const v = json(ok(n));
    return Array.isArray(v) ? (v as Obj[]) : [];
  };
  return compact({
    cpu: str(cpu.model),
    cpus: num(cpu.cpus),
    memory: num(mem.total) !== undefined ? Math.round((num(mem.total) as number) / 1048576) : undefined,
    nics: parseNics(ok("nics") ?? ""),
    disks,
    pools: parseZPools(ok("zpool-status"), ok("zpool-list"), ok("zfs-root"), disks),
    storages: list("storage").map((x) =>
      compact({ storage: x.storage, type: x.type, content: x.content, active: x.active === 1, enabled: x.enabled === 1, shared: x.shared === 1, total: x.total, used: x.used, avail: x.avail }),
    ),
    pci: list("pci").map((x) => compact({ id: x.id, class: x.class, vendor: x.vendor_name, device: x.device_name, iommuGroup: x.iommugroup, mdev: x.mdev === 1 ? true : undefined })),
  }) as unknown as NodeDiscovery;
}

/** `corosync-cfgtool -n`: every other node's links, from where the probe ran. */
export function parseCorosync(text: string): Obj[] {
  const out: Obj[] = [];
  let node: string | undefined;
  for (const l of text.split("\n")) {
    const n = /^nodeid:\s*(\d+)/.exec(l.trim());
    if (n) node = n[1];
    const k = /LINK:\s*(\d+)\s+\S+\s+\((.+?)->(.+?)\)\s+(enabled|disabled)\s+(connected|disconnected)/.exec(l);
    if (k) out.push({ nodeid: Number(node), link: Number(k[1]), local: k[2], remote: k[3], enabled: k[4] === "enabled", connected: k[5] === "connected" });
  }
  return out;
}

/** What the machine's discovery adds to the report: where nics[] and disks[]
 *  go (the server, else `attrs`, the machine's own), the ports, the pools. */
export function discoveryObjects(configDir: string, machine: string, machineRef: string, d: NodeDiscovery, attrs: Obj): CmdbObject[] {
  const doc = (readJsonObject(join(configDir, POSITIONS_FILE)) ?? {}) as unknown as PositionsDoc;
  const hit = assetNamed(doc, machine);
  const server = hit && hit.asset.kind === "server" ? hit : null;
  const objects: CmdbObject[] = [];
  const own = compact({ nics: d.nics, disks: d.disks, cpu: d.cpu, memory: d.memory });
  attrs.storages = d.storages;
  attrs.pciDevices = d.pci;
  if (d.cpus !== undefined) attrs.cpus = d.cpus;
  if (server) {
    const ref = `server/${server.key}`;
    objects.push({ ref, class: "server", name: server.key, attributes: own });
    const recorded = server.asset.ports ?? [];
    for (const n of d.nics) {
      const known = recorded.find((p) => (n.mac && p.mac?.toLowerCase() === n.mac) || p.name === n.name);
      // A port the asset records is asset-manager's: only its MAC is news.
      const attributes = known
        ? compact({ asset: { ref }, kind: known.kind, mac: n.mac })
        : compact({ asset: { ref }, kind: n.kind, speed: n.speed, mac: n.mac });
      objects.push({ class: "port", name: known?.name ?? n.name, attributes });
    }
  } else Object.assign(attrs, own);
  for (const p of d.pools) {
    objects.push({
      class: "storage-pool",
      name: p.name, // its key is the name on its node, as storage-manager reports it
      attributes: compact({ type: "zfs", size: p.size, used: p.used, health: poolHealth(p.state), vdevs: p.vdevs, onNode: { ref: machineRef } }),
    });
  }
  return objects;
}
