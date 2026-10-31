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

// The pool classes, by what they hold (cluster/DESIGN.md, pool tiers).
export const POOL_CLASSES = [
  { cls: "a", label: "tanka — important data and workloads (VM disks, HA replication; fast, redundant)" },
  { cls: "b", label: "tankb — less important workloads and data (no HA replication; cheaper disks)" },
  { cls: "c", label: "tankc — backups (the backup datastore)" },
] as const;
export type PoolClass = (typeof POOL_CLASSES)[number]["cls"];

// The class proposed for disks: fast ones hold the workloads, spinning ones the rest.
export const proposedPoolClass = (type: string): PoolClass => (type === "hdd" ? "b" : "a");

export function proposedPoolName(cls: PoolClass, taken: string[]): string {
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

// Where the stick write is, from site-manager node usb write's output: its
// last progress line ("  41%  734 of 1763 MB  24.5 MB/s, about 40 s left").
export function writeProgress(output: string): { pct: number; text: string } | null {
  let last: { pct: number; text: string } | null = null;
  for (const line of output.split("\n")) {
    const m = /^\s*(\d{1,3})%\s+(.+?)\s*$/.exec(line);
    if (m) last = { pct: Number(m[1]), text: `${m[1]}% — ${m[2]}` };
    else if (/^flushed; ejecting/.test(line.trim())) last = { pct: 100, text: "100% — flushed, ejecting the stick" };
  }
  return last;
}

// ── a node's uplinks (Add node's stages 5a and 5b) ─────────────────────
// site-manager node network show --json, as the console reads it.
export interface NodePort {
  name: string; mac: string; state: string; speed: number; usb: boolean;
  lldp: { chassis: string; name: string; port: string } | null;
}
export interface NodeNetwork {
  node: string;
  live: { ports: NodePort[]; lan: { mode: string; bond: string; members: NodePort[] }; wan: { members: NodePort[] } } | null;
  declared: { lan?: { ports: string[]; mode?: string }; wan?: { ports: string[] } } | null;
  findings: { level?: string; text?: string }[];
}

export const portSpeed = (s: number): string => (s <= 0 ? "" : s >= 1000 ? `${s / 1000}G` : `${s}M`);

// "enp5s0 · up 10G · USW-Pro-XG-10-PoE Port 3": the name, the link, and the
// switch port LLDP sees behind it.
export function portLabel(p: NodePort): string {
  const link = p.state === "up" ? `up ${portSpeed(p.speed)}`.trim() : "no link";
  return [p.name, link, p.lldp ? `${p.lldp.name} ${p.lldp.port}` : ""].filter(Boolean).join(" · ");
}

// The ports a lan leg can be added from: physical, not lan's already and not
// the WAN's (declared or live).
export function lanCandidates(n: NodeNetwork): NodePort[] {
  const lan = new Set((n.live?.lan.members ?? []).map((p) => p.mac));
  const wan = new Set([...(n.declared?.wan?.ports ?? []), ...(n.live?.wan.members ?? []).map((p) => p.mac)]);
  return (n.live?.ports ?? []).filter((p) => !p.usb && !lan.has(p.mac) && !wan.has(p.mac));
}

// The ports the WAN can take: physical and not lan's.
export function wanCandidates(n: NodeNetwork): NodePort[] {
  const lan = new Set((n.live?.lan.members ?? []).map((p) => p.mac));
  return (n.live?.ports ?? []).filter((p) => !p.usb && !lan.has(p.mac));
}

// The declared WAN port, as the node has it.
export function wanPort(n: NodeNetwork): NodePort | null {
  const mac = n.declared?.wan?.ports?.[0];
  if (!mac) return null;
  return (n.live?.ports ?? []).find((p) => p.mac === mac) ?? { name: mac, mac, state: "unknown", speed: -1, usb: false, lldp: null };
}

// The switch port LLDP sees behind a node port, as a --switch-port value
// among the choices: LLDP says "USW-Pro-XG-10-PoE" / "Port 3", the switch
// registry "USW Pro XG 10 PoE" / "3".
export function lldpSwitchPort(p: NodePort | undefined, choices: PortChoice[]): string | null {
  if (!p?.lldp) return null;
  const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, "");
  const num = p.lldp.port.replace(/^\D+/, "");
  const hit = choices.find((c) => {
    const i = c.value.lastIndexOf(":");
    return norm(c.value.slice(0, i)) === norm(p.lldp!.name) && (c.value.slice(i + 1) === num || norm(c.value.slice(i + 1)) === norm(p.lldp!.port));
  });
  return hit?.value ?? null;
}

