// cmdb-report.ts — what module-manager reports to the CMDB (ADR-040 D3, D4): every
// installed module instance as the CI of its kind — a vm, lxc, machine or
// device node, or an app on the node an application names — its services
// (one per services/<service>/ of its source, `provides`), the controllers and
// managers it brings (config/control-plane.json), and `depends-on` from its
// dependsOn.
//
// An archived instance is not reported: it is no CI any more; the delete that
// archived it reported its end (D7).

import { existsSync, readdirSync, statSync } from "fs";
import { join } from "path";
import { CmdbObject, CmdbRelation, CmdbReport } from "../../../lib/ts/src/cmdb";
import { compact, moduleCiAttributes, moduleNodeAttributes, nodeClassOf, releaseOf } from "../../../lib/ts/src/cmdb-source";
import { readJsonObject } from "../../../lib/ts/src/config-io";
import { clusterNodeNames } from "../../../lib/ts/src/nodes";
import { listModules } from "./config";
import { ModuleConfig, RunningGuest } from "./types";

type Obj = Record<string, unknown>;

export const SOURCE = "module-manager";

const nodeRef = (name: string): string => `node/${name}`;
const svcRef = (module: string, svc: string, provider: string): string => `service/${provider}/${module}:${svc}`;

/** The services a module's source declares: its services/<service>/ dirs. */
export function serviceNames(moduleSource: string | null | undefined): string[] {
  if (!moduleSource) return [];
  const dir = join(moduleSource, "services");
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((d) => {
      try {
        return statSync(join(dir, d)).isDirectory();
      } catch {
        return false;
      }
    })
    .sort();
}

interface Built {
  objects: CmdbObject[];
  relations: CmdbRelation[];
  // instance → the ref of the node it is, or runs on (an application's host)
  hostRef: Map<string, string | { class: string; name: string }>;
  // "<module>:<service>" → its object refs, by provider instance
  services: Map<string, { provider: string; ref: string }[]>;
}

/** The CIs of the given instances. `guests` (the live cluster, may be empty)
 *  gives a guest's actual node and whether it runs. */
function build(configDir: string, mods: ModuleConfig[], guests: RunningGuest[]): Built {
  const b: Built = { objects: [], relations: [], hostRef: new Map(), services: new Map() };
  const byVmid = new Map(guests.map((g) => [g.vmid, g]));
  const live = guests.length > 0;
  const installed = new Set(mods.map((m) => m.name));
  const primary = clusterNodeNames(configDir)[0];

  // 1. The nodes: one per instance of a node kind.
  for (const m of mods) {
    const cls = nodeClassOf(m.kind);
    if (!cls) continue;
    const a: Obj = moduleNodeAttributes(m.name, m.raw, cls);
    if (cls === "vm" || cls === "lxc") {
      const g = m.vmid != null ? byVmid.get(m.vmid) : undefined;
      const on = g?.node ?? m.node ?? undefined;
      if (on) a.onNode = { class: "machine", name: on };
      if (live) a.stage = g ? "operational" : "created";
    }
    b.objects.push({ ref: nodeRef(m.name), class: cls, name: m.name, attributes: compact(a) });
    b.hostRef.set(m.name, nodeRef(m.name));
  }

  // 2. Applications: an app on the node it names (ADR-022f D3); one that
  // names none (cluster) on the primary node.
  for (const m of mods) {
    if (m.kind !== "application") continue;
    const host = m.node || primary;
    if (!host) continue;
    const on = installed.has(host) && b.hostRef.has(host) ? (b.hostRef.get(host) as string) : { class: "machine", name: host };
    const onRef = typeof on === "string" ? { ref: on } : on;
    b.objects.push({
      ref: nodeRef(m.name),
      class: "app",
      name: m.name,
      attributes: compact({ ...moduleCiAttributes(m.name, m.raw), version: versionOf(m), onNode: onRef }),
    });
    b.hostRef.set(m.name, on);
  }

  // 3. Services: <module>:<service>, on the node of the instance providing it.
  for (const m of mods) {
    const host = b.hostRef.get(m.name);
    if (!host) continue;
    const onRef = typeof host === "string" ? { ref: host } : host;
    const module = releaseOf(m.raw)?.module ?? m.name;
    for (const svc of serviceNames(m.moduleSource)) {
      const name = `${module}:${svc}`;
      const ref = svcRef(module, svc, m.name);
      b.objects.push({ ref, class: "service", name, attributes: compact({ provider: m.name, version: versionOf(m), onNode: onRef, stack: m.stack ?? undefined }) });
      b.relations.push({ type: "provides", from: onRef, to: { ref } });
      b.services.set(name, [...(b.services.get(name) ?? []), { provider: m.name, ref }]);
    }
  }
  return b;
}

