// store.ts — what cmdb-controller does with the store (ADR-040 D2, D5, D6,
// D13, D14): take a report, answer a query, show an object and its history,
// walk its impact, resolve telemetry attributes to it.
//
// A report is one transaction: every object in it is matched by its class's
// keys (D5), every attribute checked against the fields of its class and its
// ancestors, and only then written; one problem refuses the whole batch, so a
// reporter never leaves half a picture. A value that changes closes the row
// that held it and opens a new one (D6); nothing is ever deleted.

import { FieldDef, KeyVia, Metamodel } from "./metamodel";
import { Param, Pg, Query, Row } from "./pg";

type Obj = Record<string, unknown>;

export const CONTROLLER_SOURCE = "cmdb-controller";
const NOT_PLACEHOLDER = "NOT EXISTS (SELECT 1 FROM attribute ph WHERE ph.object = o.id AND ph.name = 'placeholder' AND upper_inf(ph.validity))";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// ── the report's shape ──────────────────────────────────────────────────

/** A reference to an object: a ref given earlier in the same report, an id,
 *  or a class and a name. As a plain string: a ref, else an id, else a name. */
export type Ref = string | { ref?: string; id?: string; class?: string; name?: string };

export interface ReportObject {
  ref?: string;
  id?: string; // this object, by id, instead of its keys
  class: string;
  name: string;
  attributes?: Obj;
  end?: boolean; // retired (a CI) or disposed (a resource): kept, out of key matching
  recorded?: boolean; // what no machine can see, recorded by an operator (D7)
}

export interface ReportRelation {
  type: string;
  from: Ref;
  to: Ref;
  attributes?: Obj;
  end?: boolean;
  recorded?: boolean;
}

export interface Report {
  source: string;
  kind?: "observation" | "change";
  time?: string;
  job?: string;
  verb?: string;
  actor?: string;
  // What a source concluded about objects, not a sighting of them (ADR-041 D2):
  // they are named by id, nothing is created, and it does not count as seen, so
  // an assessment every few minutes neither holds off a CI's expiry nor revives
  // an unseen one.
  assessment?: boolean;
  objects?: ReportObject[];
  relations?: ReportRelation[];
  // The report names every relation of `type` from `from` (ADR-040 D4): an
  // open one it does not name has ended, and is closed. One an operator
  // recorded is left alone. With `toClass`, only the relations to an object of
  // that class (or a subclass): a node's zone, not its cluster.
  complete?: { type: string; from: Ref; toClass?: string }[];
}

export interface Problem {
  at: string;
  error: string;
  candidates?: { id: string; class: string; name: string }[];
}

/** A refused report: 409 when it conflicts with what is stored (a key
 *  matching two objects, an immutable value changed), 422 when it does not
 *  fit the metamodel. */
export class ReportError extends Error {
  constructor(
    readonly status: 409 | 422,
    readonly problems: Problem[],
  ) {
    super(problems.map((p) => `${p.at}: ${p.error}`).join("; "));
  }
}

export class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly extra?: Obj,
  ) {
    super(message);
  }
}

export interface ChangeEvent {
  id: number;
  kind: string;
  source: string;
  job: string | null;
  verb: string | null;
  actor: string | null;
  time: string;
  objects: string[];
  relations: number[];
  drift: boolean;
}

interface Target {
  id: string;
  class: string;
  name: string;
}

interface Current {
  id: number;
  value: unknown;
  from: string;
}

function isObj(v: unknown): v is Obj {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

function same(a: unknown, b: unknown): boolean {
  return canonical(a) === canonical(b);
}

// The words of a relation that carry dependency (ADR-041 D3): what derivation
// reads, set by the one source that knows them.
export const DEPENDENCY_WORDS = ["required", "redundancyGroup"];

/** A relation's attributes after a report gave `given` over `had`: the
 *  dependency words it does not name are kept, a null one is unset; a report
 *  of nothing but them annotates, keeping the rest of `had`. */
export function withDependency(had: Obj, given: Obj): Obj {
  const named = Object.keys(given);
  const annotation = named.length > 0 && named.every((k) => DEPENDENCY_WORDS.includes(k));
  const out: Obj = annotation ? { ...had, ...given } : { ...given };
  for (const w of DEPENDENCY_WORDS) {
    if (!(w in given) && w in had) out[w] = had[w];
    if (out[w] === null) delete out[w];
  }
  return out;
}

// JSON with object keys sorted: jsonb does not keep key order.
function canonical(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canonical).join(",")}]`;
  if (isObj(v)) return `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`).join(",")}}`;
  return JSON.stringify(v);
}

// A value without its members marked volatile (a condition's lastChecked):
// what history compares. A value that differs only there is rewritten in place.
export function stable(f: FieldDef, v: unknown): unknown {
  const props = isObj(f.spec.items) ? f.spec.items.properties : f.spec.properties;
  if (!isObj(props)) return v;
  const gone = Object.keys(props).filter((k) => isObj(props[k]) && (props[k] as Obj).volatile === true);
  if (!gone.length) return v;
  const strip = (x: unknown): unknown => (isObj(x) ? Object.fromEntries(Object.entries(x).filter(([k]) => !gone.includes(k))) : x);
  return Array.isArray(v) ? v.map(strip) : strip(v);
}

function later(a: string, b: string): string {
  return Date.parse(a) >= Date.parse(b) ? a : b;
}

const enumOf = (spec: Obj): unknown[] | null =>
  Array.isArray(spec.enum) ? spec.enum : isObj(spec.values) ? Object.keys(spec.values) : null;

// Enums and required members only: the rest of a shape is the reporter's.
function membersOk(spec: Obj, v: Obj): string | null {
  for (const [k, p] of Object.entries(isObj(spec.properties) ? spec.properties : {})) {
    if (!isObj(p)) continue;
    if (v[k] === undefined) {
      if (p.required === true) return `with ${k}`;
      continue;
    }
    const e = enumOf(p);
    if (e && !e.includes(v[k])) return `whose ${k} is one of ${e.join(", ")}`;
  }
  return null;
}

export function typeOk(f: FieldDef, v: unknown): string | null {
  switch (f.type) {
    case "string": {
      if (typeof v !== "string") return "a string";
      const e = enumOf(f.spec);
      return e && !e.includes(v) ? `one of ${e.join(", ")}` : null;
    }
    case "integer":
      return Number.isInteger(v) ? null : "an integer";
    case "number":
      return typeof v === "number" && Number.isFinite(v) ? null : "a number";
    case "boolean":
      return typeof v === "boolean" ? null : "true or false";
    case "array": {
      if (!Array.isArray(v)) return "an array";
      const items = isObj(f.spec.items) ? f.spec.items : null;
      if (items) {
        const e = enumOf(items);
        for (const x of v) {
          if (items.type === "string" && typeof x !== "string") return "an array of strings";
          if (items.type === "integer" && !Number.isInteger(x)) return "an array of integers";
          if (items.type === "object" && !isObj(x)) return "an array of objects";
          if (e && !e.includes(x)) return `an array of ${e.join(", ")}`;
          const m = isObj(x) ? membersOk(items, x) : null;
          if (m) return `an array of objects ${m}`;
        }
      }
      return null;
    }
    case "object": {
      if (!isObj(v)) return "an object";
      const m = membersOk(f.spec, v);
      return m ? `an object ${m}` : null;
    }
    default:
      return null;
  }
}

/** What a report wrote, for the reporter. */
/** A CI to retire, and why (D7). */
export interface RetireCandidate {
  id: string;
  class: string;
  name: string;
  reason: string;
  on?: string; // the ended object it was known by
}

export interface ReportResult {
  change: number | null;
  objects: { ref?: string; id: string; class: string; name: string; reportedAs?: string; created: boolean; adopted?: boolean; changed: string[]; drift: string[]; ended: boolean }[];
  relations: number[];
  placeholders: Target[]; // objects made for a reference to something not reported yet
}

export class Store {
  private listeners = new Set<(e: ChangeEvent) => void>();

  constructor(
    readonly pg: Pg,
    readonly mm: Metamodel,
  ) {}

  publish(e: ChangeEvent): void {
    for (const fn of this.listeners) fn(e);
  }

