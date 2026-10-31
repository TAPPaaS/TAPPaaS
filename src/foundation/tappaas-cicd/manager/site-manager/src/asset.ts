// asset.ts — the asset behind a node (ADR-040 D7, D8): what node add matches
// or creates and allocates, and what node delete releases or removes.
//
// Two ways in, one asset. Asset first: `node add <N> --asset <a>` — the asset
// is checked before anything is installed, and its recorded cable and MAC
// stand in for --switch-port and --mac. Role first: without --asset, the
// machine's own identity (DMI vendor, model, serial; its NICs' MACs), read over
// ssh once it has joined, is matched against the free server assets by D5's
// keys — serial first, then any port's MAC; two matches are a conflict, not a
// guess — and with no match a new asset is created, named by the next free tag
// (srv-NN, O5), the role's name as its display name. Either way the asset is
// then allocated to the role; its placement, if the operator placed the role's
// name already, is the asset's from then on. The CMDB learns of it from
// asset-manager (its report), not from here.
//
// Pure: decisions over a PositionsDoc; nodeasset.ts runs them.

import {
  Asset,
  AssetPort,
  DISK_KINDS,
  PositionsDoc,
  assetMacs,
  assetWithSerial,
  assetsOf,
  cablesOf,
  currentName,
  nextTag,
  placementsOf,
  placeWhere,
} from "../../../lib/ts/src/positions";

// A whole disk of the machine, as the installer posts it or lsblk reads it.
export interface MachineDisk {
  name: string; // its /dev/disk/by-id name, else the kernel's
  model?: string;
  serial?: string;
  size?: number; // bytes
  type?: string; // nvme, ssd, hdd, usb
  bus?: string;
  wwn?: string;
}

// What the machine says about itself (sysfs: /sys/class/dmi/id, /sys/class/net;
// lsblk and /dev/disk/by-id for its disks).
export interface MachineIdentity {
  vendor: string | null;
  model: string | null;
  serial: string | null;
  macs: string[]; // physical NICs', lower case
  nics: { name: string; mac: string }[]; // the same, with the kernel's names
  disks?: MachineDisk[]; // its whole disks; absent: not read
}

// Vendors' placeholders where a serial should be.
const NO_SERIAL = /^(|0+|to be filled by o\.?e\.?m\.?|default string|system serial number|not specified|none|n\/a|unknown|0123456789|1234567890)$/i;
const MAC_RE = /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/;

// The ssh command that prints the identity, one `key=value` per line: the
// three DMI fields, then `nic=<name> <mac>` for every NIC that is a device (no
// bridges, bonds, VLANs or loopback), then the disks: `byid=<link> <kernel
// name>` for every whole-disk /dev/disk/by-id link and `lsblk=<json>`, lsblk's
// whole disks on one line.
export const DISKS_SH =
  "for l in /dev/disk/by-id/*; do case \"$l\" in *-part*) continue;; esac; printf 'byid=%s %s\\n' \"$(basename \"$l\")\" \"$(basename \"$(readlink -f \"$l\")\")\"; done; " +
  "printf 'lsblk=%s\\n' \"$(lsblk -J -d -b -o NAME,MODEL,SERIAL,SIZE,TYPE,TRAN,WWN,ROTA 2>/dev/null | tr -d '\\n')\"";
export const IDENTITY_SH =
  "for f in sys_vendor product_name product_serial; do printf '%s=%s\\n' \"$f\" \"$(cat /sys/class/dmi/id/$f 2>/dev/null | tr -d '\\r\\n')\"; done; " +
  "for d in /sys/class/net/*; do [ -e \"$d/device\" ] || continue; printf 'nic=%s %s\\n' \"$(basename \"$d\")\" \"$(cat \"$d/address\" 2>/dev/null)\"; done; " +
  DISKS_SH;