// ── an Add node session, rebuilt from the records ──────────────────────
// The wizard's state lives in its pop-up only; closed mid-way, it is found
// again from what the console reads anyway — the node add job (GET jobs), the
// node's provisioning progress, its pools and its lan ports — never from the
// browser's storage.

// GET nodes/<name>/progress (reads.ts NodeProgress).
export interface NodeProgress {
  name: string;
  registration: "pending" | "answered" | "none";
  pxe: { enabled: boolean | null; text: string };
  inCluster: boolean | null;
  cluster: string[] | null;
  inSite: boolean;
  siteNodes: string[];
}

export type AddNodeStage = "declare" | "boot" | "wait" | "storage" | "lan" | "wan" | "done";
export const STAGE_NUMBER: Record<AddNodeStage, string> = { declare: "1", boot: "2", wait: "3", storage: "4", lan: "5a", wan: "5b", done: "6" };

// What the wizard knows of a node being added, from its own clicks or the records.
export interface AddNodeFacts {
  job: boolean; // a node add job is attached
  jobLive: boolean; // …and waits or runs
  progress: Pick<NodeProgress, "registration" | "inCluster" | "inSite"> | null;
  pooled: boolean; // a data pool built (or the stage skipped)
  lan: boolean; // the lan stage done (or kept at one port)
  wan: boolean;
}

// Applied, or the records say the node is on its way (registered, or joined).
export function addNodeUnderway(f: Pick<AddNodeFacts, "job" | "progress">): boolean {
  return f.job || (f.progress !== null && (f.progress.registration !== "none" || f.progress.inCluster === true));
}

export function addNodeJoined(p: AddNodeFacts["progress"]): boolean {
  return p !== null && p.inCluster === true && p.inSite;
}

// The stage the wizard stands at. A job that runs before its registration is
// written is still at the boot.
export function addNodeStage(f: AddNodeFacts): AddNodeStage {
  const p = f.progress;
  if (!addNodeUnderway(f)) return "declare";
  if (!p || p.registration === "pending" || (f.jobLive && p.registration === "none" && p.inCluster !== true)) return "boot";
  if (!addNodeJoined(p)) return "wait";
  if (!f.pooled) return "storage";
  if (!f.lan) return "lan";
  if (!f.wan) return "wan";
  return "done";
}

// A job summary, the parts a session reads (types.ts JobSummary).
export interface NodeAddJob {
  id: string; kind: string; state: string; bin: string; verb: string; argv: string[]; object: string;
  created: string; ended: string | null; exit: number | null;
  previewPhase?: { stopped: string | null } | null;
  cancelled?: { was: string } | null;
}

const NODE_NAME = /^tappaas[1-9]$/;

// The node a node add job names: its first positional after the verb's words.
export function nodeAddName(j: Pick<NodeAddJob, "argv" | "verb" | "object">): string | null {
  const first = j.argv.slice(1 + j.verb.split(" ").length).find((a) => !a.startsWith("-"));
  const name = first ?? j.object;
  return NODE_NAME.test(name) ? name : null;
}

// The node add a session hangs on: the newest one applied (`jobs` newest
// first) — not refused, not stopped by its dry run, not cancelled before it ran.
export function latestNodeAdd<J extends NodeAddJob>(jobs: J[]): { name: string; job: J } | null {
  for (const j of jobs) {
    if (j.bin !== "site-manager" || j.verb !== "node add" || j.kind !== "apply") continue;
    if (j.state === "refused" || j.previewPhase?.stopped || j.cancelled?.was === "queued") continue;
    const name = nodeAddName(j);
    if (name) return { name, job: j };
  }
  return null;
}