  onChange(fn: (e: ChangeEvent) => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  // ── report ────────────────────────────────────────────────────────────

  async report(r: Report): Promise<ReportResult> {
    if (!isObj(r)) throw new HttpError(400, "a report is a JSON object");
    if (typeof r.source !== "string" || !r.source) throw new HttpError(400, "a report names its source");
    const kind = r.kind ?? "observation";
    if (kind !== "observation" && kind !== "change") throw new HttpError(400, "kind is observation or change");
    const t = r.time ?? new Date().toISOString();
    if (Number.isNaN(Date.parse(t))) throw new HttpError(400, `time ${t} is not a date`);
    const objects = r.objects ?? [];
    const relations = r.relations ?? [];
    if (!Array.isArray(objects) || !Array.isArray(relations)) throw new HttpError(400, "objects and relations are arrays");

    const { result, event } = await this.pg.tx(async (q) => {
      const run = new ReportRun(this.mm, q, r.source, kind, new Date(t).toISOString(), r.source === "recorded", r.assessment === true);
      const c = await q(
        `INSERT INTO change (kind, source, job, verb, actor, time) VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`,
        [kind, r.source, r.job ?? null, r.verb ?? null, r.actor ?? null, run.t],
      );
      run.change = Number(c.rows[0].id);
      run.prescan(objects);
      for (let i = 0; i < objects.length; i++) await run.object(i, objects[i]);
      for (let i = 0; i < relations.length; i++) await run.relation(i, relations[i]);
      const complete = Array.isArray(r.complete) ? r.complete : [];
      for (let i = 0; i < complete.length; i++) await run.complete(i, complete[i]);
      if (run.problems.length) {
        throw new ReportError(run.problems.some((p) => p.candidates || /conflict|immutable|matches/.test(p.error)) ? 409 : 422, run.problems);
      }
      const touched = [...run.touched];
      if (!touched.length && !run.relationIds.size) {
        await q("DELETE FROM change WHERE id = $1", [run.change]);
        return { result: { change: null, objects: run.results, relations: [], placeholders: [] }, event: null };
      }
      const ev = await q(
        `UPDATE change SET objects = ARRAY(SELECT (jsonb_array_elements_text($2::jsonb))::uuid),
                relations = ARRAY(SELECT (jsonb_array_elements_text($3::jsonb))::bigint), drift = $4
          WHERE id = $1
          RETURNING id, kind, source, job, verb, actor, time, to_jsonb(objects) AS objects, to_jsonb(relations) AS relations, drift`,
        [run.change, touched, [...run.relationIds], run.drift],
      );
      return {
        result: { change: run.change, objects: run.results, relations: [...run.relationIds], placeholders: run.placeholders },
        event: ev.rows[0] as unknown as ChangeEvent,
      };
    });
    if (event) for (const fn of this.listeners) fn(event);
    // A report moves the clock the expiry is read against; it never fails for it.
    await this.expire().catch(() => undefined);
    return result;
  }

  // ── retire (D7) ──────────────────────────────────────────────────────

  /** The live CIs an ended object left behind: known by it (a key holds a
   *  relation to it, D5) and with no such relation open, the last one to an
   *  object that has ended — a pool of a node removed before a node's end
   *  took its pools with it. Nothing can find them again. */
  async orphans(now: Date = new Date()): Promise<RetireCandidate[]> {
    // A placeholder (made for a reference to something not reported yet) that
    // no owner reported within its class's expiry never will be: it goes too,
    // unless an object seen within that expiry still refers to it (an asset
    // allocated to a role no source reports is a reference, not an orphan).
    const expiries: Record<string, number> = {};
    for (const c of this.mm.classes.keys()) expiries[c] = this.mm.expirySeconds(c) ?? 7 * 86400;
    const stale = (
      await this.pg.query(
        `SELECT o.id, o.class, o.name, e.value::double precision AS secs FROM object o
           JOIN jsonb_each_text($1::jsonb) e ON e.key = o.class
          WHERE o.ended IS NULL
            AND EXISTS (SELECT 1 FROM attribute ph WHERE ph.object = o.id AND ph.name = 'placeholder' AND upper_inf(ph.validity))
            AND o.created + make_interval(secs => e.value::double precision) < $2::timestamptz
            AND NOT EXISTS (
              SELECT 1 FROM relation r
                JOIN object x ON x.id = CASE WHEN r.from_object = o.id THEN r.to_object ELSE r.from_object END
               WHERE (r.from_object = o.id OR r.to_object = o.id) AND upper_inf(r.validity)
                 AND x.ended IS NULL AND x.last_seen IS NOT NULL
                 AND x.last_seen + make_interval(secs => e.value::double precision) >= $2::timestamptz)
          ORDER BY o.class, o.name, o.id`,
        [expiries, now.toISOString()],
      )
    ).rows.map((r) => ({ id: String(r.id), class: String(r.class), name: String(r.name), reason: `a placeholder nothing reported within ${Math.round(Number(r.secs) / 86400)} day(s)` }));
    const keyed = this.mm.keyedOn();
    if (!keyed.length) return stale;
    const rows = (
      await this.pg.query(
        `SELECT DISTINCT o.id, o.class, o.name, t.class AS on_class, t.name AS on_name, t.id AS on_id
           FROM object o
           JOIN jsonb_to_recordset($1::jsonb) AS k(class text, relation text) ON k.class = o.class
           CROSS JOIN LATERAL (SELECT r.to_object FROM relation r WHERE r.from_object = o.id AND r.type = k.relation
                                ORDER BY upper(r.validity) DESC NULLS FIRST LIMIT 1) last
           JOIN object t ON t.id = last.to_object
          WHERE o.ended IS NULL AND t.ended IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM relation r2 WHERE r2.from_object = o.id AND r2.type = k.relation AND upper_inf(r2.validity))
          ORDER BY o.class, o.name, o.id`,
        [JSON.stringify(keyed)],
      )
    ).rows;
    return [...stale, ...rows.filter((r) => !stale.some((x) => x.id === String(r.id))).map((r) => ({ id: String(r.id), class: String(r.class), name: String(r.name), reason: `its ${String(r.on_class)} ${String(r.on_name)} is retired`, on: String(r.on_id) }))];
  }

  /** Retire live CIs (D7): by id, or the orphans. A preview unless apply;
   *  applied, one change (verb as given, default "retire") ends each, and
   *  what is known by each with it. Never a resource: an asset is disposed
   *  of through asset-manager. */
  async retire(body: Obj): Promise<{ change: number | null; apply: boolean; retire: RetireCandidate[]; retired: string[] }> {
    const apply = body.apply === true;
    const ids = Array.isArray(body.ids) ? body.ids.map(String) : [];
    if (!ids.length && body.orphans !== true) throw new HttpError(400, "retire: name ids, or orphans: true");
    const at = typeof body.now === "string" && !Number.isNaN(Date.parse(body.now)) ? new Date(body.now) : new Date();
    const want: RetireCandidate[] = body.orphans === true ? await this.orphans(at) : [];
    for (const id of ids) {
      if (!UUID_RE.test(id)) throw new HttpError(400, `retire: ${id} is not an id`);
      const r = (await this.pg.query("SELECT id, class, name, ended FROM object WHERE id = $1", [id])).rows[0];
      if (!r) throw new HttpError(404, `retire: no object ${id}`);
      if (r.ended !== null) throw new HttpError(409, `retire: ${String(r.class)} ${String(r.name)} (${id}) is already ended`);
      if (!this.mm.isA(String(r.class), "ci")) throw new HttpError(422, `retire: ${String(r.class)} ${String(r.name)} is not a CI — an asset is disposed of through asset-manager`);
      if (!want.some((w) => w.id === id)) want.push({ id, class: String(r.class), name: String(r.name), reason: "named" });
    }
    if (!apply || !want.length) return { change: null, apply, retire: want, retired: [] };
    const verb = typeof body.verb === "string" && body.verb ? body.verb : "retire";
    const t = new Date().toISOString();
    const { event, retired } = await this.pg.tx(async (q) => {
      const run = new ReportRun(this.mm, q, CONTROLLER_SOURCE, "change", t, false, false);
      const c = await q(`INSERT INTO change (kind, source, job, verb, actor, time) VALUES ('change', $1, $2, $3, $4, $5) RETURNING id`, [
        CONTROLLER_SOURCE, typeof body.job === "string" ? body.job : null, verb, typeof body.actor === "string" ? body.actor : null, t,
      ]);
      run.change = Number(c.rows[0].id);
      for (const w of want) await run.retire(w.id, w.class);
      const touched = [...run.touched];
      const ev = await q(
        `UPDATE change SET objects = ARRAY(SELECT (jsonb_array_elements_text($2::jsonb))::uuid) WHERE id = $1
          RETURNING id, kind, source, job, verb, actor, time, to_jsonb(objects) AS objects, to_jsonb(relations) AS relations, drift`,
        [run.change, touched],
      );
      return { event: ev.rows[0] as unknown as ChangeEvent, retired: touched };
    });
    for (const fn of this.listeners) fn(event);
    return { change: Number(event.id), apply, retire: want, retired };
  }

  // ── unseen (D5) ──────────────────────────────────────────────────────

  /** Mark every live CI that no source has reported for longer than its
   *  class's expiry as unseen: its stage, from the moment the expiry ran out.
   *  Never a delete. Run after each report and on the service's timer.
   *  Returns how many were marked. */
  async expire(now: Date = new Date()): Promise<number> {
    const expiries: Record<string, number> = {};
    for (const c of this.mm.classes.keys()) {
      const e = this.mm.expirySeconds(c);
      if (e !== null && !this.mm.classes.get(c)!.abstract) expiries[c] = e;
    }
    const event = await this.pg.tx(async (q) => {
      const due = (
        await q(
          `SELECT o.id, o.last_seen + make_interval(secs => e.value::double precision) AS since,
                  st.id AS stage_id, lower(st.validity) AS stage_from
             FROM object o
             JOIN jsonb_each_text($1::jsonb) e ON e.key = o.class
             LEFT JOIN attribute st ON st.object = o.id AND st.name = 'stage' AND upper_inf(st.validity)
            WHERE o.ended IS NULL AND o.last_seen IS NOT NULL
              AND o.last_seen + make_interval(secs => e.value::double precision) < $2::timestamptz
              AND (st.id IS NULL OR st.value <> '"unseen"'::jsonb)`,
          [expiries, now.toISOString()],
        )
      ).rows;
      if (!due.length) return null;
      const c = await q(`INSERT INTO change (kind, source, verb, time) VALUES ('observation', $1, 'expire', $2) RETURNING id`, [
        CONTROLLER_SOURCE,
        now.toISOString(),
      ]);
      const change = Number(c.rows[0].id);
      for (const d of due) {
        const t = d.stage_from === null ? String(d.since) : later(String(d.since), String(d.stage_from));
        if (d.stage_id !== null) await q("UPDATE attribute SET validity = tstzrange(lower(validity), $2) WHERE id = $1", [Number(d.stage_id), t]);
        await q(
          `INSERT INTO attribute (object, name, value, source, change, validity) VALUES ($1, 'stage', '"unseen"'::jsonb, $2, $3, tstzrange($4, NULL))`,
          [String(d.id), CONTROLLER_SOURCE, change, t],
        );
      }
      const ev = await q(
        `UPDATE change SET objects = ARRAY(SELECT (jsonb_array_elements_text($2::jsonb))::uuid) WHERE id = $1
          RETURNING id, kind, source, job, verb, actor, time, to_jsonb(objects) AS objects, to_jsonb(relations) AS relations, drift`,
        [change, due.map((d) => String(d.id))],
      );
      return ev.rows[0] as unknown as ChangeEvent;
    });
    if (!event) return 0;
    for (const fn of this.listeners) fn(event);
    return event.objects.length;
  }

  /** What a reader of the health records needs of the metamodel: each relation type's dependant end, whether it is required and
   *  the end the Health view's tree nests (D5), each class's ancestors. */
  rules(): Obj {
    const relations = new Map(this.mm.relations.map((r) => [r.name, { name: r.name, dependant: r.dependant, required: r.required, tree: r.tree }]));
    return {
      relations: [...relations.values()],
      ancestors: Object.fromEntries([...this.mm.classes.keys()].map((c) => [c, this.mm.ancestors(c)])),
      fields: [...new Set([...this.mm.classes.keys()].flatMap((c) => [...this.mm.fields(c).keys()]))].sort(),
    };
  }

  // ── query ─────────────────────────────────────────────────────────────

  /** Objects by class (its subclasses too, through class_ancestor), by
   *  physical, by attribute value (containment: a scalar equals, an array
   *  contains), as of a time. */
  async query(body: Obj): Promise<Obj[]> {
    const cls = body.class === undefined || body.class === null ? null : String(body.class);
    if (cls !== null && !this.mm.has(cls)) throw new HttpError(404, `no class ${cls}`);
    const at = body.at === undefined || body.at === null ? null : String(body.at);
    if (at !== null && Number.isNaN(Date.parse(at))) throw new HttpError(400, `at ${at} is not a date`);
    const where = isObj(body.where) ? body.where : {};
    const params: Param[] = [cls, typeof body.physical === "boolean" ? body.physical : null, typeof body.recorded === "boolean" ? body.recorded : null];
    const conds = [
      "($3::boolean IS NULL OR o.recorded = $3)",
      "($1::text IS NULL OR EXISTS (SELECT 1 FROM class_ancestor ca WHERE ca.class = o.class AND ca.ancestor = $1))",
      "($2::boolean IS NULL OR c.physical = $2)",
    ];
    let valid = "upper_inf(a.validity)";
    if (at !== null) {
      params.push(at);
      const p = `$${params.length}::timestamptz`;
      conds.push(`o.created <= ${p} AND (o.ended IS NULL OR o.ended > ${p})`);
      valid = `a.validity @> ${p}`;
    } else if (body.includeEnded !== true) conds.push("o.ended IS NULL");
    for (const [k, v] of Object.entries(where)) {
      if (k === "name") {
        params.push(String(v));
        conds.push(`o.name = $${params.length}`);
        continue;
      }
      // conditions.status=critical: a path into the value, or into any member of
      // an array value; containment, so the GIN index carries it.
      const [attr, ...path] = k.split(".");
      const value = path.reduceRight<unknown>((inner, key) => ({ [key]: inner }), v);
      params.push(attr, JSON.stringify(value), JSON.stringify([value]));
      conds.push(`EXISTS (SELECT 1 FROM attribute a WHERE a.object = o.id AND a.name = $${params.length - 2} AND (a.value @> $${params.length - 1}::jsonb OR a.value @> $${params.length}::jsonb) AND ${valid})`);
    }
    const limit = Number.isInteger(body.limit) ? Number(body.limit) : 10000;
    const rows = (
      await this.pg.query(
        `SELECT o.id, o.class, o.name, o.display_name, o.created, o.ended, o.last_seen, o.seen, o.recorded, c.physical
           FROM object o JOIN class c ON c.name = o.class
          WHERE ${conds.join(" AND ")}
          ORDER BY o.class, o.name LIMIT ${limit}`,
        params,
      )
    ).rows;
    const attrs = await this.attributesOf(rows.map((r) => String(r.id)), at);
    return rows.map((r) => ({
      id: r.id,
      class: r.class,
      name: r.name,
      displayName: r.display_name,
      physical: r.physical,
      recorded: r.recorded,
      created: r.created,
      ended: r.ended,
      lastSeen: r.last_seen,
      seen: r.seen ?? {}, // when each source last reported it
      attributes: Object.fromEntries((attrs.get(String(r.id)) ?? []).map((a) => [a.name, a.value])),
    }));
  }

  private async attributesOf(ids: string[], at: string | null): Promise<Map<string, { name: string; value: unknown; source: string; since: string }[]>> {
    const out = new Map<string, { name: string; value: unknown; source: string; since: string }[]>();
    if (!ids.length) return out;
    const rows = (
      await this.pg.query(
        `SELECT a.object, a.name, a.value, a.source, lower(a.validity) AS since FROM attribute a
          WHERE a.object IN (SELECT (jsonb_array_elements_text($1::jsonb))::uuid)
            AND ${at === null ? "upper_inf(a.validity)" : "a.validity @> $2::timestamptz"}
          ORDER BY a.name`,
        at === null ? [ids] : [ids, at],
      )
    ).rows;
    for (const r of rows) {
      const k = String(r.object);
      out.set(k, [...(out.get(k) ?? []), { name: String(r.name), value: r.value, source: String(r.source), since: String(r.since) }]);
    }
    return out;
  }

  // ── show, history ─────────────────────────────────────────────────────

  /** An object by id, or by name (in a class, when given): the live one,
   *  else the one that ended last. Two live ones by that name: 409. */
  async find(ref: string, cls: string | null): Promise<Row> {
    if (cls !== null && !this.mm.has(cls)) throw new HttpError(404, `no class ${cls}`);
    const rows = UUID_RE.test(ref)
      ? (await this.pg.query("SELECT o.*, c.physical FROM object o JOIN class c ON c.name = o.class WHERE o.id = $1", [ref])).rows
      : (
          await this.pg.query(
            `SELECT o.*, c.physical FROM object o JOIN class c ON c.name = o.class
              WHERE o.name = $1 AND ($2::text IS NULL OR EXISTS (SELECT 1 FROM class_ancestor ca WHERE ca.class = o.class AND ca.ancestor = $2))
              ORDER BY o.ended IS NULL DESC, o.ended DESC`,
            [ref, cls],
          )
        ).rows;
    if (!rows.length) throw new HttpError(404, `no object ${cls ? `${cls}/` : ""}${ref}`);
    const live = rows.filter((r) => r.ended === null);
    if (live.length > 1) {
      throw new HttpError(409, `${ref} names ${live.length} objects; give the class or the id`, {
        candidates: live.map((r) => ({ id: r.id, class: r.class, name: r.name })),
      });
    }
    return rows[0];
  }

  async show(ref: string, cls: string | null, at: string | null): Promise<Obj> {
    const o = await this.find(ref, cls);
    const id = String(o.id);
    const attrs = (await this.attributesOf([id], at)).get(id) ?? [];
    const valid = at === null ? "upper_inf(r.validity)" : "r.validity @> $2::timestamptz";
    const rels = (
      await this.pg.query(
        `SELECT r.id, r.type, r.attributes, r.source, r.recorded, lower(r.validity) AS since,
                CASE WHEN r.from_object = $1 THEN 'out' ELSE 'in' END AS direction,
                p.id AS other_id, p.class AS other_class, p.name AS other_name
           FROM relation r JOIN object p ON p.id = CASE WHEN r.from_object = $1 THEN r.to_object ELSE r.from_object END
          WHERE (r.from_object = $1 OR r.to_object = $1) AND ${valid}
          ORDER BY r.type, p.name`,
        at === null ? [id] : [id, at],
      )
    ).rows;
    const attributes: Obj = {};
    for (const a of attrs) attributes[a.name] = { value: a.value, source: a.source, since: a.since };
    return {
      id,
      class: o.class,
      ancestors: this.mm.ancestors(String(o.class)),
      name: o.name,
      displayName: o.display_name,
      physical: o.physical,
      recorded: o.recorded,
      created: o.created,
      ended: o.ended,
      lastSeen: o.last_seen,
      seen: o.seen,
      at,
      attributes,
      drift: (attributes.drift as Obj | undefined)?.value ?? null,
      relations: rels.map((r) => ({
        id: r.id,
        type: r.type,
        direction: r.direction,
        other: { id: r.other_id, class: r.other_class, name: r.other_name },
        attributes: r.attributes,
        source: r.source,
        recorded: r.recorded,
        since: r.since,
      })),
    };
  }

  /** Relations by type, by either end (an id, a name, or class and name), by
   *  the ends' classes (subclasses too), recorded or not, as of a time: what
   *  a topology is read from. */
  async relations(body: Obj): Promise<Obj[]> {
    const at = body.at === undefined || body.at === null ? null : String(body.at);
    if (at !== null && Number.isNaN(Date.parse(at))) throw new HttpError(400, `at ${at} is not a date`);
    const params: Param[] = [];
    const conds: string[] = [];
    if (at !== null) {
      params.push(new Date(at).toISOString());
      conds.push(`r.validity @> $${params.length}::timestamptz`);
    } else conds.push("upper_inf(r.validity)");
    if (body.type !== undefined && body.type !== null) {
      const type = String(body.type);
      if (!this.mm.relationEnds(type).length) throw new HttpError(404, `no relation type ${type}`);
      params.push(type);
      conds.push(`r.type = $${params.length}`);
    }
    for (const [key, col] of [["from", "r.from_object"], ["to", "r.to_object"]] as const) {
      const ref = body[key];
      if (ref === undefined || ref === null) continue;
      const o = isObj(ref)
        ? await this.find(String(ref.id ?? ref.name ?? ""), typeof ref.class === "string" ? ref.class : null)
        : await this.find(String(ref), null);
      params.push(String(o.id));
      conds.push(`${col} = $${params.length}`);
    }
    for (const [key, alias] of [["fromClass", "f"], ["toClass", "t"]] as const) {
      const cls = body[key];
      if (cls === undefined || cls === null) continue;
      if (!this.mm.has(String(cls))) throw new HttpError(404, `no class ${String(cls)}`);
      params.push(String(cls));
      conds.push(`EXISTS (SELECT 1 FROM class_ancestor ca WHERE ca.class = ${alias}.class AND ca.ancestor = $${params.length})`);
    }
    if (typeof body.recorded === "boolean") {
      params.push(body.recorded);
      conds.push(`r.recorded = $${params.length}`);
    }
    const limit = Number.isInteger(body.limit) ? Number(body.limit) : 100000;
    const rows = (
      await this.pg.query(
        `SELECT r.id, r.type, r.attributes, r.source, r.recorded, lower(r.validity) AS since, upper(r.validity) AS until,
                f.id AS from_id, f.class AS from_class, f.name AS from_name,
                t.id AS to_id, t.class AS to_class, t.name AS to_name
           FROM relation r JOIN object f ON f.id = r.from_object JOIN object t ON t.id = r.to_object
          WHERE ${conds.join(" AND ")}
          ORDER BY r.type, f.name, t.name LIMIT ${limit}`,
        params,
      )
    ).rows;
    return rows.map((r) => ({
      id: r.id,
      type: r.type,
      from: { id: r.from_id, class: r.from_class, name: r.from_name },
      to: { id: r.to_id, class: r.to_class, name: r.to_name },
      attributes: r.attributes,
      source: r.source,
      recorded: r.recorded,
      since: r.since,
      until: r.until,
    }));
  }

  /** Every period of one attribute, on any object, that was in force at or
   *  after `since` (the newest first): what a CI carried and when, with the
   *  change that ended it — e.g. the investigations that have ended, read back
   *  when the file that listed them is gone. */
  async periods(attribute: string, since: string | null): Promise<Obj[]> {
    if (!attribute) throw new HttpError(400, "periods names an attribute");
    if (since !== null && Number.isNaN(Date.parse(since))) throw new HttpError(400, `since ${since} is not a date`);
    const rows = (
      await this.pg.query(
        `SELECT o.id, o.class, o.name, a.value, a.source, a.change,
                lower(a.validity) AS "from", upper(a.validity) AS "to",
                e.id AS ended_change, e.verb AS ended_verb, e.actor AS ended_actor
           FROM attribute a JOIN object o ON o.id = a.object
           LEFT JOIN LATERAL (
             SELECT c.id, c.verb, c.actor FROM change c
              WHERE NOT upper_inf(a.validity) AND c.time = upper(a.validity) AND c.objects @> ARRAY[a.object]
              ORDER BY c.id DESC LIMIT 1) e ON true
          WHERE a.name = $1 AND NOT isempty(a.validity)
            AND ($2::timestamptz IS NULL OR upper_inf(a.validity) OR upper(a.validity) >= $2::timestamptz)
          ORDER BY lower(a.validity) DESC, o.name`,
        [attribute, since === null ? null : new Date(since).toISOString()],
      )
    ).rows;
    return rows.map((r) => ({
      object: { id: r.id, class: r.class, name: r.name },
      value: r.value,
      source: r.source,
      change: r.change,
      from: r.from,
      to: r.to,
      ended: r.ended_change === null ? null : { change: r.ended_change, verb: r.ended_verb, actor: r.ended_actor },
    }));
  }

  /** Every period of every attribute and relation of an object, and the
   *  reports that wrote them; with at, the object as it was then. */
  async history(ref: string, cls: string | null, at: string | null): Promise<Obj> {
    if (at !== null) {
      if (Number.isNaN(Date.parse(at))) throw new HttpError(400, `at ${at} is not a date`);
      return this.show(ref, cls, new Date(at).toISOString());
    }
    const o = await this.find(ref, cls);
    const id = String(o.id);
    const attributes = (
      await this.pg.query(
        `SELECT a.name, a.value, a.source, a.change, lower(a.validity) AS "from", upper(a.validity) AS "to"
           FROM attribute a WHERE a.object = $1 AND NOT isempty(a.validity)
          ORDER BY lower(a.validity), a.name`,
        [id],
      )
    ).rows;
    const relations = (
      await this.pg.query(
        `SELECT r.id, r.type, CASE WHEN r.from_object = $1 THEN 'out' ELSE 'in' END AS direction,
                p.id AS other_id, p.class AS other_class, p.name AS other_name, r.attributes, r.source, r.change,
                lower(r.validity) AS "from", upper(r.validity) AS "to"
           FROM relation r JOIN object p ON p.id = CASE WHEN r.from_object = $1 THEN r.to_object ELSE r.from_object END
          WHERE (r.from_object = $1 OR r.to_object = $1) AND NOT isempty(r.validity)
          ORDER BY lower(r.validity), r.type`,
        [id],
      )
    ).rows;
    const changes = (
      await this.pg.query(
        `SELECT id, kind, source, job, verb, actor, time, drift FROM change WHERE objects @> ARRAY[$1::uuid] ORDER BY time, id`,
        [id],
      )
    ).rows;
    return {
      id,
      class: o.class,
      name: o.name,
      created: o.created,
      ended: o.ended,
      attributes,
      relations: relations.map((r) => ({
        id: r.id,
        type: r.type,
        direction: r.direction,
        other: { id: r.other_id, class: r.other_class, name: r.other_name },
        attributes: r.attributes,
        source: r.source,
        change: r.change,
        from: r.from,
        to: r.to,
      })),
      changes,
    };
  }

  // ── impact ────────────────────────────────────────────────────────────

  /** Everything within `hops` current relations of an object (D11: a node
   *  down — which guests, services, environments, users). Each object once,
   *  at its shortest distance, with the relation it was reached by. */
  async impact(ref: string, cls: string | null, hops: number, direction: string): Promise<Obj> {
    if (!Number.isInteger(hops) || hops < 1 || hops > 10) throw new HttpError(400, "hops is 1 to 10");
    if (!["in", "out", "both"].includes(direction)) throw new HttpError(400, "direction is in, out or both");
    const o = await this.find(ref, cls);
    const step =
      direction === "out" ? "r.from_object = w.id" : direction === "in" ? "r.to_object = w.id" : "(r.from_object = w.id OR r.to_object = w.id)";
    const rows = (
      await this.pg.query(
        `WITH RECURSIVE walk(id, depth, via, prev, path) AS (
           SELECT $1::uuid, 0, NULL::text, NULL::uuid, ARRAY[$1::uuid]
           UNION ALL
           SELECT CASE WHEN r.from_object = w.id THEN r.to_object ELSE r.from_object END,
                  w.depth + 1, r.type, w.id,
                  w.path || CASE WHEN r.from_object = w.id THEN r.to_object ELSE r.from_object END
             FROM walk w JOIN relation r ON ${step} AND upper_inf(r.validity)
            WHERE w.depth < $2
              AND NOT (CASE WHEN r.from_object = w.id THEN r.to_object ELSE r.from_object END) = ANY (w.path)
         )
         SELECT DISTINCT ON (w.id) w.id, w.depth, w.via, w.prev, x.class, x.name
           FROM walk w JOIN object x ON x.id = w.id
          WHERE w.depth > 0
          ORDER BY w.id, w.depth`,
        [String(o.id), hops],
      )
    ).rows;
    rows.sort((a, b) => Number(a.depth) - Number(b.depth) || String(a.class).localeCompare(String(b.class)) || String(a.name).localeCompare(String(b.name)));
    return {
      id: o.id,
      class: o.class,
      name: o.name,
      hops,
      direction,
      impact: rows.map((r) => ({ id: r.id, class: r.class, name: r.name, depth: r.depth, via: r.via, from: r.prev })),
    };
  }

  // ── resolve (D14) ─────────────────────────────────────────────────────

  /** OpenTelemetry resource attributes → the one live object they name. */
  async resolve(attrs: Obj): Promise<Obj> {
    if (!isObj(attrs) || !Object.keys(attrs).length) throw new HttpError(400, "resolve takes OpenTelemetry resource attributes");
    for (const k of ["tappaas.ci.id", "service.instance.id", "host.id"]) {
      const v = attrs[k];
      if (typeof v === "string" && UUID_RE.test(v)) {
        const r = (await this.pg.query("SELECT id, class, name FROM object WHERE id = $1", [v])).rows;
        if (r.length) return { ...r[0], by: k };
      }
    }
    // Every other attribute narrows the candidates: a field declared
    // identifying with that OpenTelemetry name, in any class.
    const params: Param[] = [];
    const conds: string[] = ["o.ended IS NULL"];
    const used: string[] = [];
    for (const [k, v] of Object.entries(attrs)) {
      if (typeof v !== "string" || ["tappaas.ci.id", "service.instance.id", "host.id", "service.namespace", "tappaas.ci.class"].includes(k)) continue;
      const alts: string[] = [];
      for (const cls of this.mm.classes.keys()) {
        for (const f of this.mm.fields(cls).values()) {
          if (!f.identifying || !Array.isArray(f.spec.otel) || !f.spec.otel.includes(k) || f.class !== cls) continue;
          params.push(JSON.stringify(this.mm.descendants(cls)));
          const classes = `o.class IN (SELECT jsonb_array_elements_text($${params.length}::jsonb))`;
          params.push(v);
          const val = `$${params.length}::text`;
          alts.push(
            f.name === "name"
              ? `(${classes} AND o.name = ${val})`
              : `(${classes} AND EXISTS (SELECT 1 FROM attribute a WHERE a.object = o.id AND a.name = '${f.name.replace(/'/g, "''")}' AND upper_inf(a.validity) AND a.value = to_jsonb(${val})))`,
          );
        }
      }
      if (!alts.length) continue;
      used.push(k);
      conds.push(`(${alts.join(" OR ")})`);
    }
    if (typeof attrs["tappaas.ci.class"] === "string") {
      params.push(attrs["tappaas.ci.class"]);
      conds.push(`EXISTS (SELECT 1 FROM class_ancestor ca WHERE ca.class = o.class AND ca.ancestor = $${params.length})`);
      used.push("tappaas.ci.class");
    }
    if (typeof attrs["service.namespace"] === "string") {
      // software: its node; a node: its environment.
      params.push(attrs["service.namespace"]);
      conds.push(`EXISTS (SELECT 1 FROM relation r JOIN object n ON n.id = r.to_object
                           WHERE r.from_object = o.id AND r.type IN ('runs-on', 'member-of') AND upper_inf(r.validity) AND n.name = $${params.length})`);
      used.push("service.namespace");
    }
    if (!used.length) throw new HttpError(400, "none of these attributes identifies an object");
    const rows = (await this.pg.query(`SELECT o.id, o.class, o.name FROM object o WHERE ${conds.join(" AND ")} ORDER BY o.class, o.name`, params)).rows;
    if (!rows.length) throw new HttpError(404, `no object has ${used.map((k) => `${k}=${String(attrs[k])}`).join(", ")}`);
    if (rows.length > 1) throw new HttpError(409, `${rows.length} objects match; add an attribute`, { candidates: rows });
    return { ...rows[0], by: used.join(",") };
  }

  // ── classes ───────────────────────────────────────────────────────────

  classes(): Obj[] {
    return [...this.mm.classes.values()].map((c) => ({
      name: c.name,
      parent: c.parent,
      abstract: c.abstract,
      physical: c.physical,
      depth: this.mm.ancestors(c.name).length - 1,
      description: c.description,
      symbol: c.symbol,
      family: c.family,
      label: c.label,
    }));
  }

  classInfo(name: string): Obj {
    const c = this.mm.classes.get(name);
    if (!c) throw new HttpError(404, `no class ${name}`);
    return {
      name,
      parent: c.parent,
      abstract: c.abstract,
      physical: c.physical,
      description: c.description,
      symbol: c.symbol,
      family: c.family,
      label: c.label,
      ancestors: this.mm.ancestors(name),
      subclasses: this.mm.descendants(name).filter((d) => d !== name),
      keys: this.mm.keys(name),
      keyScope: this.mm.keyScope(name),
      keyVia: this.mm.keyVia(name),
      expirySeconds: this.mm.expirySeconds(name),
      fields: [...this.mm.fields(name).values()],
      relations: this.mm.relations.filter((r) => this.mm.isA(name, r.from) || this.mm.isA(name, r.to)),
    };
  }

  async counts(): Promise<Obj> {
    const r = (await this.pg.query("SELECT (SELECT count(*) FROM object) AS objects, (SELECT count(*) FROM change) AS changes")).rows[0];
    return { classes: this.mm.classes.size, objects: r.objects, changes: r.changes };
  }
}

// ── one report, in its transaction ─────────────────────────────────────────

class ReportRun {
  change = 0;
  problems: Problem[] = [];
  touched = new Set<string>();
  relationIds = new Set<number>();
  private named = new Set<string>(); // type|from|to of every relation this report put
  drift = false;
  results: ReportResult["objects"] = [];
  private refs = new Map<string, Target>();
  // What the report says about the objects it names by ref: the objects that
  // point at them (a port's asset), for the keys that are a related object's
  // field (an asset's ports' MACs, D5).
  private related = new Map<string, { class: string; relation: string; attributes: Obj }[]>();
  placeholders: Target[] = [];

