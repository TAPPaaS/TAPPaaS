// setup.ts — the Setup wizard's checklist (ADR-034 D10, spike §5.12). Its
// state is derived from the records every time, never stored, so the wizard
// resumes for free: setupSteps() is a pure function of what the records say;
// gatherSetup() reads them (config files, the managers, lib/ts cluster.ts for
// membership). Each step is then a form over its verbs in the front end, run
// as jobs with their previews.
//
//   tls        wildcard mode: config/cert-refids.json names the default
//              environment (acme-setup.sh recorded the certificate);
//              per-service mode: nothing to issue — Caddy gets each route's
//              certificate itself (HTTP-01)
//   backup, identity, logging   config/<module>.json exists and its module
//              test passed the last time it ran. The tests run only on an
//              explicit refresh (GET /setup?refresh=1, the page's Check
//              button) or as a job (the step's Test button): three tests per
//              read was the cost of every Setup view. Their last result is
//              kept in the state directory (setup-tests.json) and read back
//              like any record.
//   bootstrap  config/identities holds an organization and a user
//   nodes      every node site.json declares is a cluster member
//   switch     a switch is registered and interrogated (ports discovered)
//   vpn        the admin VPN has at least one peer (network-manager wgvpn list)
//   wifi       optional: every active Client zone (zones.json) has an SSID an
//              access point maps to it (ap-controller list --json); a name
//              zones.json declares that no AP broadcasts is not WiFi yet
//   stacks     optional: which stacks have modules installed

import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, unlinkSync } from "fs";
import { join } from "path";
import { writeJsonAtomic } from "../../lib/ts/src/config-io";
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

export interface SetupInputs {
  defaultEnv: string | null;
  dnsMode: "wildcard" | "per-service" | null;
  certRefids: Record<string, unknown> | null;
  modules: Record<"backup" | "identity" | "logging", { config: boolean; test: TestResult | null }>;
  identities: { organizations: number; users: number };
  siteNodes: string[];
  clusterNodes: string[] | null; // null: membership could not be read
  switches: { name: string; ports: number; discovered: number; controller: string | null }[] | null;
  vpnPeers: string[] | null; // null: wgvpn list could not be read
  wifi: WifiInputs;
  stacks: string[];
}

export interface WifiInputs {
  zones: { name: string; type: string | null; state: string | null; vlan: number | null; ssid: string | null }[]; // zones.json
  aps: { name: string; ssids: { name: string; zone: string | null }[] }[] | null; // null: ap-controller list could not be read
}

export type StepId = "tls" | "backup" | "identity" | "logging" | "bootstrap" | "nodes" | "switch" | "vpn" | "wifi" | "stacks";

export interface SetupStep {
  id: StepId;
  title: string;
  required: boolean;
  done: boolean | null; // null: not known (a read failed)
  detail: string;
}

const MODULE_TITLES = { backup: "Backup (PBS)", identity: "Identity (Authentik)", logging: "Logging (Loki, Grafana)" };

