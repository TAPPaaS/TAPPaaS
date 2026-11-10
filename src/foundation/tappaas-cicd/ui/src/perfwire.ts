// perfwire.ts — perf.ts's inputs from the console's own parts (main.ts): the
// health document, the CMDB, the module and environment reads, the verb
// manifests, and the store — the logging VM's Prometheus, or in fixture mode
// the synthetic one over <fixtures>/perf/metrics.json.

import { existsSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { Cached } from "./cache";
import { Cmdb, CmdbHistory } from "./cmdb";
import { FixtureMode } from "./fixtures";
import { HealthLive } from "./healthlive";
import { grafanaDashboard, grafanaTraces } from "./jumps";
import { Manifests } from "./manifest";
import { PerfDeps, PromClient, metricsConfig, promClient } from "./perf";
import { fixturePromClient, loadFixtureMetrics } from "./perffixture";
import { Reads } from "./reads";
import { Runner } from "./run";

export interface PerfWire {
  fx: FixtureMode | null;
  configDir: string;
  stateDir: string;
  home: string;
  run: Runner;
  cmdb: Cmdb;
  reads: Reads;
  healthLive: HealthLive;
  manifests: () => Manifests | null;
  mgmtDomain: string;
}

// "2048" (MB), "32G", "512M" → MB.
export function sizeMB(v: unknown): number | null {
  if (typeof v === "number") return v;
  if (typeof v !== "string") return null;
  const m = /^(\d+(?:\.\d+)?)\s*([GMT]?)B?$/i.exec(v.trim());
  if (!m) return null;
  const n = Number(m[1]);
  return m[2].toUpperCase() === "T" ? n * 1024 * 1024 : m[2].toUpperCase() === "G" ? n * 1024 : n;
}

export function hasVerb(ms: Manifests | null, bin: string, words: string[]): boolean {
  const m = ms?.byBin.get(bin);
  return !!m?.verbs.some((v) => v.keys.some((k) => k.join(" ") === words.join(" ")));
}

function store(w: PerfWire): PromClient | null {
  if (w.fx) {
    const file = join(w.fx.dir, "perf", "metrics.json");
    if (!existsSync(file)) return null;
    const pw = join(w.stateDir, "metrics-admin-password");
    writeFileSync(pw, "fixture\n", { mode: 0o600 });
    return fixturePromClient(loadFixtureMetrics(file), () => Date.now(), pw);
  }
  const cfg = metricsConfig(w.configDir, w.home);
  return cfg ? promClient(cfg) : null;
}

export function perfDeps(w: PerfWire): PerfDeps {
  const r = w.reads;
  // The routes' descriptions say which module each publishes (network:proxy writes them).
  const routes = new Cached("perf-routes", 10 * 60_000, async () => {
    const rows = await w.cmdb.query({ class: "proxy-route" });
    return new Map(rows.map((o) => [o.id, typeof o.attributes.description === "string" ? o.attributes.description : ""]));
  });
  const repo = process.env.CONSOLE_REPO ?? "/home/tappaas/TAPPaaS";
  const envFields = join(repo, "src", "foundation", "schemas", "environment-fields.json");
  return {
    configDir: w.configDir,
    run: w.run,
    graph: async () => (await w.healthLive.read()).value,
    history: (id) => w.cmdb.history(id) as Promise<CmdbHistory>,
    descriptions: async () => (await routes.get()).value ?? new Map(),
    modules: async () => (await r.modules.get()).value?.modules ?? [],
    environments: async () => ((await r.environments.get()).value ?? []).map((e) => e.name),
    logging: async () => {
      const mods = (await r.modules.get()).value?.modules ?? [];
      if (!mods.some((m) => m.name === "logging")) return { memoryMB: null, diskGB: null, installed: false };
      const f = ((await r.moduleResolve.of("logging").get()).value as { fields?: Record<string, { value?: unknown }> } | null)?.fields ?? {};
      const disk = sizeMB(f.diskSize?.value);
      return { memoryMB: sizeMB(f.memory?.value), diskGB: disk === null ? null : disk / 1024, installed: true };
    },
    hasVerb: (words) => hasVerb(w.manifests(), "health-manager", words),
    // environment-manager takes `--set performance.level` once its field schema has it (P2).
    envLevelSettable: () => {
      try {
        return /"performance"/.test(readFileSync(envFields, "utf8"));
      } catch {
        return false;
      }
    },
    prom: store(w),
    grafana: (cls, labels) =>
      grafanaDashboard({ topology: null, modules: r.modules.peek().value?.modules ?? [], environments: r.environments.peek().value ?? [], mgmtDomain: w.mgmtDomain, pbsStore: "" }, cls, labels),
    traces: (id) =>
      grafanaTraces({ topology: null, modules: r.modules.peek().value?.modules ?? [], environments: r.environments.peek().value ?? [], mgmtDomain: w.mgmtDomain, pbsStore: "" }, id),
    now: () => Date.now(),
  };
}