  constructor(
    private readonly mm: Metamodel,
    private readonly q: Query,
    private readonly source: string,
    private readonly kind: "observation" | "change",
    readonly t: string,
    private readonly allRecorded: boolean,
    private readonly assessment: boolean,
  ) {}

  prescan(objects: ReportObject[]): void {
    for (const o of objects) {
      if (!isObj(o) || typeof o.class !== "string" || !this.mm.has(o.class) || !isObj(o.attributes)) continue;
      for (const f of this.mm.fields(o.class).values()) {
        if (f.type !== "relation" || f.spec.direction === "in") continue;
        const v = o.attributes[f.name];
        const ref = typeof v === "string" ? v : isObj(v) && typeof v.ref === "string" ? v.ref : null;
        if (ref === null) continue;
        this.related.set(ref, [...(this.related.get(ref) ?? []), { class: o.class, relation: String(f.spec.relation), attributes: o.attributes }]);
      }
    }
  }

  // The values of a keyVia this report gives for the object with this ref.
  private viaValues(ref: string | undefined, kv: KeyVia): string[] {
    if (ref === undefined) return [];
    return (this.related.get(ref) ?? [])
      .filter((r) => r.relation === kv.relation && this.mm.isA(r.class, kv.class))
      .map((r) => r.attributes[kv.field])
      .filter((v): v is string => typeof v === "string" && v !== "");
  }

