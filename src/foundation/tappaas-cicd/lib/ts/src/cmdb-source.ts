// cmdb-source.ts — what a manager needs to be a source of the CMDB (ADR-040
// D4): its `report` verb (send the observation, or print it with --json), the
// change a verb reports, the job it runs in, and the CI of a module instance
// (D3: a module instance IS the node of its kind, or an app on its node).
//
// The CMDB is a record, never a gate: a change report never fails its verb —
// an outage spools (cmdb.ts), a refusal is a warning. The spool is the
// manager's own config dir's, so a verb run against --config-dir keeps its
// reports there.
//
// A change carries the console's job and its actor (job.ts currentJob).

import { join } from "path";
import { CmdbObject, CmdbOptions, CmdbRefused, CmdbRelation, CmdbReport, cmdbReport } from "./cmdb";
import { defaultConfigDir } from "./config-io";
import { changeJob } from "./job";
import { moduleOfLocation, moduleSourceOf } from "./instance";

type Obj = Record<string, unknown>;

/** The client options for a manager working on <configDir>. */
export function cmdbOptions(configDir: string = defaultConfigDir()): CmdbOptions {
  return { spoolDir: join(configDir, ".cmdb-spool") };
}

/** An attribute map without the undefined and null values: null unsets an
 *  attribute in a report, which a reader that merely lacks a value must not. */
export function compact(o: Obj): Obj {
  const out: Obj = {};
  for (const [k, v] of Object.entries(o)) if (v !== undefined && v !== null) out[k] = v;
  return out;
}

/** `<manager> report [--json]`: print the observation, or send it. 0 sent or
 *  spooled, 1 refused (a reporter's bug: the payload does not fit). */
export function sendObservation(report: CmdbReport, json: boolean, configDir?: string, print: (s: string) => void = (s) => console.log(s)): number {
  const full: CmdbReport = withStubs({ kind: "observation", ...report });
  if (json) {
    print(JSON.stringify(full, null, 2));
    return 0;
  }
  const counts = `${full.objects?.length ?? 0} object(s), ${full.relations?.length ?? 0} relation(s)`;
  try {
    const r = cmdbReport(full, cmdbOptions(configDir));
    print(r.delivered ? `reported ${counts} to the CMDB` : `[Warning] the CMDB did not answer: ${counts} spooled (${r.spooled})`);
    return 0;
  } catch (e) {
    if (!(e instanceof CmdbRefused)) throw e;
    print(`[Error] the CMDB refused the report: ${e.message}`);
    const problems = e.body.problems;
    if (problems !== undefined) print(JSON.stringify(problems, null, 2));
    return 1;
  }
}

export interface Change {
  source: string;
  verb: string; // the verb as typed: "environment add prod"
  objects: CmdbObject[];
  relations?: CmdbRelation[];
  configDir?: string;
}

/** Report what a verb changed. Never throws, never fails the verb. Off with
 *  TAPPAAS_CMDB=off. Returns the report it made (null when none). */
export function reportChange(c: Change, env: Record<string, string | undefined> = process.env): CmdbReport | null {
  if (c.objects.length === 0) return null;
  return deliver({ source: c.source, kind: "change", verb: c.verb, ...changeJob(env), objects: c.objects, relations: c.relations }, c.configDir, env);
}

/** Report what a validate or reconcile read anyway, as a side effect (D4):
 *  as reportChange, never fails the verb. */
export function reportObservation(report: CmdbReport, configDir?: string, env: Record<string, string | undefined> = process.env): CmdbReport | null {
  if (!report.objects?.length) return null;
  return deliver({ ...report, kind: "observation" }, configDir, env);
}

function deliver(report: CmdbReport, configDir: string | undefined, env: Record<string, string | undefined>): CmdbReport | null {
  if (env.TAPPAAS_CMDB === "off") return null;
  const full = withStubs(report);
  try {
    const r = cmdbReport(full, cmdbOptions(configDir));
    if (!r.delivered && env.TAPPAAS_DEBUG === "1") console.log(`[Debug] cmdb: report spooled (${r.spooled})`);
  } catch (e) {
    console.log(`\x1b[01;33m[Warning]\x1b[0m the CMDB did not record this ${report.kind ?? "report"}: ${e instanceof Error ? e.message : String(e)}`);
  }
  return full;
}

// ── references to what another source reports ──────────────────────────
//
// A reference by class and name must find a live object, or the store
// refuses the whole batch; a reporter cannot know whether the environment or
// machine it names has been reported yet (cmdb rescan runs the sources one at
// a time, in no promised order). So every such reference is to an object of
// the batch: one it reports, or a stub — class and name, no attributes — that
// matches the stored object or creates it for its own source to fill. Only
// for classes known by their name (environment, machine, location, cluster,
// organization, zone, role): a stub of a class with other keys is refused.

