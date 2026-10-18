// reads.ts — every read the console serves, each one a manager verb's --json
// (ADR-034 D1, D4 "P1 is read-only"). One cache per read with its own timer:
// health 10 minutes, the module list and the topology 5, drift on demand. The
// only files read directly are the sweep's own record (last-update-result.json
// and the failures ledger), its journal, which no manager prints, and
// zones.json through lib/ts zones.ts — the same parse network-manager's own
// `list` and `show` run, read once instead of one process per zone.

import { existsSync, mkdirSync, readFileSync } from "fs";
import { join } from "path";
import { writeJsonAtomic } from "../../lib/ts/src/config-io";
import { readZonesFile } from "../../lib/ts/src/zones";
import { parseJournal, parseLedger, sweepRuns, SweepRun } from "./activity";
import { Cached, CachedMap } from "./cache";
import { Runner, runJson } from "./run";
import { SetupInputs, gatherSetup } from "./setup";
import { BackupRow, EnvironmentRow, HealthDoc, ModuleList, TopologyDoc } from "./model";

const MIN = 60_000;

export const TTL = {
  health: 10 * MIN,
  modules: 5 * MIN,
  topology: 5 * MIN,
  zones: 5 * MIN,
  environments: 5 * MIN,
  site: 5 * MIN,
  backup: 10 * MIN,
  security: 10 * MIN,
  peers: 10 * MIN,
  activity: 5 * MIN,
  moduleDetail: 5 * MIN,
  identity: 5 * MIN,
  setup: 10 * MIN,
  drift: 0, // on demand
};

export interface ReadsConfig {
  // Cluster membership for the Setup checklist (lib/ts cluster.ts by default).
  clusterNodes?: (siteNodes: string[]) => string[] | null;
  configDir: string;
  stateDir: string; // where the health document is handed to `topology --health`
  run: Runner;
  journalDays: number;
  now?: () => number;
}

export interface Activity {
  runs: SweepRun[];
  ledger: { at: string | null; text: string }[];
  lastResult: Record<string, unknown> | null;
  sweepActive: boolean;
}

// A module name as the managers spell one; anything else never reaches an argv.
export const MODULE_NAME = /^[a-z0-9][a-z0-9-]{0,62}$/;

export const IDENTITY_KINDS = ["org", "group", "user", "role"];

export class Reads {
  readonly health: Cached<HealthDoc>;
  readonly modules: Cached<ModuleList>;
  readonly backup: Cached<BackupRow[]>;
  readonly topology: Cached<TopologyDoc & Record<string, unknown>>;
  readonly zones: Cached<Record<string, unknown>[]>;
  readonly environments: Cached<EnvironmentRow[]>;
  readonly site: Cached<Record<string, unknown>>;
  readonly security: Cached<Record<string, unknown> | null>;
  readonly peers: Cached<Record<string, unknown>[]>;
  readonly activity: Cached<Activity>;
  readonly moduleShow: CachedMap<Record<string, unknown>>;
  readonly moduleResolve: CachedMap<Record<string, unknown>>;
  readonly moduleBackup: CachedMap<Record<string, unknown>>;
  readonly moduleDrift: CachedMap<Record<string, unknown>>;
  readonly moduleFields: CachedMap<Record<string, unknown>>;
  readonly identity: Cached<Record<string, string[]>>;
  readonly setup: Cached<SetupInputs>;