  private problem(at: string, error: string, candidates?: Problem["candidates"]): void {
    this.problems.push(candidates ? { at, error, candidates } : { at, error });
  }

  // A reference to an object: in this report, by id, or by class and name.
  private async target(at: string, ref: Ref, classes: string[] | null): Promise<Target | null> {
    let id: string | undefined;
    let cls: string | undefined;
    let name: string | undefined;
    if (typeof ref === "string") {
      const local = this.refs.get(ref);
      if (local) return local;
      if (UUID_RE.test(ref)) id = ref;
      else name = ref;
    } else if (isObj(ref)) {
      if (typeof ref.ref === "string") {
        const local = this.refs.get(ref.ref);
        if (!local) {
          this.problem(at, `ref ${ref.ref} is not an object earlier in this report`);
          return null;
        }
        return local;
      }
      id = typeof ref.id === "string" ? ref.id : undefined;
      cls = typeof ref.class === "string" ? ref.class : undefined;
      name = typeof ref.name === "string" ? ref.name : undefined;
    }
    if (id) {
      const r = (await this.q("SELECT id, class, name FROM object WHERE id = $1 AND ended IS NULL", [id])).rows;
      if (!r.length) {
        this.problem(at, `no live object ${id}`);
        return null;
      }
      return { id: String(r[0].id), class: String(r[0].class), name: String(r[0].name) };
    }
    if (!name) {
      this.problem(at, "a reference is a ref, an id, or a class and a name");
      return null;
    }
    const within = cls ? (this.mm.has(cls) ? this.mm.descendants(cls) : []) : classes;
    const r = (
      await this.q(
        `SELECT id, class, name FROM object WHERE name = $1 AND ended IS NULL
            AND ($2::jsonb IS NULL OR class IN (SELECT jsonb_array_elements_text($2::jsonb)))`,
        [name, within === null ? null : JSON.stringify(within)],
      )
    ).rows;
    if (!r.length && cls && this.mm.has(cls)) return this.placeholder(cls, name);
    if (r.length !== 1) {
      this.problem(
        at,
        r.length ? `${name} matches ${r.length} objects` : cls ? `no class ${cls}` : `no live object named ${name}`,
        r.length ? r.map((x) => ({ id: String(x.id), class: String(x.class), name: String(x.name) })) : undefined,
      );
      return null;
    }
    return { id: String(r[0].id), class: String(r[0].class), name: String(r[0].name) };
  }

