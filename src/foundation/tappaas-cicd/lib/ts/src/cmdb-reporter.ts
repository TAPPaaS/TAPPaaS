// cmdb-reporter.ts — what a manager's `report` verb and its changing verbs
// share on top of the cmdb.ts client (ADR-040 D4): a batch that dedupes
// objects and relations by ref, stubs for the objects another reporter owns,
// the console's job id on a change, and delivery that never fails the verb.
//
// A stub is an object named but not described (a zone's environment, a
// datastore's machine): the controller matches it by its key and writes
// nothing, or creates it bare until its own reporter describes it. A reference
// the controller cannot resolve at all (an id it does not have, a class that
// does not exist) refuses the whole batch; delivery then drops what the refusal
// names, and what hangs off it, and sends the rest.
//
// A change carries the console's job and its actor (job.ts currentJob).
// TAPPAAS_CMDB=off sends nothing (tests that run changing verbs and do not
// look at the CMDB).

import { CmdbObject, CmdbOptions, CmdbRef, CmdbRefused, CmdbRelation, CmdbReport, ReportOutcome, cmdbReport } from "./cmdb";
import { changeJob } from "./job";

type Obj = Record<string, unknown>;

export class CmdbBatch {
  readonly objects: CmdbObject[] = [];
  readonly relations: CmdbRelation[] = [];
  private readonly byRef = new Map<string, CmdbObject>();
  private readonly relKeys = new Set<string>();

  constructor(readonly source: string) {}

  /** Add an object, or merge attributes into the one already under its ref
   *  (default `<class>:<name>`). Returns the ref. */
  put(cls: string, name: string, attributes: Obj = {}, ref = `${cls}:${name}`): string {
    const had = this.byRef.get(ref);
    const attrs = Object.fromEntries(Object.entries(attributes).filter(([, v]) => v !== undefined));
    if (had) had.attributes = { ...(had.attributes ?? {}), ...attrs };
    else {
      const o: CmdbObject = { ref, class: cls, name, attributes: attrs };
      this.objects.push(o);
      this.byRef.set(ref, o);
    }
    return ref;
  }

  /** An object this reporter names but does not describe. */
  stub(cls: string, name: string, attributes: Obj = {}, ref = `${cls}:${name}`): string {
    return this.byRef.has(ref) ? ref : this.put(cls, name, attributes, ref);
  }

  /** The object `end: true`: a CI retired, a resource disposed of (D7). */
  end(cls: string, name: string, ref = `${cls}:${name}`): string {
    this.put(cls, name, {}, ref);
    const o = this.byRef.get(ref)!;
    o.attributes = {};
    o.end = true;
    return ref;
  }

  has(ref: string): boolean {
    return this.byRef.has(ref);
  }

  relate(type: string, from: CmdbRef, to: CmdbRef, attributes?: Obj): void {
    const key = `${type}|${JSON.stringify(from)}|${JSON.stringify(to)}`;
    if (this.relKeys.has(key)) return;
    this.relKeys.add(key);
    this.relations.push(attributes && Object.keys(attributes).length ? { type, from, to, attributes } : { type, from, to });
  }

  /** The batch as an observation, or as a change with the console's job. */
  report(kind: "observation" | "change" = "observation", verb?: string): CmdbReport {
    const r: CmdbReport = { source: this.source, kind, objects: this.objects, relations: this.relations };
    if (kind === "change") Object.assign(r, { verb }, changeJob());
    return r;
  }
}

const refOf = (r: CmdbRef): string | undefined => (typeof r === "string" ? r : r.ref);

/** The report without what a refusal names (`objects[i]`, `relations[i]`) and
 *  what references it. Null when the refusal names nothing it can drop. */
export function pruneRefused(report: CmdbReport, problems: unknown): { report: CmdbReport; dropped: string[] } | null {
  const objects = report.objects ?? [];
  const relations = report.relations ?? [];
  const badObj = new Set<number>();
  const badRel = new Set<number>();
  for (const p of Array.isArray(problems) ? problems : []) {
    const m = /^(objects|relations)\[(\d+)\]/.exec(String((p as Obj)?.at ?? ""));
    if (m) (m[1] === "objects" ? badObj : badRel).add(Number(m[2]));
  }
  if (!badObj.size && !badRel.size) return null;
  const dropped: string[] = [];
  const goneRefs = new Set<string>();
  let keep = objects.filter((o, i) => {
    if (!badObj.has(i)) return true;
    if (o.ref) goneRefs.add(o.ref);
    dropped.push(`${o.class} ${o.name}`);
    return false;
  });
  // An object whose relation field points at a dropped one goes with it.
  const refsIn = (v: unknown): string[] =>
    v && typeof v === "object" ? (typeof (v as Obj).ref === "string" ? [String((v as Obj).ref)] : Object.values(v as Obj).flatMap(refsIn)) : [];
  for (let grew = true; grew; ) {
    grew = false;
    keep = keep.filter((o) => {
      if (!refsIn(o.attributes ?? {}).some((r) => goneRefs.has(r))) return true;
      if (o.ref) goneRefs.add(o.ref);
      dropped.push(`${o.class} ${o.name}`);
      grew = true;
      return false;
    });
  }
  const rels = relations.filter((r, i) => {
    const gone = badRel.has(i) || [refOf(r.from), refOf(r.to)].some((x) => x !== undefined && goneRefs.has(x));
    if (gone) dropped.push(`${r.type} ${JSON.stringify(r.from)} → ${JSON.stringify(r.to)}`);
    return !gone;
  });
  return { report: { ...report, objects: keep, relations: rels }, dropped };
}