export function setupSteps(i: SetupInputs): SetupStep[] {
  const steps: SetupStep[] = [];

  if (i.dnsMode === "wildcard") {
    const has = !!i.defaultEnv && !!i.certRefids && typeof i.certRefids[i.defaultEnv] === "string";
    steps.push({ id: "tls", title: "TLS — the wildcard certificate", required: true, done: has, detail: has ? `config/cert-refids.json: ${i.defaultEnv} → ${String(i.certRefids![i.defaultEnv!])}` : `no certificate recorded for ${i.defaultEnv ?? "the default environment"} in config/cert-refids.json` });
  } else {
    steps.push({ id: "tls", title: "TLS — certificates", required: true, done: i.defaultEnv !== null, detail: i.defaultEnv ? `${i.defaultEnv} is dnsMode per-service: Caddy gets each route's certificate itself (HTTP-01); there is no wildcard to issue` : "no default environment yet (site.json)" });
  }

  for (const m of SETUP_MODULES) {
    const s = i.modules[m];
    const done = !s.config ? false : s.test === null ? null : s.test.rc === 0;
    const when = s.test ? ` (${s.test.at.replace("T", " ").replace(/\.\d+Z$/, "Z")})` : "";
    const detail = !s.config ? `config/${m}.json does not exist: not installed` : s.test === null ? `installed (config/${m}.json); its test has not run yet: Check runs it, and so does the next sweep` : s.test.rc === 0 ? (s.test.sweep ? `installed; updated and tested by the sweep${when}` : `installed; module-manager test ${m} passed${when}`) : `installed; module-manager test ${m} failed${when} (exit ${s.test.rc}): ${s.test.tail}`;
    steps.push({ id: m, title: MODULE_TITLES[m], required: true, done, detail });
  }

  const boot = i.identities.organizations > 0 && i.identities.users > 0;
  steps.push({ id: "bootstrap", title: "Identity bootstrap — your organization and you", required: true, done: boot, detail: boot ? `config/identities: ${i.identities.organizations} organization(s), ${i.identities.users} user(s)` : "config/identities has no organization or no user yet" });

  if (i.clusterNodes === null) {
    steps.push({ id: "nodes", title: "Nodes", required: true, done: null, detail: "the cluster's membership could not be read" });
  } else {
    const missing = i.siteNodes.filter((n) => !i.clusterNodes!.includes(n));
    steps.push({ id: "nodes", title: "Nodes", required: true, done: i.siteNodes.length > 0 && missing.length === 0, detail: missing.length ? `not joined: ${missing.join(", ")}` : `${i.siteNodes.length} node(s), all cluster members: ${i.siteNodes.join(", ")}` });
  }

  if (i.switches === null) {
    steps.push({ id: "switch", title: "The switch", required: true, done: null, detail: "switch-configuration-actual.json could not be read" });
  } else {
    const ok = i.switches.filter((s) => s.discovered > 0);
    steps.push({ id: "switch", title: "The switch", required: true, done: ok.length > 0, detail: i.switches.length === 0 ? "no switch registered" : ok.length ? i.switches.map((s) => `${s.name}: ${s.ports} port(s), ${s.discovered} discovered${s.controller ? ` via ${s.controller}` : ""}`).join("; ") : `registered (${i.switches.map((s) => s.name).join(", ")}) but not interrogated: no port discovered` });
  }

  if (i.vpnPeers === null) steps.push({ id: "vpn", title: "The admin VPN", required: true, done: null, detail: "network-manager wgvpn list could not be read" });
  else steps.push({ id: "vpn", title: "The admin VPN", required: true, done: i.vpnPeers.length > 0, detail: i.vpnPeers.length ? `peer(s): ${i.vpnPeers.join(", ")}` : "no peer yet: enrol a device" });

  steps.push(wifiStep(i.wifi));

  steps.push({ id: "stacks", title: "Stacks (optional)", required: false, done: i.stacks.length > 0, detail: i.stacks.length ? `installed: ${i.stacks.join(", ")}` : "none yet" });
  return steps;
}

// The zones that should have WiFi: active (no state is Active) and of type Client.
export function clientZonesWithoutWifi(w: WifiInputs): { name: string; declared: string | null }[] {
  const served = new Set((w.aps ?? []).flatMap((a) => a.ssids.map((s) => s.zone)).filter((z): z is string => !!z));
  return w.zones
    .filter((z) => z.type === "Client" && (z.state ?? "Active") === "Active" && !served.has(z.name))
    .map((z) => ({ name: z.name, declared: z.ssid && !/^<.*>$/.test(z.ssid) ? z.ssid : null }));
}