  // A name-only object for a reference to something its owner has not reported
  // yet: no stage, never "seen", so it does not expire. The owner's report
  // merges into it (below). An abstract class is kept until then: the owner
  // says what it is.
  private async placeholder(cls: string, name: string): Promise<Target> {
    const r = await this.q("INSERT INTO object (class, name, created) VALUES ($1, $2, $3) RETURNING id", [cls, name, this.t]);
    const id = String(r.rows[0].id);
    await this.q(
      `INSERT INTO attribute (object, name, value, source, change, validity) VALUES ($1, 'placeholder', 'true'::jsonb, $2, $3, tstzrange($4, NULL))`,
      [id, this.source, this.change, this.t],
    );
    const target = { id, class: cls, name };
    this.placeholders.push(target);
    this.touched.add(id);
    return target;
  }

  // The live placeholders a report of this object is the owner of: its name,
  // in its class or an abstract class above it; the exact class first.
  private async placeholdersFor(cls: string, name: string): Promise<Target[]> {
    const rows = (
      await this.q(
        `SELECT o.id, o.class, o.name FROM object o
          WHERE o.name = $1 AND o.ended IS NULL AND o.class IN (SELECT jsonb_array_elements_text($2::jsonb))
            AND NOT ${NOT_PLACEHOLDER}
          ORDER BY o.class = $3 DESC, o.created`,
        [name, JSON.stringify(this.mm.ancestors(cls)), cls],
      )
    ).rows;
    return rows.map((r) => ({ id: String(r.id), class: String(r.class), name: String(r.name) }));
  }

