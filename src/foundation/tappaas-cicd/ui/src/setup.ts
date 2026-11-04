// setup.ts — the Setup wizard's checklist (ADR-034 D10, spike §5.12). Its
// state is derived from the records every time, never stored, so the wizard
// resumes for free: setupSteps() is a pure function of what the records say;
// gatherSetup() reads them (config files, the managers, lib/ts cluster.ts for
// membership). Each step is then a form over its verbs in the front end, run
// as jobs with their previews.
//
//   firstnode  the first node has a data pool, or "boot pool only" was answered
//   nodes      optional: every node site.json declares is a cluster member, and
//              there is more than one or "no more machines" was answered
//   vpn        the admin VPN has at least one peer (network-manager wgvpn list)
//   backup, identity, logging   config/<module>.json exists and its module
//              test passed the last time it ran. The tests run only as jobs
//              (POST /setup/check, the page's Check button; the step's Test
//              button): three tests per read was the cost of every Setup
//              view. Their last result is kept in the state directory
//              (setup-tests.json) and read back like any record.
//   bootstrap  config/identities holds an organization and a user
//   repos      optional: a repository beside TAPPaaS, or "TAPPaaS only" answered
//   switch     optional: a switch registered and interrogated (ports discovered),
//              or "none" answered
//   wifi       optional: every active Client zone (zones.json) has an SSID an
//              access point maps to it (ap-manager list --json); a name
//              zones.json declares that no AP broadcasts is not WiFi yet
//   physical   optional (Day 2): the site's rooms are recorded and every node
//              and switch is placed, in a rack or loose in a room
//              (config/positions.json, racks.json until migration 0020);
//              the devices recorded there that nothing manages are listed
//   stacks     optional: which stacks have modules installed
//   public     optional (ADR-043 D10): the default environment is public (wildcard
//              or per-service), or "stay local" was answered
//
// The order is Day 1's (operator, 2026-11-02): first node, more nodes, the
// admin VPN, the foundation with sign-in, repositories, switches, Wi-Fi, the
// physical site, stacks, and making it public. An answer an optional step can
// take ("none") is a record of the console's (setup-answers.json in its state
// directory), so the step reads as done without anything to install.

import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, unlinkSync } from "fs";
import { join } from "path";
import { writeJsonAtomic } from "../../lib/ts/src/config-io";
import { clusterNodeNames } from "../../lib/ts/src/nodes";
import { LEGACY_RACKS_FILE, POSITIONS_FILE, PositionsDoc, placementsOf, recordedDevicesOf, roomsOf } from "../../lib/ts/src/positions";
import { readZonesFile } from "../../lib/ts/src/zones";
import { AccessConfig, setupState } from "./access";
import { Runner } from "./run";

export interface TestResult {
  rc: number;
  tail: string;
  at: string; // when the test ran (ISO)
  sweep?: boolean; // the sweep updated and tested the module (config/last-update-result.json), not an explicit test
}

export const SETUP_MODULES = ["backup", "identity", "logging"] as const;
export const TESTS_FILE = "setup-tests.json"; // in the state directory
export const ANSWERS_FILE = "setup-answers.json"; // in the state directory

// What each step that can be answered takes as its answer.
export const ANSWERS = { firstnode: "boot-only", firstlan: ["port", "alone"], nodes: "no-more", repos: "tappaas-only", switch: "no-more", wifi: "no-more", public: "stay-local" } as const;
// The answers a step takes: one, or (firstlan) a choice.
const choices = (step: AnswerStep): readonly string[] => {
  const v: string | readonly string[] = ANSWERS[step];
  return typeof v === "string" ? [v] : v;
};
// An answer an older console recorded, read as today's: "none" (no switch managed) is "no more switches".
const LEGACY_ANSWERS: Partial<Record<AnswerStep, string[]>> = { switch: ["none"] };
const answered = (a: SetupAnswers, step: AnswerStep): boolean => choices(step).includes(a[step] ?? "") || (LEGACY_ANSWERS[step] ?? []).includes(a[step] ?? "");
export type AnswerStep = keyof typeof ANSWERS;
export type SetupAnswers = Partial<Record<AnswerStep, string>>;