// How long after its job ended a node still counts as being added: the boot
// window a registration stays open for (node add --ttl, two hours by default,
// a day at most).
export const SESSION_MS = 24 * 3600_000;

// Whether that node is still being added: its job waits or runs; or the job
// ended within SESSION_MS (not stopped by an operator) and the machine is
// still registered for its install, waiting to boot. Once it has joined the
// add is over: a data pool and a second lan port are day-two steps the
// Afterwards stage links, not a reason to hold the wizard open (a one-disk
// node never gets a data pool). null: not known yet (a read is still out).
export function nodeAddOngoing(job: NodeAddJob, now: number, rec: { progress: AddNodeFacts["progress"]; dataPool: boolean | null }): boolean | null {
  if (job.state === "queued" || job.state === "running") return true;
  if (job.cancelled) return false;
  if (now - Date.parse(job.ended ?? job.created) > SESSION_MS) return false;
  const p = rec.progress;
  if (!p) return null;
  return p.registration === "pending";
}

// A session the operator has dismissed ("Done with it") stays dismissed: the
// job's id is kept in the browser. Pure over the stored list, so tests need
// no window; `store` is localStorage in the page.
export const DISMISSED_KEY = "addnode.dismissed";
export interface KeyStore { getItem(k: string): string | null; setItem(k: string, v: string): void }
export function dismissedJobs(store: KeyStore | null): string[] {
  try {
    const v = JSON.parse(store?.getItem(DISMISSED_KEY) ?? "[]") as unknown;
    return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : [];
  } catch {
    return [];
  }
}
export function dismissJob(store: KeyStore | null, jobId: string): string[] {
  const ids = [...new Set([...dismissedJobs(store), jobId])].slice(-20);
  try {
    store?.setItem(DISMISSED_KEY, JSON.stringify(ids));
  } catch {
    /* no storage: dismissed for this page only */
  }
  return ids;
}

// How far node add's own output has come, before the records say so (they are
// read every ten seconds): the step it is on, the switch port it set up, and
// whether the machine can be booted now.
export function setupFromOutput(raw: string): { ready: boolean; step: string | null; port: string | null } {
  // The job's log carries the manager's colours.
  // eslint-disable-next-line no-control-regex
  const output = raw.replace(/\x1b\[[0-9;]*[A-Za-z]/g, "");
  const steps = [...output.matchAll(/^\[node add \d+\] (.+)$/gm)].map((m) => m[1]);
  const port = /^\s*✓ (.+ port .+ is .+: a node trunk.*)$/m.exec(output)?.[1] ?? null;
  return { ready: steps.some((s) => s.startsWith("boot the machine now")), step: steps[steps.length - 1] ?? null, port };
}

// Stage 1's one line once the node is declared (its job past the dry run):
// what the job is at, from its output and the node's records.
export function declaredLine(name: string, setup: { ready: boolean; step: string | null; port: string | null }, f: { live: boolean; answered: boolean; joined: boolean }): string {
  if (f.joined) return `${name} is declared and has joined the cluster.`;
  if (!f.live) return `${name} is declared; its job has ended: stage 3 has its output.`;
  if (f.answered) return `${name} is declared; its installer is running: stage 3 watches it.`;
  if (setup.ready) return `${name} is declared: boot it now, from the network or the USB stick${setup.port ? ` (${setup.port})` : ""}.`;
  return `${name} is declared; getting ready: ${setup.step ?? "starting"}…`;
}

// The last lines a failed job printed, without its colours or blank lines.
export function lastLines(raw: string, n = 8): string[] {
  // eslint-disable-next-line no-control-regex
  const lines = raw.replace(/\x1b\[[0-9;]*[A-Za-z]/g, "").split("\n").map((l) => l.trimEnd()).filter((l) => l.trim() !== "");
  return lines.slice(-n);
}