  // A placeholder beside the object it turned out to be: its relations move
  // over, and it ends.
  private async absorb(ph: Target, into: string): Promise<void> {
    const rows = (await this.q("SELECT id, type, from_object, to_object, attributes, recorded FROM relation WHERE (from_object = $1 OR to_object = $1) AND upper_inf(validity)", [ph.id])).rows;
    for (const r of rows) {
      await this.closeRelation(Number(r.id));
      const from = r.from_object === ph.id ? into : String(r.from_object);
      const to = r.to_object === ph.id ? into : String(r.to_object);
      if (from !== to) await this.putRelation(String(r.type), from, to, r.attributes as Obj, r.recorded === true);
    }
    await this.q("UPDATE object SET ended = $2 WHERE id = $1", [ph.id, this.t]);
    this.touched.add(ph.id);
  }

  async object(i: number, o: ReportObject): Promise<void> {
    const at = `objects[${i}]${isObj(o) && o.name ? ` (${String(o.class)} ${String(o.name)})` : ""}`;
    if (!isObj(o) || typeof o.class !== "string" || typeof o.name !== "string" || !o.name) {
      this.problem(at, "an object has a class and a name");
      return;
    }
    const cls = this.mm.classes.get(o.class);
    if (!cls) return this.problem(at, `no class ${o.class}`);
    if (cls.abstract) return this.problem(at, `${o.class} is abstract; report one of ${this.mm.descendants(o.class).filter((c) => !this.mm.classes.get(c)!.abstract).join(", ")}`);
    const fields = this.mm.fields(o.class);
    const attrs = isObj(o.attributes) ? o.attributes : {};
    const before = this.problems.length;

    // 1. Every attribute against the field its class (or an ancestor) declares.
    const values = new Map<string, unknown>(); // plain fields; null unsets
    const targets = new Map<string, Target | null>(); // relation fields; null ends
    for (const [k, v] of Object.entries(attrs)) {
      const f = fields.get(k);
      if (!f) {
        this.problem(at, `${o.class} has no field ${k}`);
        continue;
      }
      if (k === "name") {
        this.problem(at, "name is the object's own, not an attribute");
        continue;
      }
      if (f.spec.derived === true) {
        this.problem(at, `${k} is kept by cmdb-controller, not reported`);
        continue;
      }
      if (v === null) {
        if (f.required) this.problem(at, `${k} is required and cannot be unset`);
        else if (f.type === "relation") targets.set(k, null);
        else values.set(k, null);
        continue;
      }
      if (f.type === "relation") {
        const rel = String(f.spec.relation);
        const dir = f.spec.direction === "in" ? "in" : "out";
        const tg = await this.target(`${at}.${k}`, v as Ref, this.mm.targetClasses(rel, o.class, dir));
        if (!tg) continue;
        const ok = dir === "out" ? this.mm.allows(rel, o.class, tg.class) : this.mm.allows(rel, tg.class, o.class);
        if (!ok) {
          this.problem(at, `${k}: ${rel} does not join ${dir === "out" ? `${o.class} to ${tg.class}` : `${tg.class} to ${o.class}`}`);
          continue;
        }
        targets.set(k, tg);
        continue;
      }
      const want = typeOk(f, v);
      if (want) this.problem(at, `${k} must be ${want}`);
      else values.set(k, v);
    }
    if (this.problems.length > before) return;

    // 2. Which object is it (D5)?
    if (this.assessment && typeof o.id !== "string") return this.problem(at, "an assessment names its objects by id");
    const match = typeof o.id === "string" ? await this.byId(at, o.id) : await this.match(at, o.class, o.name, o.ref, values, targets);
    if (match === undefined) return;
    const recorded = this.allRecorded || o.recorded === true;
    const placeholders = typeof o.id === "string" ? [] : await this.placeholdersFor(o.class, o.name);
    const adopted = match === null ? placeholders.shift() : undefined;
    let id: string;
    let created = false;
    const current = new Map<string, Current>();
    const currentTargets = new Map<string, { id: number; to: string; from: string }>();
    if (match === null) {
      if (o.end && !adopted) return; // already gone, or never reported: there is nothing to end
      for (const f of fields.values()) {
        if (!f.required || f.name === "name") continue;
        if (f.type === "relation" ? !targets.get(f.name) : values.get(f.name) === undefined || values.get(f.name) === null) {
          this.problem(at, `${f.name} is required`);
        }
      }
      if (this.problems.length > before) return;
    }
    if (match === null && !adopted) {
      const r = await this.q(
        `INSERT INTO object (class, name, display_name, created, last_seen, seen, recorded)
         VALUES ($1, $2, $3, $4, $4, $5::jsonb, $6) RETURNING id`,
        [o.class, o.name, typeof values.get("displayName") === "string" ? String(values.get("displayName")) : null, this.t, { [this.source]: this.t }, recorded],
      );
      id = String(r.rows[0].id);
      created = true;
      this.touched.add(id);
    } else {
      const known = (match ?? adopted)!;
      id = known.id;
      if (adopted) {
        await this.q("UPDATE object SET class = $2 WHERE id = $1", [id, o.class]);
        this.touched.add(id);
      } else if (match!.class !== o.class) {
        return this.problem(at, `conflict: the key matches ${match!.class} ${match!.name}, not a ${o.class}`, [match!]);
      }
      if (known.name !== o.name && this.mm.isA(o.class, "ci")) {
        // A CI's name is immutable: a renamed CI is a new one (D7).
        return this.problem(at, `conflict: the key matches ${known.class} ${known.name}, named ${o.name} here`, [known]);
      }
      // A resource or place found by a stronger key (an asset by its serial or
      // a port's MAC) keeps the name it has: a reporter that does not know the
      // asset's tag (the installer's hook, D8) still reaches the asset.
      for (const r of (await this.q(`SELECT id, name, value, lower(validity) AS "from" FROM attribute WHERE object = $1 AND upper_inf(validity)`, [id])).rows) {
        current.set(String(r.name), { id: Number(r.id), value: r.value, from: String(r.from) });
      }
      for (const [k, f] of fields) {
        if (f.type !== "relation") continue;
        const cur = await this.currentTarget(id, String(f.spec.relation), f.spec.direction === "in" ? "in" : "out", f.spec.target as string | undefined);
        if (cur) currentTargets.set(k, cur);
      }
      const ph = current.get("placeholder");
      if (ph) {
        await this.q("UPDATE attribute SET validity = tstzrange(lower(validity), $2) WHERE id = $1", [ph.id, later(this.t, ph.from)]);
        current.delete("placeholder");
      }
      for (const other of placeholders) await this.absorb(other, id);
    }

    // 3. What may not change, and what one field allows of another.
    for (const [k, v] of values) {
      const f = fields.get(k)!;
      const cur = current.get(k);
      if (f.immutable && cur && !same(cur.value, v)) this.problem(at, `${k} is immutable (${JSON.stringify(cur.value)} → ${JSON.stringify(v)}): conflict`);
    }
    for (const [k, tg] of targets) {
      const f = fields.get(k)!;
      const cur = currentTargets.get(k);
      if (f.immutable && cur && (!tg || (f.spec.direction === "in" ? cur.from : cur.to) !== tg.id)) this.problem(at, `${k} is immutable: conflict`);
    }
    const merged = new Map<string, unknown>([...[...current].map(([k, c]) => [k, c.value] as [string, unknown]), ...values]);
    for (const [k, f] of fields) {
      const v = merged.get(k);
      if (v === undefined || v === null || !isObj(f.spec.allowedBy)) continue;
      for (const [ctl, table] of Object.entries(f.spec.allowedBy)) {
        const cv = merged.get(ctl);
        const allowed = isObj(table) && typeof cv === "string" ? table[cv] : undefined;
        if (!Array.isArray(allowed)) this.problem(at, `${k} does not apply to a ${o.class} whose ${ctl} is ${JSON.stringify(cv ?? null)}`);
        else if (allowed.length && !(Array.isArray(v) ? v : [v]).every((x) => allowed.includes(x))) {
          this.problem(at, `${k} of a ${ctl} ${String(cv)} ${o.class} is one of ${allowed.join(", ")}`);
        }
      }
    }
    if (this.problems.length > before) return;

    // 4. Write: a value that differs closes its row and opens one (D6).
    const changed: string[] = [];
    // A CI that was unseen and is reported again is operational (D7); the
    // controller says so, unless the report sets the stage itself.
    const stage = current.get("stage");
    if (!o.end && stage && stage.value === "unseen" && !values.has("stage") && this.kind === "observation" && !this.assessment) {
      const t = later(this.t, stage.from);
      await this.q("UPDATE attribute SET validity = tstzrange(lower(validity), $2) WHERE id = $1", [stage.id, t]);
      await this.q(
        `INSERT INTO attribute (object, name, value, source, change, validity) VALUES ($1, 'stage', '"operational"'::jsonb, $2, $3, tstzrange($4, NULL))`,
        [id, CONTROLLER_SOURCE, this.change, t],
      );
      current.delete("stage");
      changed.push("stage");
    }
    const drifted: Record<string, { was: unknown; now: unknown }> = {};
    for (const [k, v] of values) {
      const cur = current.get(k);
      if (cur && same(cur.value, v)) continue;
      if (!cur && v === null) continue;
      if (cur && v !== null && same(stable(fields.get(k)!, cur.value), stable(fields.get(k)!, v))) {
        await this.q("UPDATE attribute SET value = $2::jsonb WHERE id = $1", [cur.id, JSON.stringify(v)]);
        continue;
      }
      const t = cur ? later(this.t, cur.from) : this.t;
      if (cur) await this.q("UPDATE attribute SET validity = tstzrange(lower(validity), $2) WHERE id = $1", [cur.id, t]);
      if (v !== null) {
        await this.q(
          "INSERT INTO attribute (object, name, value, source, change, validity) VALUES ($1, $2, $3::jsonb, $4, $5, tstzrange($6, NULL))",
          [id, k, JSON.stringify(v), this.source, this.change, t],
        );
      }
      if (k === "displayName") await this.q("UPDATE object SET display_name = $2 WHERE id = $1", [id, typeof v === "string" ? v : null]);
      changed.push(k);
      if (cur && this.kind === "observation" && !fields.get(k)!.volatile) drifted[k] = { was: cur.value, now: v };
    }
    for (const [k, tg] of targets) {
      const f = fields.get(k)!;
      const rel = String(f.spec.relation);
      const dir = f.spec.direction === "in" ? "in" : "out";
      const cur = currentTargets.get(k);
      const curOther = cur ? (dir === "out" ? cur.to : cur.from) : null;
      if (tg && curOther === tg.id) {
        if (recorded) await this.q("UPDATE relation SET recorded = true WHERE id = $1 AND NOT recorded", [cur!.id]);
        continue;
      }
      if (!tg && !cur) continue;
      if (cur) await this.closeRelation(cur.id);
      if (tg) {
        const [from, to] = dir === "out" ? [id, tg.id] : [tg.id, id];
        await this.putRelation(rel, from, to, {}, recorded);
      }
      changed.push(k);
      if (cur && this.kind === "observation") drifted[k] = { was: curOther, now: tg ? tg.id : null };
    }

    // 5. Drift: an observation that differs from the last with nothing
    // behind it (D6). A change clears it.
    const drift = current.get("drift");
    const driftNames = Object.keys(drifted);
    if (driftNames.length) {
      const was = drift && isObj(drift.value) ? drift.value : null;
      const value = {
        since: was?.since ?? this.t,
        source: this.source,
        attributes: { ...(isObj(was?.attributes) ? was!.attributes : {}), ...drifted },
        desired: current.get("desired")?.value ?? null,
      };
      if (drift) await this.q("UPDATE attribute SET validity = tstzrange(lower(validity), $2) WHERE id = $1", [drift.id, later(this.t, drift.from)]);
      await this.q(
        "INSERT INTO attribute (object, name, value, source, change, validity) VALUES ($1, 'drift', $2::jsonb, $3, $4, tstzrange($5, NULL))",
        [id, JSON.stringify(value), CONTROLLER_SOURCE, this.change, drift ? later(this.t, drift.from) : this.t],
      );
      this.drift = true;
    } else if (drift && this.kind === "change") {
      await this.q("UPDATE attribute SET validity = tstzrange(lower(validity), $2) WHERE id = $1", [drift.id, later(this.t, drift.from)]);
      changed.push("drift");
    }

    // 6. Seen; ended.
    if (!this.assessment) {
      await this.q(
        `UPDATE object SET last_seen = GREATEST(last_seen, $2::timestamptz), seen = seen || $3::jsonb, recorded = recorded OR $4 WHERE id = $1`,
        [id, this.t, { [this.source]: this.t }, recorded],
      );
    }
    let ended = false;
    if (o.end) {
      await this.end(id, o.class, current);
      ended = true;
    }
    if (changed.length || ended) this.touched.add(id);
    const name = match ? match.name : o.name;
    const target = { id, class: o.class, name };
    if (typeof o.ref === "string") this.refs.set(o.ref, target);
    this.results.push({ ref: o.ref, id, class: o.class, name, ...(name !== o.name ? { reportedAs: o.name } : {}), created, ...(adopted ? { adopted: true } : {}), changed, drift: driftNames, ended });
  }