// A whole disk's kernel name: no partition, zvol, loop, optical or RAM disk.
const WHOLE_DISK = /^(sd[a-z]+|nvme\d+n\d+|hd[a-z]+|vd[a-z]+|xvd[a-z]+)$/;
// The by-id link a disk is named by: a vendor's (ata-, nvme-, scsi-, usb-), not
// a WWN or an EUI; an NVMe namespace's _1 is the disk's own name.
const preferred = (n: string): number => (/^(wwn-|nvme-eui\.|nvme-nvme\.)/.test(n) ? 2 : /^scsi-[0-9a-f]+$/.test(n) ? 1 : 0);
const stableName = (n: string): string => n.replace(/^(nvme-.*)_\d{1,2}$/, "$1");

/** The disks lines of the identity (DISKS_SH) → the whole disks. */
export function parseDisks(lines: string[]): MachineDisk[] | undefined {
  const byId = new Map<string, string>();
  let blk: unknown = undefined;
  for (const line of lines) {
    const i = line.indexOf("=");
    if (i < 0) continue;
    const [k, v] = [line.slice(0, i).trim(), line.slice(i + 1).trim()];
    if (k === "byid") {
      const [link, kname] = v.split(/\s+/, 2);
      const had = byId.get(kname);
      if (link && kname && (!had || preferred(link) < preferred(had) || (preferred(link) === preferred(had) && link.length < had.length))) byId.set(kname, link);
    } else if (k === "lsblk") {
      try {
        blk = JSON.parse(v);
      } catch {
        blk = undefined;
      }
    }
  }
  const devs = (blk as { blockdevices?: Record<string, unknown>[] } | undefined)?.blockdevices;
  if (!Array.isArray(devs)) return undefined;
  const str = (x: unknown): string | undefined => (typeof x === "string" && x.trim() ? x.trim() : undefined);
  const out: MachineDisk[] = [];
  for (const d of devs) {
    const kname = str(d.name)?.replace(/^.*\//, "") ?? "";
    if (d.type !== "disk" || !WHOLE_DISK.test(kname)) continue;
    const tran = str(d.tran);
    const rota = d.rota === true || d.rota === "1" || d.rota === 1;
    const type = tran === "usb" ? "usb" : tran === "nvme" || kname.startsWith("nvme") ? "nvme" : rota ? "hdd" : "ssd";
    const size = typeof d.size === "number" ? d.size : typeof d.size === "string" && /^\d+$/.test(d.size) ? Number(d.size) : undefined;
    const link = byId.get(kname);
    const disk: MachineDisk = { name: link ? stableName(link) : kname, type };
    const model = str(d.model);
    const serial = str(d.serial);
    const wwn = str(d.wwn);
    if (model) disk.model = model;
    if (serial) disk.serial = serial;
    if (size) disk.size = size;
    if (tran) disk.bus = tran;
    if (wwn) disk.wwn = wwn;
    out.push(disk);
  }
  return out;
}

export function parseIdentity(out: string): MachineIdentity {
  const id: MachineIdentity = { vendor: null, model: null, serial: null, macs: [], nics: [] };
  const disks = parseDisks(out.split("\n"));
  if (disks) id.disks = disks;
  for (const line of out.split("\n")) {
    const i = line.indexOf("=");
    if (i < 0) continue;
    const [k, v] = [line.slice(0, i).trim(), line.slice(i + 1).trim()];
    if (k === "sys_vendor" && v) id.vendor = v;
    else if (k === "product_name" && v) id.model = v;
    else if (k === "product_serial" && !NO_SERIAL.test(v)) id.serial = v;
    else if (k === "nic" || k === "mac") {
      const [nic, raw] = k === "nic" ? v.split(/\s+/, 2) : ["", v];
      const m = (raw ?? "").toLowerCase().replace(/-/g, ":");
      if (!MAC_RE.test(m) || m === "00:00:00:00:00:00" || id.macs.includes(m)) continue;
      id.macs.push(m);
      if (nic) id.nics.push({ name: nic, mac: m });
    }
  }
  return id;
}

// The identity the installer posted, kept on the consumed registration by
// node-provisioner (config/provision/<name>.json.consumed, `identity`): the
// hook ADR-040 D8 names. Null when the record has none worth matching by.
export function identityFromRegistration(rec: unknown): MachineIdentity | null {
  const r = rec && typeof rec === "object" ? (rec as { identity?: unknown }).identity : null;
  if (!r || typeof r !== "object") return null;
  const o = r as { vendor?: unknown; model?: unknown; serial?: unknown; nics?: unknown };
  const str = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim() : null);
  const id: MachineIdentity = { vendor: str(o.vendor), model: str(o.model), serial: str(o.serial), macs: [], nics: [] };
  if (id.serial && NO_SERIAL.test(id.serial)) id.serial = null;
  const posted = (r as { disks?: unknown }).disks;
  if (Array.isArray(posted) && posted.length) {
    id.disks = posted
      .filter((x): x is Record<string, unknown> => !!x && typeof x === "object" && !!str(x.name))
      .map((x) => {
        const d: MachineDisk = { name: str(x.name)! };
        for (const k of ["model", "serial", "type", "bus", "wwn"] as const) if (str(x[k])) d[k] = str(x[k])!;
        if (typeof x.size === "number" && x.size > 0) d.size = x.size;
        return d;
      });
  }
  for (const n of Array.isArray(o.nics) ? o.nics : []) {
    const nic = n as { link?: unknown; mac?: unknown };
    const m = str(nic.mac)?.toLowerCase().replace(/-/g, ":") ?? "";
    if (!MAC_RE.test(m) || m === "00:00:00:00:00:00" || id.macs.includes(m)) continue;
    id.macs.push(m);
    id.nics.push({ name: str(nic.link) ?? `nic${id.nics.length + 1}`, mac: m });
  }
  return id.serial || id.macs.length ? id : null;
}