export interface SetupInputs {
  defaultEnv: string | null;
  defaultDomain?: string | null; // the default environment's primary domain
  dnsMode: "wildcard" | "per-service" | "local" | null;
  certRefids: Record<string, unknown> | null;
  modules: Record<"backup" | "identity" | "logging", { config: boolean; test: TestResult | null }>;
  identities: { organizations: number; users: number };
  siteNodes: string[];
  clusterNodes: string[] | null; // null: membership could not be read
  switches: { name: string; ports: number; discovered: number; controller: string | null; manual?: boolean }[] | null;
  vpnPeers: string[] | null; // null: wgvpn list could not be read
  wifi: WifiInputs;
  physical?: PhysicalInputs | null; // null: positions.json could not be read
  stacks: string[];
  firstNode?: { name: string; pools: string[]; lanPorts?: string[] } | null; // its record's storagePools and uplinks.lan.ports (MACs); null: no node record
  repositories?: string[]; // site.json repositories[].name
  answers?: SetupAnswers;
}

// What positions.json says of the site's hardware: its rooms (and where), the
// devices placed somewhere, the devices recorded there that nothing manages.
export interface PhysicalInputs {
  rooms: { name: string; location: string | null }[];
  placed: string[];
  recorded: { name: string; kind: string }[];
}

export interface WifiInputs {
  zones: { name: string; type: string | null; state: string | null; vlan: number | null; ssid: string | null }[]; // zones.json
  aps: { name: string; ssids: { name: string; zone: string | null }[] }[] | null; // null: ap-manager list could not be read
}

export type StepId = "firstnode" | "nodes" | "vpn" | "bootstrap" | "repos" | "switch" | "wifi" | "physical" | "stacks" | "public";

export interface SetupStep {
  id: StepId;
  title: string;
  required: boolean;
  done: boolean | null; // null: not known (a read failed)
  detail: string;
}

const MODULE_NAMES = { backup: "backup", identity: "identity", logging: "logging" };

// One foundation module's part of its step: installed, and its test passed.
export function moduleState(s: { config: boolean; test: TestResult | null }): { done: boolean | null; detail: string } {
  if (!s.config) return { done: false, detail: "not installed" };
  if (s.test === null) return { done: null, detail: "installed, not tested yet: Check runs it" };
  const when = s.test.at.replace("T", " ").replace(/\.\d+Z$/, "Z");
  if (s.test.rc === 0) return { done: true, detail: s.test.sweep ? `tested by the sweep (${when})` : `test passed (${when})` };
  return { done: false, detail: `test failed (${when}): ${s.test.tail}` };
}