  private async byId(at: string, id: string): Promise<Target | undefined> {
    const r = (await this.q("SELECT id, class, name FROM object WHERE id = $1 AND ended IS NULL", [id])).rows;
    if (!r.length) {
      this.problem(at, `no live object ${id}`);
      return undefined;
    }
    return { id: String(r[0].id), class: String(r[0].class), name: String(r[0].name) };
  }

  // The object a report means, by its class's keys, strongest first (D5).
  // undefined: refused (a problem is recorded); null: a new object.
  private async match(
    at: string,
    cls: string,
    name: string,
    ref: string | undefined,
    values: Map<string, unknown>,
    targets: Map<string, Target | null>,
  ): Promise<Target | null | undefined> {
    const keys = this.mm.keys(cls);
    const fields = this.mm.fields(cls);
    const tried: { rank: number; components: string[]; via?: KeyVia }[] = keys.length ? [...keys] : [{ rank: 0, components: ["name"] }];
    for (const kv of this.mm.keyVia(cls)) tried.push({ rank: kv.rank, components: [`${kv.class}.${kv.field}`], via: kv });
    tried.sort((a, b) => a.rank - b.rank);
    let found: Target | null = null;
    let complete = 0;
    const take = (key: { components: string[] }, hits: Target[]): boolean => {
      if (hits.length > 1) {
        this.problem(at, `conflict: key (${key.components.join(", ")}) matches ${hits.length} objects`, hits);
        return false;
      }
      if (hits.length === 1) {
        if (found && found.id !== hits[0].id) {
          this.problem(at, `conflict: key (${key.components.join(", ")}) matches ${hits[0].class} ${hits[0].name}, a stronger key ${found.class} ${found.name}`, [found, hits[0]]);
          return false;
        }
        found = hits[0];
      }
      return true;
    };
    for (const key of tried) {
      if (key.via) {
        // Any of the related objects' values: an asset whose stored ports
        // carry one of the MACs its ports in this report carry.
        const kv = key.via;
        const vals = this.viaValues(ref, kv);
        if (!vals.length) continue;
        complete++;
        const rows = (
          await this.q(
            `SELECT DISTINCT o.id, o.class, o.name FROM object o
               JOIN relation r ON r.to_object = o.id AND r.type = $2 AND upper_inf(r.validity)
               JOIN object p ON p.id = r.from_object AND p.ended IS NULL
               JOIN class_ancestor ca ON ca.class = p.class AND ca.ancestor = $3
               JOIN attribute a ON a.object = p.id AND a.name = $4 AND upper_inf(a.validity)
              WHERE o.ended IS NULL AND ${NOT_PLACEHOLDER} AND o.class IN (SELECT jsonb_array_elements_text($1::jsonb))
                AND lower(a.value #>> '{}') IN (SELECT lower(x) FROM jsonb_array_elements_text($5::jsonb) AS x)`,
            [JSON.stringify(this.mm.keyViaClasses(cls, kv)), kv.relation, kv.class, kv.field, JSON.stringify(vals)],
          )
        ).rows;
        if (!take(key, rows.map((r) => ({ id: String(r.id), class: String(r.class), name: String(r.name) })))) return undefined;
        continue;
      }
      const params: Param[] = [JSON.stringify(this.mm.keyClasses(cls, key))];
      const conds = ["o.ended IS NULL", NOT_PLACEHOLDER, "o.class IN (SELECT jsonb_array_elements_text($1::jsonb))"];
      let usable = true;
      for (const c of key.components) {
        const f = fields.get(c)!;
        if (c === "name") {
          params.push(name);
          conds.push(`o.name = $${params.length}`);
        } else if (f.type === "relation") {
          const tg = targets.get(c);
          if (!tg) {
            usable = false;
            break;
          }
          params.push(String(f.spec.relation), tg.id);
          conds.push(
            f.spec.direction === "in"
              ? `EXISTS (SELECT 1 FROM relation r WHERE r.type = $${params.length - 1} AND r.to_object = o.id AND r.from_object = $${params.length} AND upper_inf(r.validity))`
              : `EXISTS (SELECT 1 FROM relation r WHERE r.type = $${params.length - 1} AND r.from_object = o.id AND r.to_object = $${params.length} AND upper_inf(r.validity))`,
          );
        } else {
          const v = values.get(c);
          if (v === undefined || v === null) {
            usable = false;
            break;
          }
          params.push(c, JSON.stringify(v));
          conds.push(
            `EXISTS (SELECT 1 FROM attribute a WHERE a.object = o.id AND a.name = $${params.length - 1} AND a.value = $${params.length}::jsonb AND upper_inf(a.validity))`,
          );
        }
      }
      if (!usable) continue;
      complete++;
      const rows = (await this.q(`SELECT o.id, o.class, o.name FROM object o WHERE ${conds.join(" AND ")}`, params)).rows;
      if (!take(key, rows.map((r) => ({ id: String(r.id), class: String(r.class), name: String(r.name) })))) return undefined;
    }
    if (!complete) {
      this.problem(at, `no key: a ${cls} is known by ${tried.map((k) => `(${k.components.join(", ")})`).join(" or ")}`);
      return undefined;
    }
    return found;
  }

