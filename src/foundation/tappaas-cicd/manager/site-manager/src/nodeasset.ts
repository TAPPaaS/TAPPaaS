// nodeasset.ts — runs asset.ts's decisions: node add's allocation and node
// delete's release, through asset-manager (the one writer of positions.json).
// A failure here is a warning with the command to run by hand, never a failed
// join or a failed delete: the node is in (or out of) the cluster already.

import { spawnSync } from "child_process";
import { existsSync, readFileSync } from "fs";
import { GN, YW, CL, info, warn } from "../../../lib/ts/src/cli";
import { POSITIONS_FILE, PositionsDoc } from "../../../lib/ts/src/positions";
import { AssetFate, DISKS_SH, IDENTITY_SH, MachineIdentity, assetFillArgs, assetPlaying, assetRemovalSteps, diskArgs, identityFromRegistration, matchAsset, newAssetArgs, parseDisks, parseIdentity } from "./asset";
import { defaultConfigDir } from "./config";

export function readPositions(configDir = defaultConfigDir()): PositionsDoc | null {
  const f = `${configDir.replace(/\/$/, "")}/${POSITIONS_FILE}`;
  if (!existsSync(f)) return null;
  try {
    return JSON.parse(readFileSync(f, "utf8")) as PositionsDoc;
  } catch {
    return null;
  }
}

function assetManager(args: string[]): { rc: number; out: string } {
  const r = spawnSync("asset-manager", args, { encoding: "utf8" });
  if (r.error) return { rc: -1, out: r.error.message };
  return { rc: r.status ?? -1, out: `${r.stdout ?? ""}${r.stderr ?? ""}`.trim() };
}