type Ref = { ref?: string; id?: string; class?: string; name?: string };
const isClassName = (v: unknown): v is Ref =>
  v !== null && typeof v === "object" && !Array.isArray(v) && typeof (v as Ref).class === "string" && typeof (v as Ref).name === "string" && (v as Ref).ref === undefined && (v as Ref).id === undefined;

/** The report with every {class, name} reference turned into a ref to an
 *  object of the batch, stubs added (first) where the batch has none. */
export function withStubs(report: CmdbReport): CmdbReport {
  const objects = (report.objects ?? []).map((o) => ({ ...o, attributes: o.attributes ? { ...o.attributes } : undefined }));
  const stubs: CmdbObject[] = [];
  const refOf = (cls: string, name: string): string => {
    const own = objects.find((o) => o.class === cls && o.name === name);
    if (own) return (own.ref ??= `${cls}/${name}`);
    const key = `stub:${cls}/${name}`;
    if (!stubs.some((s) => s.ref === key)) stubs.push({ ref: key, class: cls, name });
    return key;
  };
  const resolve = (v: unknown): unknown => (isClassName(v) ? { ref: refOf(v.class as string, v.name as string) } : v);
  for (const o of objects) {
    if (!o.attributes) {
      delete o.attributes;
      continue;
    }
    for (const [k, v] of Object.entries(o.attributes)) o.attributes[k] = resolve(v);
  }
  const relations = (report.relations ?? []).map((r) => ({ ...r, from: resolve(r.from) as CmdbRelation["from"], to: resolve(r.to) as CmdbRelation["to"] }));
  const out: CmdbReport = { ...report, objects: referencedFirst([...stubs, ...objects]) };
  if (relations.length) out.relations = relations;
  else delete out.relations;
  return out;
}

/** The objects in their order, except that an object comes after every
 *  object its attributes refer to (the store resolves a ref only to an object
 *  earlier in the report). */
function referencedFirst(objects: CmdbObject[]): CmdbObject[] {
  const byRef = new Map(objects.filter((o) => o.ref).map((o) => [o.ref as string, o]));
  const out: CmdbObject[] = [];
  const placed = new Set<CmdbObject>();
  const visiting = new Set<CmdbObject>();
  const place = (o: CmdbObject): void => {
    if (placed.has(o) || visiting.has(o)) return; // a cycle keeps the given order
    visiting.add(o);
    for (const v of Object.values(o.attributes ?? {})) {
      const r = v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Ref).ref : undefined;
      const target = r ? byRef.get(r) : undefined;
      if (target) place(target);
    }
    visiting.delete(o);
    placed.add(o);
    out.push(o);
  };
  for (const o of objects) place(o);
  return out;
}

// ── the CI of a module instance (D3) ───────────────────────────────────

/** A deployed config's module and version: its `release`. */
export function releaseOf(raw: Obj): { module: string; version?: string } | undefined {
  const src = moduleSourceOf(raw);
  if (!src) return undefined;
  return compact({ module: moduleOfLocation(src), version: typeof raw.version === "string" ? raw.version : undefined }) as { module: string; version?: string };
}

/** The node class of a module's kind; null for an application (an app on a
 *  node) or a kind that is none. */
export function nodeClassOf(kind: string | null | undefined): "vm" | "lxc" | "machine" | "device" | null {
  return kind === "vm" || kind === "lxc" || kind === "machine" || kind === "device" ? kind : null;
}

const str = (v: unknown): string | undefined => (typeof v === "string" && v !== "" ? v : undefined);
const num = (v: unknown): number | undefined => (typeof v === "number" && Number.isFinite(v) ? v : typeof v === "string" && /^\d+$/.test(v) ? Number(v) : undefined);

/** The attributes every module instance's CI carries: desired, release,
 *  stage, displayName, description. */
export function moduleCiAttributes(name: string, raw: Obj): Obj {
  return compact({
    desired: { file: `${name}.json` },
    release: releaseOf(raw),
    displayName: str(raw.displayName),
    description: str(raw.description),
  });
}

/** A module's node attributes its config states (desired state the live
 *  reads refine): vmid, management, environment (by name), addresses. */
export function moduleNodeAttributes(name: string, raw: Obj, cls: string): Obj {
  const a: Obj = { ...moduleCiAttributes(name, raw), stack: str(raw.stack) };
  if (cls === "vm" || cls === "lxc") a.vmid = num(raw.vmid);
  const mgmt = str(raw.management);
  if (mgmt === "managed" || mgmt === "unmanaged") a.management = mgmt;
  const env = str(raw.environment);
  if (env) a.environment = { class: "environment", name: env };
  const addr = str(raw.address);
  if (addr) a.addresses = [addr];
  if (cls === "machine") a.hostname = addr;
  if (cls === "device") a.managementAddress = addr;
  return compact(a);
}