export function setupSteps(i: SetupInputs): SetupStep[] {
  const steps: SetupStep[] = [];
  const answer = i.answers ?? {};

  // 1 · the first node: its disks (a data pool, or the boot pool alone, said so)
  // and its LAN uplink. The install guesses the LAN port; it counts once
  // confirmed or chosen here, or "this machine alone" is answered — or on a site
  // whose other nodes already reach it on that port.
  const fn = i.firstNode;
  const fnTitle = "First node — its disks and LAN uplink";
  if (fn === undefined || fn === null) steps.push({ id: "firstnode", title: fnTitle, required: true, done: null, detail: "no node record yet" });
  else {
    const disks = fn.pools.length
      ? { done: true, text: `disks: ${fn.pools.join(", ")}` }
      : answer.firstnode === ANSWERS.firstnode
        ? { done: true, text: "disks: the boot pool only, as answered" }
        : { done: false, text: 'no data pool: make one from its free disks, or answer "boot pool only"' };
    const lanPorts = fn.lanPorts ?? [];
    const lan = answer.firstlan === "alone"
      ? { done: true, text: "LAN: this machine alone, as answered" }
      : answer.firstlan === "port" && lanPorts.length
        ? { done: true, text: `LAN on ${lanPorts.join(", ")}` }
        : i.siteNodes.length > 1 && lanPorts.length
          ? { done: true, text: `LAN on ${lanPorts.join(", ")}, which the other nodes reach it on` }
          : lanPorts.length
            ? { done: false, text: `LAN on ${lanPorts.join(", ")}, as the install guessed: confirm it, or choose the port the switch is on` }
            : { done: false, text: 'no LAN port: choose the port the switch is on, or answer "this machine alone"' };
    steps.push({ id: "firstnode", title: fnTitle, required: true, done: disks.done && lan.done, detail: `${fn.name}: ${disks.text}; ${lan.text}` });
  }

  // 2 · more nodes (optional).
  if (i.clusterNodes === null) {
    steps.push({ id: "nodes", title: "More nodes (optional)", required: false, done: null, detail: "the cluster's membership could not be read" });
  } else {
    const missing = i.siteNodes.filter((n) => !i.clusterNodes!.includes(n));
    const done = missing.length === 0 && (i.siteNodes.length > 1 || answer.nodes === ANSWERS.nodes);
    const detail = missing.length
      ? `not joined: ${missing.join(", ")}`
      : i.siteNodes.length > 1
        ? `${i.siteNodes.length} node(s), all cluster members: ${i.siteNodes.join(", ")}`
        : answer.nodes === ANSWERS.nodes
          ? `${i.siteNodes.join(", ")} alone, as answered`
          : `${i.siteNodes.join(", ") || "no node"} alone: add a machine, or answer "no more machines"`;
    steps.push({ id: "nodes", title: "More nodes (optional)", required: false, done, detail });
  }

  // 3 · the admin VPN: the gate is reachable from mgmt and the VPN only.
  if (i.vpnPeers === null) steps.push({ id: "vpn", title: "The admin VPN", required: true, done: null, detail: "network-manager wgvpn list could not be read" });
  else steps.push({ id: "vpn", title: "The admin VPN", required: true, done: i.vpnPeers.length > 0, detail: i.vpnPeers.length ? `peer(s): ${i.vpnPeers.join(", ")}` : "no peer yet: enrol a device" });

  // 4 · the rest of the foundation, and you in it: one step, one job (Rest of
  // foundation). Backup, identity and logging are its parts: each installed and
  // its test passed, and an organization with a user.
  const parts = SETUP_MODULES.map((m) => ({ m, ...moduleState(i.modules[m]) }));
  const boot = i.identities.organizations > 0 && i.identities.users > 0;
  const fdone = parts.some((p) => p.done === false) || !boot ? false : parts.some((p) => p.done === null) ? null : true;
  const fdetail = [
    ...parts.map((p) => `${MODULE_NAMES[p.m]}: ${p.detail}`),
    boot ? `you: ${i.identities.organizations} organization(s), ${i.identities.users} user(s)` : "you: no organization or user yet",
  ].join("; ");
  steps.push({ id: "bootstrap", title: "Rest of foundation — backup, identity, logging, and you", required: true, done: fdone, detail: fdetail });

  // 5 · repositories (optional).
  const repos = i.repositories ?? [];
  const extra = repos.filter((r) => r !== "TAPPaaS");
  steps.push({
    id: "repos",
    title: "Repositories (optional)",
    required: false,
    done: extra.length > 0 || answer.repos === ANSWERS.repos,
    detail: extra.length ? `registered: ${repos.join(", ")}` : answer.repos === ANSWERS.repos ? "TAPPaaS only, as answered" : "TAPPaaS only: add Community or another, or answer \"TAPPaaS only\"",
  });

  // 6 · the switch fabric (optional), as More nodes: add switches until "no
  // more switches". A switch TAPPaaS programs counts once its ports are read; one
  // managed outside TAPPaaS counts as recorded.
  if (i.switches === null) {
    steps.push({ id: "switch", title: "Switch fabric (optional)", required: false, done: answered(answer, "switch") ? true : null, detail: "switch-configuration-actual.json could not be read" });
  } else {
    const line = (s: NonNullable<SetupInputs["switches"]>[number]) =>
      s.manual ? `${s.name}: managed outside TAPPaaS, ${s.ports} port(s) recorded` : `${s.name}: ${s.ports} port(s), ${s.discovered} discovered${s.controller ? ` via ${s.controller}` : ""}`;
    const unread = i.switches.filter((s) => !s.manual && s.discovered === 0).map((s) => s.name);
    const list = i.switches.map(line).join("; ");
    const done = unread.length === 0 && (i.switches.length > 0 || answered(answer, "switch"));
    const detail = unread.length
      ? `${list}; ports not read yet on ${unread.join(", ")}: discover them in Add a switch`
      : i.switches.length === 0
        ? answered(answer, "switch")
          ? "no switch, as answered: the VLANs on the switches are set by hand"
          : "no switch yet: add one, or answer \"no more switches\""
        : answered(answer, "switch")
          ? `${list}; no more switches, as answered`
          : list;
    steps.push({ id: "switch", title: "Switch fabric (optional)", required: false, done, detail });
  }

  // 7–9 · Wi-Fi, the physical site, stacks.
  steps.push(wifiStep(i.wifi, answered(answer, "wifi")));
  steps.push(physicalStep(i.physical, i.siteNodes, (i.switches ?? []).map((s) => s.name)));
  steps.push({ id: "stacks", title: "Stacks (optional)", required: false, done: i.stacks.length > 0, detail: i.stacks.length ? `installed: ${i.stacks.join(", ")}` : "none yet" });

  // 10 · make it public (optional, ADR-043 D10): the issuer of published names.
  const pub = i.dnsMode === "wildcard" || i.dnsMode === "per-service";
  steps.push({
    id: "public",
    title: "Make it public (optional)",
    required: false,
    done: pub || answer.public === ANSWERS.public,
    detail: pub
      ? `${i.defaultEnv ?? "the default environment"} is public (dnsMode ${i.dnsMode})`
      : i.dnsMode === "local"
        ? answer.public === ANSWERS.public
          ? "it stays local, as answered: the site's own CA signs its names"
          : "local: the site's own CA signs its names, and each person imports it. Going public needs a DNS provider or public records"
        : "no default environment",
  });
  return steps;
}