// The server assets a node could be: in no role, here (not ordered, not disposed).
export function freeServers(doc: PositionsDoc): [string, Asset][] {
  return Object.entries(assetsOf(doc)).filter(([, a]) => a.kind === "server" && !a.role && a.stage !== "ordered" && a.stage !== "disposed");
}

export type Match = { key: string; by: "serial" | "mac" } | { conflict: string } | null;

// D5: vendor + serial, then any port's MAC, among the free servers. Vendors
// spell the same serial differently across BIOS versions, so the serial is
// compared case-insensitively and the vendor is not required to agree.
export function matchAsset(doc: PositionsDoc, id: MachineIdentity): Match {
  const free = freeServers(doc);
  const conflict = (hits: [string, Asset][], by: string): Match => ({ conflict: `${by} matches ${hits.length} assets: ${hits.map(([k]) => k).join(", ")}` });
  if (id.serial) {
    const s = id.serial.toLowerCase();
    const hits = free.filter(([, a]) => a.serial && a.serial.toLowerCase() === s);
    if (hits.length === 1) return { key: hits[0][0], by: "serial" };
    if (hits.length > 1) return conflict(hits, `serial ${id.serial}`);
  }
  if (id.macs.length) {
    const hits = free.filter(([, a]) => assetMacs(a).some((m) => id.macs.includes(m.toLowerCase())));
    if (hits.length === 1) return { key: hits[0][0], by: "mac" };
    if (hits.length > 1) return conflict(hits, `the machine's MACs`);
  }
  return null;
}

// --asset <a> before an install: why it cannot play a node, or null.
export function assetProblem(doc: PositionsDoc, key: string): string | null {
  const a = assetsOf(doc)[key];
  if (!a) return `asset ${key} is not recorded (asset-manager asset list)`;
  if (a.kind !== "server") return `asset ${key} is a ${a.kind}: a node's asset is a server`;
  if (a.stage === "ordered") return `asset ${key} is ordered, not here yet (asset-manager asset receive ${key} when it comes)`;
  if (a.stage === "disposed") return `asset ${key} is disposed`;
  if (a.role) return `asset ${key} plays ${a.role} already (asset-manager asset release ${key} first)`;
  return null;
}