export interface SendOutcome {
  outcome: ReportOutcome | null; // null: not sent (off, or refused outright)
  dropped: string[];
  error?: string;
}

/** Deliver a report. Never throws: an outage spools (cmdb.ts), a refusal
 *  drops what it names and sends the rest, up to a few rounds. */
export function sendReport(report: CmdbReport, o: CmdbOptions = {}, env: Record<string, string | undefined> = process.env): SendOutcome {
  if ((env.TAPPAAS_CMDB ?? "").toLowerCase() === "off") return { outcome: null, dropped: [] };
  let r = report;
  const dropped: string[] = [];
  for (let round = 0; round < 5; round++) {
    try {
      return { outcome: cmdbReport(r, o), dropped };
    } catch (e) {
      if (!(e instanceof CmdbRefused)) return { outcome: null, dropped, error: (e as Error).message };
      const pruned = pruneRefused(r, e.body.problems);
      if (!pruned || !(pruned.report.objects?.length || pruned.report.relations?.length)) return { outcome: null, dropped, error: e.message };
      dropped.push(...pruned.dropped);
      r = pruned.report;
    }
  }
  return { outcome: null, dropped, error: "refused after five rounds" };
}

const note = (msg: string): void => {
  process.stderr.write(`[Warning] cmdb: ${msg}\n`);
};

/** A `report` verb: print the payload (`--json`) or send it and say how it
 *  went. Returns the exit code: 0, also when the report was spooled. */
export function printOrSend(batch: CmdbBatch, json: boolean, o: CmdbOptions = {}): number {
  const report = batch.report();
  if (json) {
    process.stdout.write(JSON.stringify(report, null, 1) + "\n");
    return 0;
  }
  const s = sendReport(report, o);
  for (const d of s.dropped) note(`left out (refused): ${d}`);
  const counts = `${report.objects?.length ?? 0} objects, ${report.relations?.length ?? 0} relations`;
  if (s.outcome?.delivered) console.log(`${batch.source}: reported ${counts} to the CMDB`);
  else if (s.outcome?.spooled) console.log(`${batch.source}: the CMDB did not answer; ${counts} spooled to ${s.outcome.spooled}`);
  else if (s.error) note(`report not recorded: ${s.error}`);
  return 0;
}

/** `report --discover` (ADR-040 D15): the plain report, then what only the
 *  sweep reads, each sent on its own so a refusal of one leaves the other.
 *  `--json` prints them as an array. */
export function printOrSendAll(batches: CmdbBatch[], json: boolean, o: CmdbOptions = {}): number {
  if (json) {
    process.stdout.write(JSON.stringify(batches.map((b) => b.report()), null, 1) + "\n");
    return 0;
  }
  for (const b of batches) printOrSend(b, false, o);
  return 0;
}

/** A changing verb's report: quiet when it goes, a warning on stderr when it
 *  is refused; never fails the verb. */
export function reportChange(batch: CmdbBatch, verb: string, o: CmdbOptions = {}): SendOutcome {
  if (!batch.objects.length && !batch.relations.length) return { outcome: null, dropped: [] };
  let s: SendOutcome;
  try {
    s = sendReport(batch.report("change", verb), o);
  } catch (e) {
    s = { outcome: null, dropped: [], error: (e as Error).message }; // a full disk under the spool
  }
  for (const d of s.dropped) note(`left out (refused): ${d}`);
  if (s.error) note(`change not recorded: ${s.error}`);
  return s;
}

/** IPv4 dotted quad of a network address plus an offset (a zone's DHCP range). */
export function ipv4Offset(cidr: string, offset: number): string | undefined {
  const m = /^(\d+)\.(\d+)\.(\d+)\.(\d+)\/(\d+)$/.exec(cidr.trim());
  if (!m) return undefined;
  const bits = Number(m[5]);
  const base = ((Number(m[1]) << 24) | (Number(m[2]) << 16) | (Number(m[3]) << 8) | Number(m[4])) >>> 0;
  const net = bits === 0 ? 0 : (base & (~0 << (32 - bits))) >>> 0;
  const n = (net + offset) >>> 0;
  return [n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255].join(".");
}

/** Whether an IPv4 address lies in a CIDR. */
export function ipv4In(ip: string, cidr: string): boolean {
  const toN = (s: string): number | null => {
    const p = s.split(".").map(Number);
    return p.length === 4 && p.every((x) => Number.isInteger(x) && x >= 0 && x < 256) ? ((p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]) >>> 0 : null;
  };
  const [net, b] = cidr.split("/");
  const a = toN(ip);
  const n = toN(net ?? "");
  const bits = Number(b);
  if (a === null || n === null || !Number.isInteger(bits)) return false;
  const mask = bits === 0 ? 0 : (~0 << (32 - bits)) >>> 0;
  return ((a & mask) >>> 0) === ((n & mask) >>> 0);
}
