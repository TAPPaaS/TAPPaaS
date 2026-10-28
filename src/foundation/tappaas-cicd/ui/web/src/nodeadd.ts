// nodeadd.ts — what the Add node wizard offers (ADR-037 D4), kept apart from
// the page so it is tested: the switch ports a new node can be cabled to, the
// trunk a port TAPPaaS does not program needs, and the data pool proposed from
// the node's free disks. The verbs decide; these only fill the forms.

import { StorageDisk, TopoSwitch } from "./types";

export interface PortChoice {
  value: string; // <switch>:<port>, node add --switch-port
  label: string;
}

// The ports node add --switch-port can take: on a switch TAPPaaS programs
// (managed auto), a port used for nothing (no type, or parked) or already this
// node's, never a member of an aggregate. Unused ports with no link first: a
// new machine is cabled to a free port.
export function switchPortChoices(switches: TopoSwitch[], node: string): PortChoice[] {
  const out: (PortChoice & { rank: number })[] = [];
  for (const sw of switches) {
    if (sw.managed !== "auto") continue;
    for (const p of sw.ports) {
      if (p.lag || p.lagLead) continue;
      const mine = p.type === "node" && p.target?.name === node;
      // A port with a type, or with something cabled to it (another switch: an
      // inter-switch link), is not free.
      if ((p.type || p.target) && !mine) continue;
      const state = mine ? `${node}'s already` : p.parked ? "parked" : "unused";
      const link = p.link === "up" ? ", link up" : p.link === "down" ? ", no link" : "";
      out.push({ value: `${sw.name}:${p.port}`, label: `${sw.name} port ${p.port} — ${state}${link}`, rank: mine ? 0 : p.link === "up" ? 2 : 1 });
    }
  }
  return out
    .sort((a, b) => a.rank - b.rank || a.value.localeCompare(b.value, "en", { numeric: true }))
    .map(({ value, label }) => ({ value, label }));
}

// The switches TAPPaaS does not program: their ports are configured by hand.
export function manualSwitches(switches: TopoSwitch[]): string[] {
  return switches.filter((s) => s.managed !== "auto").map((s) => s.name);
}

// The VLANs a node trunk carries tagged: every active zone's; mgmt is untagged.
export function nodeTrunkVlans(zones: { state?: string; vlantag?: number }[]): number[] {
  return [...new Set(zones.filter((z) => (z.state === "Active" || z.state === "Mandatory") && (z.vlantag ?? 0) > 0).map((z) => z.vlantag as number))]
    .sort((a, b) => a - b);
}

export function manualTrunkText(vlans: number[]): string {
  return `a trunk: the management network untagged (native), and tagged ${vlans.length ? `VLAN ${vlans.join(", ")}` : "no VLAN (no zone is active yet)"}`;
}

// The disks a pool may be proposed on: healthy, in no pool. An old pool's
// label is erased only with --wipe, so such a disk is offered with a note.
export function poolDisks(disks: StorageDisk[]): StorageDisk[] {
  return disks.filter((d) => d.state === "ok" && !d.zfs && (d.serial || d.byId));
}

export const diskId = (d: StorageDisk): string => d.serial || d.byId || d.device;

export function proposedLayout(count: number): string {
  return count <= 1 ? "single" : count === 2 ? "mirror" : "raidz1";
}

export function proposedPoolName(type: string, taken: string[]): string {
  const cls = type === "hdd" ? "b" : "a";
  for (let n = 1; ; n++) if (!taken.includes(`tank${cls}${n}`)) return `tank${cls}${n}`;
}

// The first proposal: the fast disks if there are any, two of the same size
// when there are two (a mirror), else one.
export function proposedDisks(disks: StorageDisk[]): StorageDisk[] {
  const ok = poolDisks(disks);
  const fast = ok.filter((d) => d.type !== "hdd");
  const pick = fast.length ? fast : ok;
  const pair = pick.find((d, i) => pick.some((e, j) => j !== i && e.size === d.size && e.model === d.model));
  if (pair) return pick.filter((d) => d.size === pair.size && d.model === pair.model).slice(0, 2);
  return pick.slice(0, 1);
}

export function humanSize(bytes: number | null): string {
  if (bytes === null) return "?";
  const units = ["B", "KB", "MB", "GB", "TB", "PB"];
  let v = bytes, i = 0;
  while (v >= 1000 && i < units.length - 1) { v /= 1000; i++; }
  return `${v >= 10 || i === 0 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
}