// What the asset's records say about where it is cabled: a recorded cable
// from one of its ports to another device (the switch) gives the switch port;
// that port's MAC, or the asset's only MAC, gives the MAC.
export function assetCabling(doc: PositionsDoc, key: string): { switchPort: string | null; mac: string | null; port: string | null } {
  const a = assetsOf(doc)[key];
  if (!a) return { switchPort: null, mac: null, port: null };
  const me = currentName(key, a);
  const cable = cablesOf(doc).find((c) => c.from.device === me || c.to.device === me);
  const mine = cable ? (cable.from.device === me ? cable.from : cable.to) : null;
  const other = cable ? (cable.from.device === me ? cable.to : cable.from) : null;
  const ports: AssetPort[] = a.ports ?? [];
  const onPort = mine ? ports.find((p) => p.name === mine.port)?.mac ?? null : null;
  const macs = assetMacs(a);
  return {
    switchPort: other ? `${other.device}:${other.port}` : null,
    mac: (onPort ?? (macs.length === 1 ? macs[0] : null))?.toLowerCase() ?? null,
    port: mine?.port ?? null,
  };
}

// The `asset-manager` calls that record a machine nobody recorded: `asset add`
// with the next tag, its identity and the role's name shown; then a `port add`
// per NIC with its MAC — what the next node add on this box matches by (D5),
// since a vendor's BIOS may give no serial at all.
export function newAssetArgs(doc: PositionsDoc, id: MachineIdentity, role: string): { key: string; args: string[]; ports: string[][] } {
  const key = nextTag(doc, "server");
  const args = ["asset", "add", key, "--kind", "server", "--display-name", role];
  if (id.vendor) args.push("--vendor", id.vendor);
  if (id.model) args.push("--model", id.model);
  if (id.serial) args.push("--serial", id.serial);
  const ports = id.nics.map((n) => ["port", "add", key, n.name, "--kind", "rj45", "--mac", n.mac]);
  return { key, args, ports };
}

// What node add does with the machine's disks (ADR-042 D4): `disk add` each
// one no asset records into the node's asset, `place --in` it each recorded
// disk that is in stock or in another asset (it moved), nothing for one the
// asset holds already; one without a serial, or whose serial a non-disk
// asset has, is a note.
export function diskArgs(doc: PositionsDoc, key: string, disks: MachineDisk[]): { calls: string[][]; notes: string[] } {
  const calls: string[][] = [];
  const notes: string[] = [];
  const seen = new Set<string>();
  for (const d of disks) {
    if (!d.serial) {
      notes.push(`${d.name} has no serial: not recorded (asset-manager disk add ${key} ${d.name} --serial <serial>)`);
      continue;
    }
    if (seen.has(d.serial.toLowerCase())) continue;
    seen.add(d.serial.toLowerCase());
    const twin = assetWithSerial(doc, d.serial);
    const a = twin ? assetsOf(doc)[twin] : null;
    if (twin && a?.kind !== "disk") {
      notes.push(`${d.name}: serial ${d.serial} is asset ${twin}'s, which is no disk — not recorded`);
      continue;
    }
    if (twin) {
      const m = placementsOf(doc)[twin];
      if (m?.in === key) continue;
      if (a?.stage === "disposed") {
        notes.push(`${d.name}: serial ${d.serial} is disk ${twin}, disposed — not placed`);
        continue;
      }
      calls.push(["place", twin, "--in", key]);
      continue;
    }
    const args = ["disk", "add", key, d.name, "--serial", d.serial];
    if (d.model) args.push("--model", d.model);
    if (d.size) args.push("--size", String(d.size));
    if (d.type && (DISK_KINDS as readonly string[]).includes(d.type)) args.push("--kind", d.type);
    if (d.bus) args.push("--bus", d.bus);
    if (d.wwn) args.push("--wwn", d.wwn);
    calls.push(args);
  }
  return { calls, notes };
}