// The zones that should have WiFi: active (no state is Active) and of type Client.
export function clientZonesWithoutWifi(w: WifiInputs): { name: string; declared: string | null }[] {
  const served = new Set((w.aps ?? []).flatMap((a) => a.ssids.map((s) => s.zone)).filter((z): z is string => !!z));
  return w.zones
    .filter((z) => z.type === "Client" && (z.state ?? "Active") === "Active" && !served.has(z.name))
    .map((z) => ({ name: z.name, declared: z.ssid && !/^<.*>$/.test(z.ssid) ? z.ssid : null }));
}

// As More nodes: add Wi-Fi until every Client zone has an SSID, or until "no
// more Wi-Fi" says the rest stay without.
export function wifiStep(w: WifiInputs, noMore = false): SetupStep {
  const title = "WiFi (optional)";
  const clients = w.zones.filter((z) => z.type === "Client" && (z.state ?? "Active") === "Active").map((z) => z.name);
  if (clients.length === 0) return { id: "wifi", title, required: false, done: true, detail: "no active Client zone: nothing to broadcast" };
  if (w.aps === null) return { id: "wifi", title, required: false, done: null, detail: "ap-manager list could not be read" };
  const missing = clientZonesWithoutWifi(w);
  if (missing.length === 0) {
    const names = w.aps.flatMap((a) => a.ssids.filter((s) => s.zone && clients.includes(s.zone)).map((s) => `${s.name} → ${s.zone}`));
    return { id: "wifi", title, required: false, done: true, detail: `every active Client zone has an SSID: ${names.join(", ")}` };
  }
  const named = missing.map((z) => (z.declared ? `${z.name} (zones.json names ${z.declared}; no access point broadcasts it)` : z.name)).join(", ");
  if (noMore) return { id: "wifi", title, required: false, done: true, detail: `no more Wi-Fi, as answered; without an SSID: ${named}` };
  return { id: "wifi", title, required: false, done: false, detail: w.aps.length === 0 ? `no access point registered yet (ap-manager add); no SSID for: ${named}` : `no SSID for: ${named}` };
}