export function wifiStep(w: WifiInputs): SetupStep {
  const title = "WiFi (optional)";
  const clients = w.zones.filter((z) => z.type === "Client" && (z.state ?? "Active") === "Active").map((z) => z.name);
  if (clients.length === 0) return { id: "wifi", title, required: false, done: true, detail: "no active Client zone: nothing to broadcast" };
  if (w.aps === null) return { id: "wifi", title, required: false, done: null, detail: "ap-controller list could not be read" };
  const missing = clientZonesWithoutWifi(w);
  if (missing.length === 0) {
    const names = w.aps.flatMap((a) => a.ssids.filter((s) => s.zone && clients.includes(s.zone)).map((s) => `${s.name} → ${s.zone}`));
    return { id: "wifi", title, required: false, done: true, detail: `every active Client zone has an SSID: ${names.join(", ")}` };
  }
  const named = missing.map((z) => (z.declared ? `${z.name} (zones.json names ${z.declared}; no access point broadcasts it)` : z.name)).join(", ");
  return { id: "wifi", title, required: false, done: false, detail: w.aps.length === 0 ? `no access point registered yet (ap-controller add); no SSID for: ${named}` : `no SSID for: ${named}` };
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

// `ap-controller list --json`: each AP and the SSIDs it maps to a zone; null
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
  const sw = (doc as { switches?: Record<string, { controller?: string; ports?: Record<string, { source?: string }> }> })?.switches;
  if (!sw || typeof sw !== "object") return [];
  return Object.entries(sw).map(([name, s]) => {
    const ports = Object.values(s.ports ?? {});
    return { name, ports: ports.length, discovered: ports.filter((p) => p.source === "discovered").length, controller: s.controller ?? null };
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

// The last result of each foundation module's test, as the explicit refresh
// left them; a module never tested (or a file never written) has none.
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

// The explicit refresh: run `module-manager test <m>` for every installed
// foundation module (fast mode; the deep suite is a job) and keep the results
// where readSetupTests finds them. A module not installed keeps no result.
export async function runSetupTests(d: Pick<GatherDeps, "configDir" | "stateDir" | "run">, now: () => number = Date.now): Promise<void> {
  const results = readSetupTests(d.stateDir);
  await Promise.all(
    SETUP_MODULES.map(async (m) => {
      if (!existsSync(join(d.configDir, `${m}.json`))) {
        delete results[m];
        return;
      }
      const r = await d.run("module-manager", ["test", m], 15 * 60_000);
      if (!r.ran) return; // the manager could not run: keep what the last run said
      const tail = (r.stdout + r.stderr).replace(/\x1b\[[0-9;]*m/g, "").trim().split("\n").slice(-1)[0] ?? "";
      results[m] = { rc: r.rc, tail, at: new Date(now()).toISOString() };
    }),
  );
  mkdirSync(d.stateDir, { recursive: true });
  writeJsonAtomic(join(d.stateDir, TESTS_FILE), results);
}

// A finished job that ran a foundation module's test (the step's Test button,
// or the verb typed in a form) is as good a result as the Check's: it is kept
// where readSetupTests finds it. A job that could not run, or was cut off,
// says nothing. Returns the module it recorded, or null.
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
  const dnsMode = ((envDoc?.domains as { dnsMode?: string } | undefined)?.dnsMode === "wildcard" ? "wildcard" : envDoc ? "per-service" : null) as SetupInputs["dnsMode"];
  const siteNodes = (((site.hardware as { nodes?: { name?: string }[] } | undefined)?.nodes ?? []).map((n) => n.name).filter((n): n is string => typeof n === "string"));
  // The module tests are not run here (every Setup read gathers): their last
  // result is a record in the state directory, written by runSetupTests.
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
  const [vpn, aps] = await Promise.all([d.run("network-manager", ["wgvpn", "list"], 60_000), d.run("ap-controller", ["list", "--json"], 60_000)]);
  return {
    defaultEnv,
    dnsMode,
    certRefids: readJson(join(d.configDir, "cert-refids.json")),
    modules,
    identities: { organizations: countJson(join(idDir, "organizations")), users: countJson(join(idDir, "users")) },
    siteNodes,
    clusterNodes: d.clusterNodes(siteNodes),
    switches: existsSync(join(d.configDir, "switch-configuration-actual.json")) ? parseSwitches(readJson(join(d.configDir, "switch-configuration-actual.json"))) : [],
    vpnPeers: vpn.ran && vpn.rc === 0 ? parseWgvpnPeers(vpn.stdout + vpn.stderr) : null,
    wifi: { zones: readWifiZones(join(d.configDir, "zones.json")), aps: aps.ran && aps.rc === 0 ? parseApList(aps.stdout) : null },
    stacks: await d.stacks().catch(() => []),
  };
}

// The setup token closes itself (D10, T6): once identity is installed the
// token is refused, and its file is deleted here — after the identity step,
// and at any later look.
export function closeSetupToken(access: AccessConfig, log: (l: string) => void = () => undefined): boolean {
  const s = setupState(access);
  if (!(s.identityInstalled && s.tokenPresent)) return false;
  try {
    unlinkSync(access.tokenFile);
    log(`identity is installed: deleted the setup token ${access.tokenFile}`);
    return true;
  } catch (e) {
    log(`could not delete the setup token ${access.tokenFile}: ${(e as Error).message}`);
    return false;
  }
}