  constructor(private readonly cfg: ReadsConfig) {
    const run = cfg.run;
    const now = cfg.now ?? Date.now;
    const j = <T>(bin: string, args: string[], okRcs: number[] = [0], timeoutMs = 2 * MIN): Promise<T> =>
      runJson<T>(run, bin, args, { okRcs, timeoutMs });

    // validate exits 1 when a gate fails; the document is complete either way.
    this.health = new Cached("health", TTL.health, () => j<HealthDoc>("health-manager", ["validate", "--json"], [0, 1], 10 * MIN), now);
    this.modules = new Cached("modules", TTL.modules, () => j<ModuleList>("module-manager", ["list", "--json"]), now);
    this.backup = new Cached("backup", TTL.backup, () => j<BackupRow[]>("backup-manager", ["list", "--json"]), now);
    this.topology = new Cached("topology", TTL.topology, () => this.loadTopology(), now);
    this.zones = new Cached("zones", TTL.zones, () => this.loadZones(), now);
    this.environments = new Cached("environments", TTL.environments, () => j<EnvironmentRow[]>("environment-manager", ["list", "--json"]), now);
    this.site = new Cached("site", TTL.site, () => this.loadSite(), now);
    // No scan yet is an answer (null), not a failure.
    this.security = new Cached("security", TTL.security, async () => {
      const r = await run("health-manager", ["report", "security", "--json"]);
      if (r.ran && r.rc !== 0 && /no security scan yet/.test(r.stderr + r.stdout)) return null;
      return runJson<Record<string, unknown>>(async () => r, "health-manager", ["report", "security", "--json"]);
    }, now);
    this.peers = new Cached("peers", TTL.peers, () => j<Record<string, unknown>[]>("backup-manager", ["peers", "--json"]), now);
    this.activity = new Cached("activity", TTL.activity, () => this.loadActivity(), now);
    this.moduleShow = new CachedMap("show", TTL.moduleDetail, (m) => j<Record<string, unknown>>("module-manager", ["show", m, "--json"]), now);
    this.moduleResolve = new CachedMap("resolve", TTL.moduleDetail, (m) => j<Record<string, unknown>>("module-manager", ["resolve", m, "--json"]), now);
    this.moduleBackup = new CachedMap("backup", TTL.backup, async (m) => {
      const [policy, coverage] = await Promise.all([
        j<Record<string, unknown>>("backup-manager", ["show", m, "--json"]),
        j<Record<string, unknown>>("backup-manager", ["coverage", m, "--json"]).catch((e: Error) => ({ error: e.message })),
      ]);
      return { policy, coverage };
    }, now);
    // What `modify --set` may change, with each field's ADR-020 change class.
    this.moduleFields = new CachedMap("fields", TTL.moduleDetail, (m) => j<Record<string, unknown>>("module-manager", ["fields", m, "--json"]), now);
    this.identity = new Cached("identity", TTL.identity, async () => {
      const out: Record<string, string[]> = {};
      await Promise.all(IDENTITY_KINDS.map(async (k) => (out[k] = await j<string[]>("identity-manager", [k, "list", "--json"]))));
      return out;
    }, now);
    // The Setup checklist's records: read on demand (it runs three module tests).
    this.setup = new Cached("setup", TTL.setup, () =>
      gatherSetup({
        configDir: cfg.configDir,
        run,
        clusterNodes: cfg.clusterNodes ?? (() => null),
        stacks: async () => {
          const m = await this.modules.get();
          return [...new Set((m.value?.modules ?? []).map((x) => x.stack).filter((x): x is string => !!x && x !== "foundation"))].sort();
        },
      }), now);
    this.moduleDrift = new CachedMap("drift", TTL.drift, (m) => j<Record<string, unknown>>("module-manager", ["drift", m, "--json"], [0, 1, 2], 5 * MIN), now);
  }

  get configDir(): string {
    return this.cfg.configDir;
  }

  // The reads with timers, refreshed in the background from the start.
  timed(): Cached<unknown>[] {
    return [this.health, this.modules, this.backup, this.topology, this.zones, this.environments, this.site, this.security, this.peers, this.activity] as Cached<unknown>[];
  }

  start(): void {
    for (const c of this.timed()) {
      void c.refresh();
      c.start();
    }
  }

  stop(): void {
    for (const c of this.timed()) c.stop();
  }

  // Refresh one read, or every read, now (the explicit refresh endpoint).
  async refresh(what: string): Promise<string[]> {
    const all: Record<string, Cached<unknown>> = {
      health: this.health, modules: this.modules, backup: this.backup, topology: this.topology,
      zones: this.zones, environments: this.environments, site: this.site, security: this.security,
      peers: this.peers, activity: this.activity,
    } as Record<string, Cached<unknown>>;
    if (what === "all") {
      this.moduleShow.clear();
      this.moduleResolve.clear();
      this.moduleBackup.clear();
      this.moduleDrift.clear();
      this.moduleFields.clear();
      // health first: the topology places its findings
      await this.health.refresh();
      await Promise.all(Object.entries(all).filter(([k]) => k !== "health").map(([, c]) => c.refresh()));
      return Object.keys(all);
    }
    const c = all[what];
    if (!c) throw new Error(`unknown read '${what}' (one of: all, ${Object.keys(all).join(", ")})`);
    await c.refresh();
    if (what === "health") void this.topology.refresh();
    return [what];
  }