const sshRoot = (host: string, cmd: string): string | null => {
  const r = spawnSync("ssh", ["-o", "ConnectTimeout=10", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", `root@${host}`, cmd], { encoding: "utf8" });
  return r.error || r.status !== 0 ? null : r.stdout ?? "";
};

// The machine's identity: what the installer posted, kept on the node's
// consumed registration (ADR-040 D8's hook), else read over ssh (root, the
// mgmt address it joined at — a node adopted by hand has no registration).
// An installer that posted no disks leaves them to the same ssh read.
export function readIdentity(host: string, name?: string, configDir = defaultConfigDir()): MachineIdentity | null {
  if (name) {
    const f = `${configDir.replace(/\/$/, "")}/provision/${name}.json.consumed`;
    if (existsSync(f)) {
      try {
        const id = identityFromRegistration(JSON.parse(readFileSync(f, "utf8")));
        if (id) {
          if (!id.disks) {
            const out = sshRoot(host, DISKS_SH);
            const disks = out === null ? undefined : parseDisks(out.split("\n"));
            if (disks) id.disks = disks;
          }
          return id;
        }
      } catch { /* unreadable: ssh */ }
    }
  }
  const out = sshRoot(host, IDENTITY_SH);
  return out === null ? null : parseIdentity(out);
}

// node add: the machine's disks become disk assets in its asset (ADR-042 D4),
// through asset-manager; a disk recorded elsewhere moves in. Warnings only.
function recordNodeDisks(key: string, id: MachineIdentity | null): void {
  if (!id?.disks) {
    warn(`  ${key}'s disks could not be read: asset-manager disk adopt ${key} records them after the next site-manager report --discover`);
    return;
  }
  const doc = readPositions();
  if (!doc) return;
  const { calls, notes } = diskArgs(doc, key, id.disks);
  for (const n of notes) warn(`  ${n}`);
  let added = 0;
  let moved = 0;
  for (const c of calls) {
    const r = assetManager(c);
    if (r.rc !== 0) warn(`  ${c[0] === "place" ? `disk ${c[1]} is not placed in ${key}` : `disk ${c[3]} is not recorded`}: ${r.out} — asset-manager ${c.join(" ")}`);
    else if (c[0] === "place") moved++;
    else added++;
  }
  if (added || moved) info(`  ${GN}✓${CL} ${[added ? `${added} disk(s) recorded` : "", moved ? `${moved} recorded disk(s) moved in` : ""].filter(Boolean).join(", ")} in ${key}, by serial`);
  else if (!notes.length) info(`  ${key}'s ${id.disks.length} disk(s) are recorded already`);
}

// node add: the asset for the role `name` (ADR-040 D8). `asset`: --asset, the
// asset-first way; else the machine at `host` is identified and matched, and
// a new asset is made when nothing matches. With a host, its disks are then
// recorded in that asset (ADR-042 D4). Returns the asset's key, or null.
export function allocateNodeAsset(name: string, host: string | null, asset?: string): string | null {
  const doc = readPositions();
  if (!doc) {
    warn(`  no config/${POSITIONS_FILE}: ${name} gets no asset (asset-manager asset add --kind server, then asset allocate <asset> --role ${name})`);
    return null;
  }
  const already = assetPlaying(doc, name);
  if (already) {
    info(`  asset ${already.key} plays ${name} already`);
    if (host) recordNodeDisks(already.key, readIdentity(host, name));
    return already.key;
  }
  let key = asset ?? null;
  let fresh = false;
  // What the machine says of itself: matched by when no asset is named, and
  // checked against and filled into the asset's record either way.
  const id = host ? readIdentity(host, name) : null;
  if (host && !id) warn(`  ${name}'s identity (serial, MACs) could not be read from ${host}: ${key ? "its asset's record is not checked against it" : "no asset is matched by it"}`);
  if (!key) {
    const m = id ? matchAsset(doc, id) : null;
    if (m && "conflict" in m) {
      warn(`  ${m.conflict}: ${name} gets no asset — asset-manager asset allocate <the right one> --role ${name}`);
      return null;
    }
    if (m) {
      key = m.key;
      info(`  asset ${key} is this machine (by its ${m.by})`);
    } else {
      const n = newAssetArgs(doc, id ?? { vendor: null, model: null, serial: null, macs: [], nics: [] }, name);
      const r = assetManager(n.args);
      if (r.rc !== 0) {
        warn(`  no asset recorded for ${name}: ${r.out} — asset-manager ${n.args.join(" ")}`);
        return null;
      }
      key = n.key;
      fresh = true;
      for (const p of n.ports) {
        const pr = assetManager(p);
        if (pr.rc !== 0) warn(`  port ${p[3]} (${p[7]}) is not recorded on ${key}: ${pr.out}`);
      }
      if (n.ports.length) info(`  ${n.ports.length} NIC(s) recorded as ${key}'s ports, by MAC`);
    }
  }
  // A known asset: what its record lacks (serial, vendor, model, the NICs'
  // MACs) from the machine, so the next match — and a DHCP reservation or a
  // registration that names a MAC — finds it.
  if (!fresh && id) {
    const f = assetFillArgs(doc, key, id);
    if (f.mismatch) warn(`  ${f.mismatch}: is ${key} the right asset? Its record is left as it is`);
    for (const c of f.calls) {
      const r = assetManager(c);
      if (r.rc !== 0) warn(`  ${key}'s record is not completed: asset-manager ${c.join(" ")}: ${r.out}`);
    }
    if (f.calls.length) info(`  ${key}'s record completed from the machine (${f.calls.length} change(s))`);
    if (f.note) warn(`  ${f.note}`);
  }
  const r = assetManager(["asset", "allocate", key, "--role", name]);
  if (host) recordNodeDisks(key, id);
  if (r.rc !== 0) {
    warn(`  asset ${key} is not allocated to ${name}: ${r.out} — asset-manager asset allocate ${key} --role ${name}`);
    return key;
  }
  const after = readPositions();
  const placed = after ? assetPlaying(after, name)?.placed ?? null : null;
  info(`  ${GN}✓${CL} asset ${key}${fresh ? " (new)" : ""} plays ${name}${placed ? `, placed in ${placed}` : ""}`);
  if (!placed) info(`  place it where it stands: ${YW}asset-manager place ${name} --rack <rack> --u <n>${CL} (or the console's Physical view)`);
  return key;
}

// node delete: the role ends (D7). fate keep: the asset keeps its placement
// and cables under its own name, in stock or placed for its next role.
// fate remove: the machine leaves the site — released, then its recorded
// cables, its placement and its record removed, each by asset-manager's verb
// (which reports the change to the CMDB). What would happen, for the
// preview, when `apply` is false.
export function releaseNodeAsset(name: string, apply: boolean, fate: AssetFate = "keep", configDir = defaultConfigDir()): void {
  const doc = readPositions(configDir);
  const a = doc ? assetPlaying(doc, name) : null;
  if (!doc || !a) {
    if (!apply) info(`  then: no asset is recorded for ${name}: no asset record changes`);
    return;
  }
  const where = a.placed ? `stays placed in ${a.placed}` : "goes back to stock";
  if (!apply) {
    if (fate === "keep") info(`  then: asset ${a.key} is released from ${name} and kept: it ${where}`);
    else {
      const r = assetRemovalSteps(doc, a.key);
      const parts = [r.cables ? `its ${r.cables} recorded cable(s)` : "", r.placed ? `its placement in ${r.placed}` : "", "its record"].filter(Boolean);
      info(`  then: asset ${a.key} is released from ${name} and removed: ${parts.join(", ")}`);
    }
    return;
  }
  const r = assetManager(["asset", "release", a.key]);
  if (r.rc !== 0) {
    warn(`asset ${a.key} still plays ${name}: ${r.out} — asset-manager asset release ${a.key}`);
    return;
  }
  if (fate === "keep") {
    info(`${GN}✓${CL} asset ${a.key} released from ${name} and kept: it ${where}`);
    return;
  }
  info(`${GN}✓${CL} asset ${a.key} released from ${name}`);
  const after = readPositions(configDir) ?? doc;
  for (const step of assetRemovalSteps(after, a.key).steps) {
    const s = assetManager(step);
    if (s.rc !== 0) {
      warn(`asset ${a.key} is not removed: asset-manager ${step.join(" ")}: ${s.out} — run the rest by hand (asset-manager asset show ${a.key})`);
      return;
    }
  }
  info(`${GN}✓${CL} asset ${a.key} removed: its cables, placement and record`);
}