// What an asset's record lacks that the machine says of itself, as
// asset-manager calls (node add, once the asset is known — matched, or named
// with --asset): its serial, vendor and model where the record has none, and
// its NICs' MACs — a port named as the NIC with no MAC gets it, an asset with
// no ports of its own gets a port per NIC. Ports under other names with no
// MAC are not guessed at: `note` says so. `mismatch`: the record's serial is
// another machine's — then nothing is filled.
export function assetFillArgs(doc: PositionsDoc, key: string, id: MachineIdentity): { calls: string[][]; note: string | null; mismatch: string | null } {
  const a = assetsOf(doc)[key];
  if (!a) return { calls: [], note: null, mismatch: null };
  if (a.serial && id.serial && a.serial.toLowerCase() !== id.serial.toLowerCase()) {
    return { calls: [], note: null, mismatch: `asset ${key} records serial ${a.serial}, the machine says ${id.serial}` };
  }
  const calls: string[][] = [];
  const sets: string[] = [];
  if (!a.serial && id.serial) sets.push(`serial=${id.serial}`);
  if (!a.vendor && id.vendor) sets.push(`vendor=${id.vendor}`);
  if (!a.model && id.model) sets.push(`model=${id.model}`);
  if (sets.length) calls.push(["asset", "modify", key, ...sets.flatMap((x) => ["--set", x])]);
  const known = assetMacs(a).map((m) => m.toLowerCase());
  const own = a.ports ?? [];
  const unplaced: string[] = [];
  for (const n of id.nics) {
    if (known.includes(n.mac)) continue;
    const p = own.find((x) => x.name === n.name);
    if (p && !p.mac) calls.push(["port", "modify", key, n.name, "--set", `mac=${n.mac}`]);
    else if (!p && own.length === 0) calls.push(["port", "add", key, n.name, "--kind", "rj45", "--mac", n.mac]);
    else unplaced.push(`${n.name} ${n.mac}`);
  }
  const note = unplaced.length ? `${key}'s ports do not name these NICs: ${unplaced.join(", ")} — record each MAC on its port (asset-manager port modify ${key} <port> --set mac=<mac>)` : null;
  return { calls, note, mismatch: null };
}

// The asset playing a role (what node delete releases), and where it is.
export function assetPlaying(doc: PositionsDoc, role: string): { key: string; asset: Asset; placed: string | null } | null {
  const hit = Object.entries(assetsOf(doc)).find(([, a]) => a.role === role);
  if (!hit) return null;
  const m = placementsOf(doc)[role];
  return { key: hit[0], asset: hit[1], placed: m ? placeWhere(m) : null };
}

// What becomes of a removed node's asset (node delete --asset): kept — the
// role ends and the asset goes back to stock, or stays placed for its next
// role, its cables recorded — or removed: the machine leaves the site, so
// once released its recorded cables, its placement and its record go too.
// A lost node's asset is removed unless told otherwise.
export type AssetFate = "keep" | "remove";
export const ASSET_FATES: AssetFate[] = ["keep", "remove"];
export function assetFate(given: string | undefined, lost: boolean): AssetFate | { refused: string } {
  if (given === undefined) return lost ? "remove" : "keep";
  if ((ASSET_FATES as string[]).includes(given)) return given as AssetFate;
  return { refused: `--asset is keep or remove, not '${given}'` };
}

// The asset-manager calls that take a released asset off the site, in order:
// a `cable remove` per recorded cable it is an end of (by its own end), its
// `unplace`, then `asset remove`. Each is asset-manager's own verb, so each
// change reaches the CMDB through its change report. Computed on the doc as
// it stands; an asset still in a role is named as it plays (the release comes
// first, nodeasset.ts).
export function assetRemovalSteps(doc: PositionsDoc, key: string): { steps: string[][]; cables: number; placed: string | null } {
  const a = assetsOf(doc)[key];
  if (!a) return { steps: [], cables: 0, placed: null };
  const me = currentName(key, a);
  const steps: string[][] = [];
  const seen = new Set<string>();
  for (const c of cablesOf(doc)) {
    const end = c.from.device === me ? c.from : c.to.device === me ? c.to : null;
    if (!end || seen.has(end.port)) continue;
    seen.add(end.port);
    steps.push(["cable", "remove", `${me}:${end.port}`]);
  }
  const m = placementsOf(doc)[me];
  if (m) steps.push(["unplace", me]);
  steps.push(["asset", "remove", key]);
  return { steps, cables: seen.size, placed: m ? placeWhere(m) : null };
}