  // After a job changed the site: what it may have changed is read again now
  // (health keeps its own ten-minute timer; validate takes half a minute).
  refreshAfterJob(): Promise<void> {
    this.moduleShow.clear();
    this.moduleResolve.clear();
    this.moduleBackup.clear();
    this.moduleDrift.clear();
    this.moduleFields.clear();
    // The Setup checklist runs module tests: only re-read if someone has looked.
    const setup = this.setup.peek().at !== null ? [this.setup] : [];
    return Promise.all([...setup, this.identity, this.modules, this.topology, this.zones, this.environments, this.site, this.backup, this.peers, this.activity].map((c) => (c as Cached<unknown>).refresh())).then(() => undefined);
  }

  private async loadTopology(): Promise<TopologyDoc & Record<string, unknown>> {
    // The topology places the health findings: hand it the document this cache
    // already holds rather than have it run validate a second time.
    const h = await this.health.get();
    let args = ["topology", "--json", "--no-health"];
    if (h.value) {
      mkdirSync(this.cfg.stateDir, { recursive: true });
      const f = join(this.cfg.stateDir, "health.json");
      writeJsonAtomic(f, h.value);
      args = ["topology", "--json", "--health", f];
    }
    return runJson<TopologyDoc & Record<string, unknown>>(this.cfg.run, "network-manager", args, { timeoutMs: 3 * MIN });
  }

  // Each zone as `network-manager show <name> --json` prints it, plus its name:
  // zones.json read once (lib/ts zones.ts, the manager's own parse and rule).
  private async loadZones(): Promise<Record<string, unknown>[]> {
    const { entries } = readZonesFile(join(this.cfg.configDir, "zones.json"));
    return entries.map(([name, z]) => {
      const { name: _n, ...rest } = z;
      return { name, ...rest };
    });
  }

  private async loadSite(): Promise<Record<string, unknown>> {
    const run = this.cfg.run;
    const [site, nodes, repositories] = await Promise.all([
      runJson<Record<string, unknown>>(run, "site-manager", ["site", "show", "--json"]),
      runJson<unknown[]>(run, "site-manager", ["node", "list", "--json"]).catch(() => null),
      runJson<unknown[]>(run, "site-manager", ["repository", "list", "--json"]).catch(() => null),
    ]);
    return { site, nodes, repositories, lastSweep: this.readJson("last-update-result.json") };
  }

  private async loadActivity(): Promise<Activity> {
    const run = this.cfg.run;
    const [journal, active] = await Promise.all([
      run("journalctl", ["-u", "update-tappaas.service", "--since", `-${this.cfg.journalDays}d`, "-o", "short-iso", "--no-pager"], 60_000),
      run("systemctl", ["is-active", "update-tappaas.service"], 10_000),
    ]);
    if (!journal.ran || (journal.rc !== 0 && journal.stdout === "")) {
      throw new Error(`journalctl -u update-tappaas.service: ${journal.stderr.trim() || `exit ${journal.rc}`}`);
    }
    const ledgerFile = join(this.cfg.configDir, "update-tappaas.failures");
    return {
      runs: sweepRuns(parseJournal(journal.stdout)),
      ledger: existsSync(ledgerFile) ? parseLedger(readFileSync(ledgerFile, "utf8")) : [],
      lastResult: this.readJson("last-update-result.json"),
      sweepActive: active.ran && ["active", "activating"].includes(active.stdout.trim()),
    };
  }

  private readJson(file: string): Record<string, unknown> | null {
    const f = join(this.cfg.configDir, file);
    if (!existsSync(f)) return null;
    try {
      return JSON.parse(readFileSync(f, "utf8")) as Record<string, unknown>;
    } catch {
      return null;
    }
  }
}