// The physical site: the rooms, then every node and switch placed (Day 2).
export function physicalStep(p: PhysicalInputs | null | undefined, nodes: string[], switches: string[]): SetupStep {
  const title = "The physical site (optional)";
  if (p === null) return { id: "physical", title, required: false, done: null, detail: "config/positions.json could not be read" };
  const rooms = p?.rooms ?? [];
  const placed = new Set(p?.placed ?? []);
  const open = [...nodes, ...switches].filter((d) => !placed.has(d));
  const recorded = p?.recorded ?? [];
  const what = recorded.length ? `; recorded: ${recorded.map((d) => `${d.name} (${d.kind})`).join(", ")}` : "; nothing the cluster cannot see is recorded yet (a modem, a patch panel)";
  if (rooms.length === 0) return { id: "physical", title, required: false, done: false, detail: "no room recorded yet (config/positions.json)" };
  const where = `${rooms.length} room(s): ${rooms.map((r) => (r.location ? `${r.name} at ${r.location}` : r.name)).join(", ")}`;
  return {
    id: "physical",
    title,
    required: false,
    done: open.length === 0,
    detail: open.length ? `${where}; placed nowhere: ${open.join(", ")}${what}` : `${where}; every node and switch placed${what}`,
  };
}

// positions.json (racks.json before migration 0020); an absent file is an empty one.
export function readPhysical(configDir: string): PhysicalInputs | null {
  const file = [POSITIONS_FILE, LEGACY_RACKS_FILE].map((f) => join(configDir, f)).find((f) => existsSync(f));
  if (!file) return { rooms: [], placed: [], recorded: [] };
  const doc = readJson(file) as PositionsDoc | null;
  if (!doc) return null;
  return {
    rooms: Object.entries(roomsOf(doc)).map(([name, r]) => ({ name, location: r.location ?? null })),
    placed: Object.keys(placementsOf(doc)),
    // What nothing manages: an asset playing a node, a switch or an AP is that one.
    recorded: recordedDevicesOf(doc)
      .filter((d) => !(d.asset.role && ["server", "switch", "access-point"].includes(d.asset.kind)))
      .map((d) => ({ name: d.name, kind: d.asset.kind })),
  };
}

export function setupComplete(steps: SetupStep[]): boolean {
  return steps.every((s) => !s.required || s.done === true);
}

// ── parsing what the records say ──────────────────────────────────────