  // A field's `target` narrows a relation type that joins a class to several
  // others: a node's environment is one member-of, its cluster another.
  private async currentTarget(id: string, rel: string, dir: "out" | "in", target?: string): Promise<{ id: number; from: string; to: string } | null> {
    const other = target ? `AND (SELECT class FROM object WHERE id = ${dir === "out" ? "to_object" : "from_object"}) IN (SELECT jsonb_array_elements_text($3::jsonb))` : "";
    const r = (
      await this.q(
        `SELECT id, from_object, to_object FROM relation WHERE type = $1 AND ${dir === "out" ? "from_object" : "to_object"} = $2 AND upper_inf(validity) ${other} ORDER BY id DESC LIMIT 1`,
        target ? [rel, id, JSON.stringify(this.mm.descendants(target))] : [rel, id],
      )
    ).rows;
    return r.length ? { id: Number(r[0].id), from: String(r[0].from_object), to: String(r[0].to_object) } : null;
  }

  private async closeRelation(rid: number): Promise<void> {
    await this.q("UPDATE relation SET validity = tstzrange(lower(validity), GREATEST(lower(validity), $2::timestamptz)) WHERE id = $1", [rid, this.t]);
    this.relationIds.add(rid);
  }

  // Open (type, from, to) with these attributes, closing what the type's
  // cardinality says a new one replaces. The dependency words (ADR-041 D3) are
  // set by the one source that knows them, while others report the same
  // relation: a report that does not name one keeps it, null unsets it, and a
  // report of nothing but them adds them to the relation's other attributes.
  private async putRelation(type: string, from: string, to: string, given: Obj, recorded = false): Promise<number> {
    const open = (
      await this.q(
        "SELECT id, attributes, recorded, lower(validity) AS since FROM relation WHERE type = $1 AND from_object = $2 AND to_object = $3 AND upper_inf(validity)",
        [type, from, to],
      )
    ).rows;
    const attributes = withDependency(isObj(open[0]?.attributes) ? (open[0].attributes as Obj) : {}, given);
    if (open.length && same(open[0].attributes, attributes)) {
      if (recorded && open[0].recorded !== true) {
        await this.q("UPDATE relation SET recorded = true WHERE id = $1", [Number(open[0].id)]);
        this.relationIds.add(Number(open[0].id));
      }
      return Number(open[0].id);
    }
    const keep = recorded || open[0]?.recorded === true;
    let t = this.t;
    if (open.length) {
      t = later(this.t, String(open[0].since));
      await this.closeRelation(Number(open[0].id));
    }
    const card = this.mm.relationEnds(type)[0]?.cardinality ?? "n:m";
    const replace: string[] = [];
    if (card === "n:1" || card === "1:1") replace.push("from_object = $2 AND to_object <> $3");
    if (card === "1:n" || card === "1:1") replace.push("to_object = $3 AND from_object <> $2");
    if (replace.length) {
      for (const r of (await this.q(`SELECT id FROM relation WHERE type = $1 AND upper_inf(validity) AND ((${replace.join(") OR (")}))`, [type, from, to])).rows) {
        await this.closeRelation(Number(r.id));
      }
    }
    const r = await this.q(
      `INSERT INTO relation (type, from_object, to_object, attributes, source, change, validity, recorded)
       VALUES ($1, $2, $3, $4::jsonb, $5, $6, tstzrange($7, NULL), $8) RETURNING id`,
      [type, from, to, JSON.stringify(attributes), this.source, this.change, t, keep],
    );
    const rid = Number(r.rows[0].id);
    this.relationIds.add(rid);
    this.touched.add(from);
    this.touched.add(to);
    return rid;
  }

  /** Retire (or dispose of) a live object by id, as a report's end does. */
  async retire(id: string, cls: string): Promise<void> {
    const s = (await this.q(`SELECT id, value, lower(validity) AS "from" FROM attribute WHERE object = $1 AND name = 'stage' AND upper_inf(validity)`, [id])).rows;
    const stage = s.length ? ([["stage", { id: Number(s[0].id), value: s[0].value, from: String(s[0].from) }]] as [string, Current][]) : [];
    await this.end(id, cls, new Map(stage));
    this.touched.add(id);
  }

  // Retired (a CI) or disposed (a resource): its relations end, its rows stay.
  // What is known by the ended object ends with it — the pools and software
  // on an ended node: their key is that node, so nothing can find them again.
  private async end(id: string, cls: string, current: Map<string, Current>): Promise<void> {
    await this.q("UPDATE object SET ended = $2 WHERE id = $1 AND ended IS NULL", [id, this.t]);
    const keyed = this.mm.keyedOn();
    if (keyed.length) {
      const dependants = await this.q(
        `SELECT DISTINCT o.id, o.class FROM relation r
           JOIN object o ON o.id = r.from_object AND o.ended IS NULL
           JOIN jsonb_to_recordset($2::jsonb) AS k(class text, relation text) ON k.class = o.class AND k.relation = r.type
          WHERE r.to_object = $1 AND upper_inf(r.validity)`,
        [id, JSON.stringify(keyed)],
      );
      for (const r of dependants.rows) await this.retire(String(r.id), String(r.class));
    }
    for (const r of (await this.q("SELECT id FROM relation WHERE (from_object = $1 OR to_object = $1) AND upper_inf(validity)", [id])).rows) {
      await this.closeRelation(Number(r.id));
    }
    const stage = this.mm.isA(cls, "ci") ? "retired" : this.mm.isA(cls, "resource") ? "disposed" : null;
    const cur = current.get("stage");
    if (stage && this.mm.fields(cls).has("stage") && !(cur && cur.value === stage)) {
      const t = cur ? later(this.t, cur.from) : this.t;
      if (cur) await this.q("UPDATE attribute SET validity = tstzrange(lower(validity), $2) WHERE id = $1", [cur.id, t]);
      await this.q(
        "INSERT INTO attribute (object, name, value, source, change, validity) VALUES ($1, 'stage', $2::jsonb, $3, $4, tstzrange($5, NULL))",
        [id, JSON.stringify(stage), this.source, this.change, t],
      );
    }
  }

  async relation(i: number, r: ReportRelation): Promise<void> {
    const at = `relations[${i}]${isObj(r) && r.type ? ` (${String(r.type)})` : ""}`;
    if (!isObj(r) || typeof r.type !== "string") return this.problem(at, "a relation has a type, a from and a to");
    if (!this.mm.relationEnds(r.type).length) return this.problem(at, `no relation type ${r.type}`);
    const from = await this.target(`${at}.from`, r.from, null);
    const to = await this.target(`${at}.to`, r.to, null);
    if (!from || !to) return;
    if (!this.mm.allows(r.type, from.class, to.class)) return this.problem(at, `${r.type} does not join ${from.class} to ${to.class}`);
    const ra = isObj(r.attributes) ? r.attributes : {};
    if (ra.required !== undefined && ra.required !== null && typeof ra.required !== "boolean") return this.problem(at, "required is true or false (null unsets it)");
    if (ra.redundancyGroup !== undefined && ra.redundancyGroup !== null && (typeof ra.redundancyGroup !== "string" || !ra.redundancyGroup)) {
      return this.problem(at, "redundancyGroup is a name (null unsets it)");
    }
    if (r.end) {
      const open = (
        await this.q("SELECT id FROM relation WHERE type = $1 AND from_object = $2 AND to_object = $3 AND upper_inf(validity)", [r.type, from.id, to.id])
      ).rows;
      for (const x of open) await this.closeRelation(Number(x.id));
      if (open.length) {
        this.touched.add(from.id);
        this.touched.add(to.id);
      }
      return;
    }
    await this.putRelation(r.type, from.id, to.id, isObj(r.attributes) ? r.attributes : {}, this.allRecorded || r.recorded === true);
    this.named.add(`${r.type}|${from.id}|${to.id}`);
  }

  /** A complete statement: close what the report no longer names. */
  async complete(i: number, c: { type: string; from: Ref; toClass?: string }): Promise<void> {
    const at = `complete[${i}]`;
    if (!isObj(c) || typeof c.type !== "string" || !this.mm.relationEnds(c.type).length) return this.problem(at, "a complete names a relation type and a from");
    if (c.toClass !== undefined && (typeof c.toClass !== "string" || !this.mm.has(c.toClass))) return this.problem(`${at}.toClass`, `no class ${String(c.toClass)}`);
    const from = await this.target(`${at}.from`, c.from, null);
    if (!from) return;
    const open = (await this.q(
      `SELECT r.id, r.to_object FROM relation r JOIN object o ON o.id = r.to_object
        WHERE r.type = $1 AND r.from_object = $2 AND upper_inf(r.validity) AND NOT r.recorded
          AND ($3::text IS NULL OR EXISTS (SELECT 1 FROM class_ancestor ca WHERE ca.class = o.class AND ca.ancestor = $3))`,
      [c.type, from.id, c.toClass ?? null],
    )).rows;
    for (const x of open) {
      if (this.named.has(`${c.type}|${from.id}|${String(x.to_object)}`)) continue;
      await this.closeRelation(Number(x.id));
      this.touched.add(from.id);
      this.touched.add(String(x.to_object));
    }
  }
}
