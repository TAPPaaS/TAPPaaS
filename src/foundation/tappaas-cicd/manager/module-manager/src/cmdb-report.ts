// cmdb-report.ts — what module-manager reports to the CMDB (ADR-040 D3, D4): every
// installed module instance as the CI of its kind — a vm, lxc, machine or
// device node, or an app on the node an application names — its services
// (one per services/<service>/ of its source, `provides`), the controllers and
// managers it brings (config/control-plane.json), and `depends-on` from its
// dependsOn.
//
// An archived instance is not reported: it is no CI any more; the delete that
// archived it reported its end (D7): delete-module.sh, through `report --end`.

import { existsSync, readdirSync, statSync } from "fs";
import { join } from "path";
import { CmdbObject, CmdbRelation, CmdbReport } from "../../../lib/ts/src/cmdb";
import { compact, moduleCiAttributes, moduleNodeAttributes, nodeClassOf, releaseOf } from "../../../lib/ts/src/cmdb-source";
import { readJsonObject } from "../../../lib/ts/src/config-io";
import { guestConfAttributes, parseGuestConf } from "../../../lib/ts/src/guest-conf";
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
      // Where it runs is what the cluster says: without a live read (a
      // change report) the config's node may be where it is not (a guest on
      // its HANode), so it is left out.
      const g = m.vmid != null ? byVmid.get(m.vmid) : undefined;
      const on = g?.node ?? (live ? m.node ?? undefined : undefined);
      if (on) a.onNode = { class: "machine", name: on };
      if (live) {
        a.stage = g ? "operational" : "created";
        a.state = g ? (g.template ? "template" : g.status) : "stopped";
      }
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
      attributes: compact({
        ...moduleCiAttributes(m.name, m.raw),
        version: versionOf(m),
        onNode: onRef,
        stack: m.raw.stack,
        zone: m.raw.zone0,
        maturity: m.raw.status,
        environment: m.raw.environment,
        moduleNode: m.node,
      }),
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
      b.objects.push({ ref, class: "service", name, attributes: compact({ provider: m.name, version: versionOf(m), onNode: onRef }) });
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

  const complete: NonNullable<CmdbReport["complete"]> = [];
  // depends-on: the node, or the application, that needs the service. Never an
  // application's host: the host would then depend on services that run on it.
  for (const m of mods) {
    const host = b.hostRef.get(m.name);
    if (!host) continue;
    const from = m.kind === "application" ? { ref: nodeRef(m.name) } : typeof host === "string" ? { ref: host } : host;
    // Complete: a dependency dropped from the record ends here, and so does one
    // an earlier release put on the application's host.
    complete.push({ type: "depends-on", from });
    if (m.kind === "application") complete.push({ type: "depends-on", from: typeof host === "string" ? { ref: host } : host });
    for (const dep of m.dependsOn ?? []) {
      const list = b.services.get(dep);
      if (!list) continue;
      // A module that provides the service itself does not depend on it: that
      // would be a dependency cycle of one.
      if (list.some((x) => x.provider === m.name)) continue;
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
  return { source: SOURCE, kind: "observation", objects: b.objects, relations: b.relations, complete: dedupe(complete) };
}

const dedupe = <T>(xs: T[]): T[] => [...new Map(xs.map((x) => [JSON.stringify(x), x])).values()];

/** The end of an instance. A node's: its software ends with it (the store). An
 *  application's: the app and its services, which run on a node that stays, by
 *  their key, the name on that node. */
export function moduleEndObjects(configDir: string, was: ModuleConfig): { objects: CmdbObject[]; relations: CmdbRelation[] } {
  const cls = nodeClassOf(was.kind);
  if (cls) return { objects: [{ class: cls, name: was.name, attributes: compact({ vmid: cls === "vm" || cls === "lxc" ? was.vmid ?? undefined : undefined }), end: true }], relations: [] };
  // A guest whose config names no kind (a legacy or test fixture): the live
  // cluster reported it as a vm or an lxc by its vmid, so end both; the end of
  // the class it is not is nothing (the controller matches by key, D5/D7).
  if (was.kind == null && typeof was.vmid === "number") {
    return { objects: ["vm", "lxc"].map((c) => ({ class: c, name: was.name, attributes: { vmid: was.vmid }, end: true })), relations: [] };
  }
  if (was.kind !== "application") return { objects: [], relations: [] };
  const host = listModules(configDir).filter((m) => m.status !== "archived" && m.name === was.node);
  const b = build(configDir, [was, ...host], []);
  const ended = (o: CmdbObject): boolean => (o.class === "app" && o.name === was.name) || (o.class === "service" && o.attributes?.provider === was.name);
  const objects = b.objects.map((o) => (ended(o) ? { ...o, attributes: { onNode: o.attributes?.onNode }, end: true } : o));
  return { objects, relations: [] };
}

/** The CIs of one instance — its node or app, its services and provides — as
 *  a verb leaves it; an archived or removed one ends. `confs` (by vmid) are
 *  the guest configs as the verb applied them: a vm's or lxc's cores, memory,
 *  disks and nics are reported from them, in the shape site-manager observes,
 *  so the sweep credits the verb with what it changed on the guest. */
export function moduleChangeObjects(
  configDir: string,
  name: string,
  before: ModuleConfig | null,
  confs: Map<number, string> = new Map(),
): { objects: CmdbObject[]; relations: CmdbRelation[] } {
  const now = listModules(configDir).find((m) => m.name === name) ?? null;
  if (!now || now.status === "archived") {
    const was = now ?? before;
    return was ? moduleEndObjects(configDir, was) : { objects: [], relations: [] };
  }
  // The instance and the node it names, so an app's host is in the batch.
  const mods = listModules(configDir).filter((m) => m.status !== "archived" && (m.name === name || m.name === now.node));
  const b = build(configDir, mods, []);
  if (now.vmid != null && confs.has(now.vmid)) {
    const o = b.objects.find((x) => x.name === name && (x.class === "vm" || x.class === "lxc"));
    if (o) o.attributes = { ...o.attributes, ...guestConfAttributes(o.class as "vm" | "lxc", parseGuestConf(confs.get(now.vmid)!)) };
  }
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