const versionOf = (m: ModuleConfig): string => (typeof m.raw.version === "string" && m.raw.version ? m.raw.version : "unknown");

/** The provider a dependency means: the instance named as the module, else
 *  the first (an environment's instance is <module>-<env>). */
function providerOf(list: { provider: string; ref: string }[], module: string): string {
  return (list.find((s) => s.provider === module) ?? list[0]).ref;
}

/** Every installed instance, its services, its dependencies, and the control
 *  plane's components, as one observation. */
export function moduleObservation(configDir: string, guests: RunningGuest[]): CmdbReport {
  const mods = listModules(configDir).filter((m) => m.status !== "archived");
  const b = build(configDir, mods, guests);

  // depends-on: a node (an application's host) on the service it needs.
  for (const m of mods) {
    const host = b.hostRef.get(m.name);
    if (!host) continue;
    const from = typeof host === "string" ? { ref: host } : host;
    for (const dep of m.dependsOn ?? []) {
      const list = b.services.get(dep);
      if (!list) continue;
      b.relations.push({ type: "depends-on", from, to: { ref: providerOf(list, dep.split(":")[0]) } });
    }
  }

  // The control plane's managers and controllers, on the instance they came with.
  const registry = readJsonObject(join(configDir, "control-plane.json"));
  const components = Array.isArray(registry?.components) ? (registry!.components as Obj[]) : [];
  for (const c of components) {
    if ((c.kind !== "manager" && c.kind !== "controller") || typeof c.name !== "string") continue;
    const owner = typeof c.module === "string" ? c.module : "tappaas-cicd";
    const host = b.hostRef.get(owner);
    const m = mods.find((x) => x.name === owner);
    if (!host || !m) continue;
    b.objects.push({
      class: c.kind,
      name: c.name,
      attributes: compact({
        version: versionOf(m),
        onNode: typeof host === "string" ? { ref: host } : host,
        registry: c,
        aliases: Array.isArray(c.aliases) && c.aliases.length ? c.aliases : undefined,
        stage: "operational",
      }),
    });
  }
  return { source: SOURCE, kind: "observation", objects: b.objects, relations: b.relations };
}

/** The CIs of one instance — its node or app, its services and provides — as
 *  a verb leaves it; an archived or removed one ends. */
export function moduleChangeObjects(configDir: string, name: string, before: ModuleConfig | null): { objects: CmdbObject[]; relations: CmdbRelation[] } {
  const now = listModules(configDir).find((m) => m.name === name) ?? null;
  if (!now || now.status === "archived") {
    const was = now ?? before;
    if (!was) return { objects: [], relations: [] };
    const cls = nodeClassOf(was.kind) ?? (was.kind === "application" ? "app" : null);
    if (!cls || cls === "app") return { objects: [], relations: [] }; // an app is keyed by its node: its end is its node's
    return { objects: [{ class: cls, name, attributes: compact({ vmid: cls === "vm" || cls === "lxc" ? was.vmid ?? undefined : undefined }), end: true }], relations: [] };
  }
  // The instance and the node it names, so an app's host is in the batch.
  const mods = listModules(configDir).filter((m) => m.status !== "archived" && (m.name === name || m.name === now.node));
  const b = build(configDir, mods, []);
  return { objects: b.objects, relations: b.relations };
}

/** config/<name>.json's modification time, per module: what a verb changed. */
export function moduleStamps(configDir: string): Map<string, { mtime: number; m: ModuleConfig }> {
  const out = new Map<string, { mtime: number; m: ModuleConfig }>();
  for (const m of listModules(configDir)) {
    try {
      out.set(m.name, { mtime: statSync(join(configDir, `${m.name}.json`)).mtimeMs, m });
    } catch {
      // gone between the listing and the stat
    }
  }
  return out;
}
