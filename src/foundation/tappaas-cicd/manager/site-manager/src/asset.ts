// asset.ts — the asset behind a node (ADR-040 D7, D8): what node add matches
// or creates and allocates, and what node delete releases.
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
  PositionsDoc,
  assetMacs,
  assetsOf,
  cablesOf,
  currentName,
  nextTag,
  placementsOf,
  placeWhere,
} from "../../../lib/ts/src/positions";

// What the machine says about itself (sysfs: /sys/class/dmi/id, /sys/class/net).
export interface MachineIdentity {
  vendor: string | null;
  model: string | null;
  serial: string | null;
  macs: string[]; // physical NICs', lower case
  nics: { name: string; mac: string }[]; // the same, with the kernel's names
}

// Vendors' placeholders where a serial should be.
const NO_SERIAL = /^(|0+|to be filled by o\.?e\.?m\.?|default string|system serial number|not specified|none|n\/a|unknown|0123456789|1234567890)$/i;
const MAC_RE = /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/;

// The ssh command that prints the identity, one `key=value` per line: the
// three DMI fields, then `nic=<name> <mac>` for every NIC that is a device (no
// bridges, bonds, VLANs or loopback).
export const IDENTITY_SH =
  "for f in sys_vendor product_name product_serial; do printf '%s=%s\\n' \"$f\" \"$(cat /sys/class/dmi/id/$f 2>/dev/null | tr -d '\\r\\n')\"; done; " +
  "for d in /sys/class/net/*; do [ -e \"$d/device\" ] || continue; printf 'nic=%s %s\\n' \"$(basename \"$d\")\" \"$(cat \"$d/address\" 2>/dev/null)\"; done";

export function parseIdentity(out: string): MachineIdentity {
  const id: MachineIdentity = { vendor: null, model: null, serial: null, macs: [], nics: [] };
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

// The asset playing a role (what node delete releases), and where it is.
export function assetPlaying(doc: PositionsDoc, role: string): { key: string; asset: Asset; placed: string | null } | null {
  const hit = Object.entries(assetsOf(doc)).find(([, a]) => a.role === role);
  if (!hit) return null;
  const m = placementsOf(doc)[role];
  return { key: hit[0], asset: hit[1], placed: m ? placeWhere(m) : null };
}