// `network-manager wgvpn list`: the rows under "peers :".
export function parseWgvpnPeers(out: string): string[] {
  const lines = out.replace(/\x1b\[[0-9;]*m/g, "").split("\n");
  const at = lines.findIndex((l) => /^peers\s*:/.test(l));
  if (at < 0) return [];
  const peers: string[] = [];
  for (const l of lines.slice(at + 1)) {
    const m = /^\s+-\s+(\S+)/.exec(l);
    if (m) peers.push(m[1]);
    else if (l.trim() && !/^\s/.test(l)) break;
  }
  return peers;
}

// zones.json's zones, as much of each as the WiFi step reads; none without the file.
export function readWifiZones(file: string): WifiInputs["zones"] {
  if (!existsSync(file)) return [];
  try {
    return readZonesFile(file).entries.map(([name, z]) => ({
      name,
      type: typeof z.type === "string" ? z.type : null,
      state: typeof z.state === "string" ? z.state : null,
      vlan: typeof z.vlantag === "number" ? z.vlantag : null,
      ssid: typeof z.SSID === "string" ? z.SSID : null,
    }));
  } catch {
    return [];
  }
}

// `ap-manager list --json`: each AP and the SSIDs it maps to a zone; null
// when it is not that document.
export function parseApList(out: string): WifiInputs["aps"] {
  try {
    const doc = JSON.parse(out) as unknown;
    if (!Array.isArray(doc)) return null;
    return doc
      .filter((a): a is { name: string; ssids?: unknown } => !!a && typeof (a as { name?: unknown }).name === "string")
      .map((a) => ({
        name: a.name,
        ssids: (Array.isArray(a.ssids) ? a.ssids : [])
          .filter((s): s is { name: string; zone?: unknown } => !!s && typeof (s as { name?: unknown }).name === "string")
          .map((s) => ({ name: s.name, zone: typeof s.zone === "string" ? s.zone : null })),
      }));
  } catch {
    return null;
  }
}

export function parseSwitches(doc: unknown): SetupInputs["switches"] {
  const sw = (doc as { switches?: Record<string, { controller?: string; managed?: string; ports?: Record<string, { source?: string }> }> })?.switches;
  if (!sw || typeof sw !== "object") return [];
  return Object.entries(sw).map(([name, s]) => {
    const ports = Object.values(s.ports ?? {});
    return { name, ports: ports.length, discovered: ports.filter((p) => p.source === "discovered").length, controller: s.controller ?? null, manual: s.managed === "manual" };
  });
}

function readJson(f: string): Record<string, unknown> | null {
  try {
    return existsSync(f) ? (JSON.parse(readFileSync(f, "utf8")) as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

function countJson(dir: string): number {
  try {
    return readdirSync(dir).filter((f) => f.endsWith(".json")).length;
  } catch {
    return 0;
  }
}

export interface GatherDeps {
  configDir: string;
  stateDir: string; // where the last module test results are kept (TESTS_FILE)
  run: Runner;
  clusterNodes: (siteNodes: string[]) => string[] | null;
  stacks: () => Promise<string[]>;
}

// The last result of each foundation module's test, as its job left it
// (recordSetupTest); a module never tested (or a file never written) has none.
export function readSetupTests(stateDir: string): Partial<Record<(typeof SETUP_MODULES)[number], TestResult>> {
  const doc = readJson(join(stateDir, TESTS_FILE)) ?? {};
  const out: Partial<Record<(typeof SETUP_MODULES)[number], TestResult>> = {};
  for (const m of SETUP_MODULES) {
    const t = doc[m] as Partial<TestResult> | undefined;
    if (t && typeof t.rc === "number" && typeof t.at === "string") out[m] = { rc: t.rc, tail: typeof t.tail === "string" ? t.tail : "", at: t.at };
  }
  return out;
}

// The sweep counts as a test: `module update` tests each module it updates
// (Test Step 4), and config/last-update-result.json records a run that
// succeeded for every module. A module whose config was written before that
// run ended, and that is not among its failed modules, has therefore passed
// its test at the run's end; an explicit test or a Test job that is newer wins.
export function sweepTestResult(configDir: string, m: string): TestResult | null {
  const r = readJson(join(configDir, "last-update-result.json"));
  if (!r || r.ok !== true || typeof r.end_time !== "string") return null;
  const failed = Array.isArray(r.failed_modules) ? (r.failed_modules as unknown[]).map(String) : [];
  if (failed.includes(m)) return null;
  const end = Date.parse(r.end_time.replace(" ", "T")); // the sweep's local time, no zone
  if (Number.isNaN(end)) return null;
  try {
    if (statSync(join(configDir, `${m}.json`)).mtimeMs > end) return null; // installed after that run
  } catch {
    return null;
  }
  return { rc: 0, tail: "updated and tested by the sweep", at: new Date(end).toISOString(), sweep: true };
}

// What the page's Check tests: every installed foundation module (fast mode;
// the deep suite is a job of its own). A module no longer installed keeps no
// result.
export function setupCheckModules(configDir: string, stateDir: string): (typeof SETUP_MODULES)[number][] {
  const results = readSetupTests(stateDir);
  const installed = SETUP_MODULES.filter((m) => existsSync(join(configDir, `${m}.json`)));
  const gone = SETUP_MODULES.filter((m) => results[m] !== undefined && !installed.includes(m));
  if (gone.length) {
    for (const m of gone) delete results[m];
    writeJsonAtomic(join(stateDir, TESTS_FILE), results);
  }
  return installed;
}

// A finished job that ran a foundation module's test (Check, the step's Test
// button, or the verb typed in a form): its result is kept where readSetupTests
// finds it. A job that could not run, or was cut off, says nothing, and the
// last result stands. Returns the module it recorded, or null.
export function recordSetupTest(stateDir: string, job: { argv: string[]; state: string; exit: number | null; ended: string | null }, tail: string): string | null {
  const [bin, verb, m] = job.argv;
  if (bin !== "module-manager" || verb !== "test" || !(SETUP_MODULES as readonly string[]).includes(m)) return null;
  if (job.state !== "done" || job.exit === null || job.exit < 0 || !job.ended) return null;
  const results = readSetupTests(stateDir);
  results[m as (typeof SETUP_MODULES)[number]] = { rc: job.exit, tail: tail.replace(/\x1b\[[0-9;]*m/g, "").trim().split("\n").slice(-1)[0] ?? "", at: job.ended };
  mkdirSync(stateDir, { recursive: true });
  writeJsonAtomic(join(stateDir, TESTS_FILE), results);
  return m;
}

export async function gatherSetup(d: GatherDeps): Promise<SetupInputs> {
  const site = readJson(join(d.configDir, "site.json")) ?? {};
  const defaultEnv = (site.defaultEnvironment as string | undefined) ?? (site.name as string | undefined) ?? null;
  const envDoc = defaultEnv ? readJson(join(d.configDir, "environments", `${defaultEnv}.json`)) : null;
  const dm = (envDoc?.domains as { dnsMode?: string } | undefined)?.dnsMode;
  const dnsMode = (dm === "wildcard" || dm === "local" ? dm : envDoc ? "per-service" : null) as SetupInputs["dnsMode"];
  // The cluster's nodes are their pvehost instances (ADR-036 D6).
  const siteNodes = clusterNodeNames(d.configDir);
  // The module tests are not run here (every Setup read gathers): their last
  // result is a record in the state directory, written by recordSetupTest.
  const tests = readSetupTests(d.stateDir);
  const modules = {} as SetupInputs["modules"];
  for (const m of SETUP_MODULES) {
    const config = existsSync(join(d.configDir, `${m}.json`));
    const explicit = config ? (tests[m] ?? null) : null;
    const swept = config ? sweepTestResult(d.configDir, m) : null;
    // The newer of an explicit test and the last successful sweep.
    modules[m] = { config, test: explicit && swept ? (Date.parse(explicit.at) >= Date.parse(swept.at) ? explicit : swept) : (explicit ?? swept) };
  }
  const idDir = join(d.configDir, existsSync(join(d.configDir, "identities")) ? "identities" : "people");
  const [vpn, aps] = await Promise.all([d.run("network-manager", ["wgvpn", "list"], 60_000), d.run("ap-manager", ["list", "--json"], 60_000)]);
  return {
    defaultEnv,
    defaultDomain: ((envDoc as { domains?: { primary?: string } } | null)?.domains?.primary) ?? null,
    dnsMode,
    certRefids: readJson(join(d.configDir, "cert-refids.json")),
    modules,
    identities: { organizations: countJson(join(idDir, "organizations")), users: countJson(join(idDir, "users")) },
    siteNodes,
    clusterNodes: d.clusterNodes(siteNodes),
    switches: existsSync(join(d.configDir, "switch-configuration-actual.json")) ? parseSwitches(readJson(join(d.configDir, "switch-configuration-actual.json"))) : [],
    vpnPeers: vpn.ran && vpn.rc === 0 ? parseWgvpnPeers(vpn.stdout + vpn.stderr) : null,
    wifi: { zones: readWifiZones(join(d.configDir, "zones.json")), aps: aps.ran && aps.rc === 0 ? parseApList(aps.stdout) : null },
    physical: readPhysical(d.configDir),
    stacks: await d.stacks().catch(() => []),
    firstNode: firstNodeOf(d.configDir, siteNodes),
    repositories: Array.isArray(site.repositories) ? (site.repositories as { name?: unknown }[]).map((r) => (typeof r.name === "string" ? r.name : "")).filter(Boolean) : [],
    answers: readSetupAnswers(d.stateDir),
  };
}

// The first node: the first of the cluster's nodes, with its record's pools.
function firstNodeOf(configDir: string, siteNodes: string[]): { name: string; pools: string[]; lanPorts: string[] } | null {
  const name = siteNodes[0];
  if (!name) return null;
  const rec = readJson(join(configDir, `${name}.json`));
  const pools = Array.isArray(rec?.storagePools) ? (rec!.storagePools as unknown[]).filter((p): p is string => typeof p === "string") : [];
  const lan = (rec?.uplinks as { lan?: { ports?: unknown } } | undefined)?.lan?.ports;
  const lanPorts = Array.isArray(lan) ? lan.filter((p): p is string => typeof p === "string") : [];
  return { name, pools, lanPorts };
}

export function readSetupAnswers(stateDir: string): SetupAnswers {
  const doc = readJson(join(stateDir, ANSWERS_FILE)) ?? {};
  const out: SetupAnswers = {};
  for (const k of Object.keys(ANSWERS) as AnswerStep[]) {
    const v = doc[k];
    if (typeof v === "string" && choices(k).includes(v)) out[k] = v;
  }
  return out;
}

// Record (or, with null, withdraw) a step's answer. Returns an error for the
// caller, or null.
export function recordSetupAnswer(stateDir: string, step: string, answer: string | null): string | null {
  if (!(step in ANSWERS)) return `${step}: not a step that takes an answer (${Object.keys(ANSWERS).join(", ")})`;
  const want = choices(step as AnswerStep);
  if (answer !== null && !want.includes(answer)) return `${step}: the answer is ${want.map((w) => `'${w}'`).join(" or ")}`;
  const doc = readSetupAnswers(stateDir);
  if (answer === null) delete doc[step as AnswerStep];
  else doc[step as AnswerStep] = answer;
  mkdirSync(stateDir, { recursive: true });
  writeJsonAtomic(join(stateDir, ANSWERS_FILE), doc);
  return null;
}

// The setup token closes itself (D10, T6): the first installer through the
// gate has proven the route, a user and a way in, so the token goes. Not on
// identity's install: until then the token is the only way in.
export function closeSetupToken(access: AccessConfig, log: (l: string) => void = () => undefined): boolean {
  if (!setupState(access).tokenPresent) return false;
  try {
    unlinkSync(access.tokenFile);
    log(`the gate is proven: deleted the setup token ${access.tokenFile}`);
    return true;
  } catch (e) {
    log(`could not delete the setup token ${access.tokenFile}: ${(e as Error).message}`);
    return false;
  }
}
